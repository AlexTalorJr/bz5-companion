import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../data/database.dart';

/// v0.1.81+180 — ИМПОРТ ИЗ АРХИВА: ВТОРАЯ ПОЛОВИНА ЭКСПОРТА.
///
/// ЗАЧЕМ. Обновление на ГУ идёт только через удаление — тема установки
/// поверх закрыта полем 31.07: прошивка отвечает «нельзя устанавливать
/// приложения не из магазина приложений» тостом без кнопок, и это
/// политика, а не разрешение. Значит цену удаления надо снимать с
/// другой стороны: сделать так, чтобы стирание ничего не стоило.
///
/// ЧТО УЖЕ БЫЛО ГОТОВО, И ЭТО ГЛАВНОЕ. `samples.sqlite` внутри архива —
/// не выгрузка, а ПОБАЙТОВАЯ КОПИЯ живой базы Drift
/// (`export_service._findDatabaseFile`). Проверено на реальном архиве
/// 31.07: `user_version` 17, журнал откатный (не WAL), счётчики в
/// `metadata.json` совпадают с содержимым копии до строки. Поэтому
/// импорт не разбирает CSV и не собирает строки заново — он кладёт
/// файл обратно. Разом приезжает всё, включая то, чего в облаке нет
/// вовсе: `hal_samples`, `samples` и незамороженные полосы атласа.
///
/// ПУТЬ К ФАЙЛУ ОТКРЫТ, И ЭТО ИЗМЕРЕНО. Экспорт пишет в
/// `/storage/emulated/0/Download`, когда туда пишется. 31.07 туда
/// записалось зеркало маркера — при `read_storage_granted=false`, то
/// есть БЕЗ единого разрешения на хранилище. Значит архив переживает
/// удаление и читается обратно обычным `File`. Стена, которая убила
/// тему установки (нет DocumentsUI, нет SAF, GET_CONTENT перехвачен
/// галереей), здесь не стоит вообще — выбор файла не нужен.
///
/// ПОДМЕНА НЕ НА ЖИВОЙ БАЗЕ. Файл кладётся рядом под служебным именем,
/// ставится флаг, а замена происходит на следующем старте ДО того, как
/// Drift откроет базу (см. `main()`). Закрывать открытую базу и менять
/// файл под её дескриптором — ровно тот класс тихой поломки, который
/// потом ищется полевым визитом. Сам обмен — `rename` поверх живого
/// пути: на POSIX он атомарный, поэтому старый файл НЕ удаляется
/// заранее. Удаляются только спутники (`-wal`/`-shm`/`-journal`):
/// журнал прежней базы поверх новой — это порча.
///
/// БУХГАЛТЕРИЯ СИНХРОНИЗАЦИИ НЕ ИМПОРТИРУЕТСЯ НИКОГДА, а пересобирается
/// из восстановленной базы. Причина конкретная: курсоры живут в
/// SharedPreferences, а их стирает удаление. Восстановить полную базу с
/// нулевыми курсорами — значит залить всё заново с первой строки, то
/// есть повторить лавину 04.07, испортившую 53 серверные поездки из 86.
/// Поэтому после подмены курсоры отправки встают в максимальные id: «всё,
/// что здесь есть, уже отправлено».
///
/// СТОРОНА ЗАГРУЗКИ безопасна и без курсоров: применение с сервера
/// идемпотентно по `client_uuid` (`getTripByClientUuid`,
/// `getSnapshotByClientUuid`, `applyPulledAtlasSnapshot`, и то же для
/// reveal-очереди и `trip_series`). Померено на реальных данных 31.07:
/// на 3617 строках пяти таблиц НИ ОДНОЙ без uuid. Поэтому импорт и
/// облако сосуществуют: сервер узнаёт свои строки, а не удваивает их.
///
/// ЧЕГО ИМПОРТ НЕ ВОЗВРАЩАЕТ, сознательно: `client_token` (Keystore, а
/// не prefs — `_kTokenKey` в cloud_sync_service это ключ секретного
/// хранилища), `device_id`, `vehicle_id` и учётные ключи. Иначе
/// телефон, приняв архив с головы, начнёт выдавать себя за неё.
class ImportService {
  /// Формат `prefs.json`. Растёт при смене раскладки записей, а не при
  /// добавлении ключей — список ключей и формат независимы.
  static const int kPrefsFormat = 1;

  static const String kMetaEntry = 'metadata.json';
  static const String kDbEntry = 'samples.sqlite';
  static const String kPrefsEntry = 'prefs.json';

  /// Имя-постоянная копия архива. Существует ровно затем, чтобы импорту
  /// не требовалось перебирать каталог: после удаления приложение не
  /// знает метку времени последнего экспорта, а перечисление
  /// `/storage/emulated/0/Download` на этой прошивке может вернуть
  /// пусто (`listSync` без разрешения). Постоянное имя читается прямым
  /// путём и не зависит ни от перечисления, ни от выбора файла.
  static const String kFixedName = 'bz5_export_latest.zip';

  static const String _pendingDbName = 'bz5_import_pending.sqlite';
  static const String _pendingPrefsName = 'bz5_import_pending_prefs.json';

  /// Имя живой базы. Совпадает с `driftDatabase(name: 'bz5_data')` в
  /// `database.dart` плюс расширение, которое подставляет drift.
  static const String liveDbName = 'bz5_data.sqlite';

  static const String kPendingFlag = 'import_pending';
  static const String kAppliedFlag = 'import_applied';
  static const String kAppliedAt = 'import_applied_at';

  /// НАСТРОЙКИ ВЛАДЕЛЬЦА И МАШИНЫ — едут в каждом архиве.
  ///
  /// Решение владельца 31.07: в облако (третья итерация) уедет только
  /// этот класс, потому что он одинаков везде. Здесь он шире, чем
  /// уедет в облако, и это правильно: архив восстанавливает УСТРОЙСТВО
  /// целиком, а облако переносит владельца между устройствами.
  static const List<String> ownerKeys = <String>[
    'cost_per_kwh',
    'currency_symbol',
    'app_locale',
    'auto_connect_enabled',
    'last_adapter',
    'match_speedometer',
    'hal_source_mode',
    'soc_source',
    'bridge_diag_enabled',
    'advanced_unlocked',
    'speed_profile_active',
    'speed_profile_archive',
    'speed_profile_session',
  ];

  /// КЛЮЧИ, ОПИСЫВАЮЩИЕ БАЗУ, а не устройство и не владельца.
  ///
  /// Едут вместе с базой и только с ней. В облако им нельзя: облако
  /// восстанавливает базу НЕПОЛНО (без `hal_samples`/`samples`), и
  /// бухгалтерия от одной базы поверх другой — рассинхрон.
  ///
  /// `trip_end_anchor_backfill_147` важнее, чем выглядит: потеряв флаг,
  /// приложение прогонит разовый пересчёт якорей заново по
  /// восстановленным поездкам.
  static const List<String> dbBoundKeys = <String>[
    'atlas_ledger',
    'atlas_intent_band',
    'atlas_intent_ms',
    'atlas_intent_win',
    'atlas_insert_fail_total',
    'hal_soh_pending_session',
    'cloud_tsgen_watermark',
    'trip_end_anchor_backfill_147',
  ];

  static List<String> get travellingKeys =>
      <String>[...ownerKeys, ...dbBoundKeys];

  /// Курсор отправки → таблица, чей максимальный id его закрывает.
  ///
  /// ЛИТЕРАЛЫ, А НЕ ССЫЛКИ на приватные константы `CloudSyncService`, и
  /// это осознанно — тот же приём, что в +177 с именами дверей.
  /// Расхождение с сервисом ловит текстовый гейт (`regress` BO2), а не
  /// компилятор, потому что приватную константу из другого файла
  /// компилятор всё равно не отдаст.
  static const Map<String, String> cursorTables = <String, String>{
    'cloud_sync_cursor_trip': 'trips',
    'cloud_sync_cursor_snapshot': 'snapshots',
    'cloud_sync_cursor_sweep': 'sweep_runs',
    'cloud_sync_cursor_livelog': 'live_log_sessions',
    'cloud_sync_cursor_canmonitor': 'can_monitor_sessions',
  };

  /// Сущности с картой uuid → водяной знак. Список из `_uuidMapWm`
  /// в cloud_sync_service.
  static const List<String> uuidMapEntities = <String>['trips', 'snapshots'];

  static const String uuidMapWmPrefix = 'cloud_sync_uuid_map_wm_';
  static const String uuidMapInitialDone = 'cloud_sync_uuid_map_initial_done';

  // ─────────────────────────── экспортная половина ───────────────────

  /// Собрать переезжающие настройки в блок для `prefs.json`.
  ///
  /// Тип берётся у ЗНАЧЕНИЯ во время выполнения, а не из таблицы
  /// «ключ → тип»: такая таблица разошлась бы с кодом при первой смене
  /// типа настройки, и разошлась бы молча.
  static Future<Map<String, Object?>> collectPrefs() async {
    final prefs = await SharedPreferences.getInstance();
    final entries = <Map<String, Object?>>[];
    for (final k in travellingKeys) {
      final v = prefs.get(k);
      if (v == null) continue;
      final String t;
      Object val = v;
      if (v is bool) {
        t = 'b';
      } else if (v is int) {
        t = 'i';
      } else if (v is double) {
        t = 'd';
      } else if (v is String) {
        t = 's';
      } else if (v is List) {
        // `is List<String>` было бы точнее, но shared_preferences в
        // разных версиях отдаёт то `List<String>`, то `List<dynamic>`, и
        // при второй форме точная проверка МОЛЧА пропустила бы ключ —
        // настройка не уехала бы, и узналось бы это при восстановлении.
        t = 'sl';
        val = v.whereType<String>().toList(growable: false);
      } else {
        continue;
      }
      entries.add(<String, Object?>{'k': k, 't': t, 'v': val});
    }
    return <String, Object?>{
      'format': kPrefsFormat,
      'saved_at': DateTime.now().toIso8601String(),
      'entries': entries,
    };
  }

  // ─────────────────────────── поиск архива ──────────────────────────

  /// Каталоги, где может лежать архив, в порядке предпочтения.
  static Future<List<Directory>> _candidateDirs() async {
    final out = <Directory>[];
    final pub = Directory('/storage/emulated/0/Download');
    try {
      if (await pub.exists()) out.add(pub);
    } catch (_) {}
    try {
      final ext = await getExternalStorageDirectory();
      if (ext != null) {
        final d = Directory(p.join(ext.path, 'Downloads'));
        if (await d.exists()) out.add(d);
      }
    } catch (_) {}
    try {
      out.add(await getApplicationDocumentsDirectory());
    } catch (_) {}
    return out;
  }

  /// Найти архив: сначала постоянное имя, потом — самый свежий
  /// `bz5_export_*.zip`. Перечисление каталога вторично именно потому,
  /// что оно может быть недоступно.
  static Future<File?> findArchive() async {
    final dirs = await _candidateDirs();
    for (final d in dirs) {
      final fixed = File(p.join(d.path, kFixedName));
      try {
        if (await fixed.exists()) return fixed;
      } catch (_) {}
    }
    File? newest;
    DateTime? newestAt;
    for (final d in dirs) {
      try {
        for (final e in d.listSync()) {
          if (e is! File) continue;
          final name = p.basename(e.path);
          if (!name.startsWith('bz5_export_') || !name.endsWith('.zip')) {
            continue;
          }
          final at = e.statSync().modified;
          if (newestAt == null || at.isAfter(newestAt)) {
            newest = e;
            newestAt = at;
          }
        }
      } catch (_) {}
    }
    return newest;
  }

  // ─────────────────────────── осмотр архива ────────────────────────

  /// Прочитать архив и сказать, что в нём есть — БЕЗ каких-либо правок.
  ///
  /// Сухой отчёт до подтверждения — не вежливость, а единственная
  /// защита: замена идёт целиком, и владелец должен увидеть числа
  /// заранее.
  static Future<ImportPreview> inspect(
    File zip, {
    required int appSchemaVersion,
  }) async {
    late final Archive archive;
    int sizeBytes = 0;
    try {
      final bytes = await zip.readAsBytes();
      sizeBytes = bytes.length;
      archive = ZipDecoder().decodeBytes(bytes);
    } catch (e) {
      return ImportPreview.bad(zip.path, 'unreadable', '$e');
    }

    ArchiveFile? entry(String name) {
      for (final f in archive.files) {
        if (f.name == name) return f;
      }
      return null;
    }

    final metaFile = entry(kMetaEntry);
    if (metaFile == null) {
      return ImportPreview.bad(zip.path, 'no-metadata', kMetaEntry);
    }

    Map<String, Object?> meta;
    try {
      final raw = utf8.decode(metaFile.content as List<int>);
      final decoded = jsonDecode(raw);
      if (decoded is! Map) {
        return ImportPreview.bad(zip.path, 'bad-metadata', 'not an object');
      }
      meta = Map<String, Object?>.from(decoded);
    } catch (e) {
      return ImportPreview.bad(zip.path, 'bad-metadata', '$e');
    }

    final schema = meta['schema_version'];
    final schemaVersion = schema is int ? schema : -1;
    if (schemaVersion < 0) {
      return ImportPreview.bad(zip.path, 'bad-metadata', 'schema_version');
    }
    // Схема НОВЕЕ нашей — отказ. Drift поднимает старую базу миграцией
    // сам, а опустить новую не может ничем: колонок, которых он не
    // знает, он не удалит, а запросы к отсутствующим полям упадут уже
    // на первом кадре.
    if (schemaVersion > appSchemaVersion) {
      return ImportPreview.bad(
        zip.path,
        'schema-too-new',
        '$schemaVersion > $appSchemaVersion',
      );
    }

    final dbFile = entry(kDbEntry);
    if (dbFile == null) {
      return ImportPreview.bad(zip.path, 'no-db', kDbEntry);
    }
    // Заголовок sqlite — 16 байт магии. Дешевле, чем открыть базу, и
    // ловит обрезанный архив: 29.07 два ZIP подряд приехали усечёнными.
    final dbBytes = dbFile.content as List<int>;
    if (!_looksLikeSqlite(dbBytes)) {
      return ImportPreview.bad(zip.path, 'db-not-sqlite', '${dbBytes.length} B');
    }

    final counts = <String, int>{};
    final rawCounts = meta['counts'];
    if (rawCounts is Map) {
      for (final e in rawCounts.entries) {
        final v = e.value;
        if (v is int) counts['${e.key}'] = v;
      }
    }

    int prefsCount = 0;
    int prefsFormat = 0;
    final prefsFile = entry(kPrefsEntry);
    if (prefsFile != null) {
      try {
        final decoded = jsonDecode(utf8.decode(prefsFile.content as List<int>));
        if (decoded is Map) {
          final f = decoded['format'];
          prefsFormat = f is int ? f : 0;
          final list = decoded['entries'];
          if (list is List) prefsCount = list.length;
        }
      } catch (_) {
        prefsCount = 0;
      }
    }

    final exportedAt = meta['exported_at'];

    return ImportPreview(
      path: zip.path,
      ok: true,
      sizeBytes: sizeBytes,
      dbBytes: dbBytes.length,
      schemaVersion: schemaVersion,
      exportedAt: exportedAt is String ? exportedAt : '',
      counts: counts,
      prefsCount: prefsCount,
      prefsFormat: prefsFormat,
    );
  }

  static bool _looksLikeSqlite(List<int> b) {
    const magic = 'SQLite format 3';
    if (b.length < magic.length + 1) return false;
    for (var i = 0; i < magic.length; i++) {
      if (b[i] != magic.codeUnitAt(i)) return false;
    }
    return true;
  }

  // ─────────────────────────── постановка в очередь ──────────────────

  /// Разложить архив рядом с базой и поднять флаг. Живую базу НЕ
  /// трогает — обмен произойдёт на следующем старте.
  static Future<ImportStageResult> stage(
    File zip, {
    required bool withSettings,
  }) async {
    try {
      final bytes = await zip.readAsBytes();
      final archive = ZipDecoder().decodeBytes(bytes);
      List<int>? db;
      String? prefsJson;
      for (final f in archive.files) {
        if (f.name == kDbEntry) db = f.content as List<int>;
        if (f.name == kPrefsEntry) {
          prefsJson = utf8.decode(f.content as List<int>);
        }
      }
      if (db == null || !_looksLikeSqlite(db)) {
        return ImportStageResult(ok: false, error: 'no-db');
      }

      final support = await getApplicationSupportDirectory();
      final staged = File(p.join(support.path, _pendingDbName));
      await staged.writeAsBytes(db, flush: true);

      final prefsPath = File(p.join(support.path, _pendingPrefsName));
      if (withSettings && prefsJson != null) {
        await prefsPath.writeAsString(prefsJson, flush: true);
      } else {
        // Прошлая незавершённая попытка могла оставить файл. Флаг один,
        // и он не различает «настроек не было» от «настройки старые».
        try {
          if (await prefsPath.exists()) await prefsPath.delete();
        } catch (_) {}
      }

      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(kPendingFlag, true);
      return ImportStageResult(ok: true, stagedBytes: db.length);
    } catch (e) {
      return ImportStageResult(ok: false, error: '$e');
    }
  }

  /// Снять отложенный импорт (владелец передумал до перезапуска).
  static Future<void> cancelPending() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(kPendingFlag);
    try {
      final support = await getApplicationSupportDirectory();
      for (final n in const [_pendingDbName, _pendingPrefsName]) {
        final f = File(p.join(support.path, n));
        if (await f.exists()) await f.delete();
      }
    } catch (_) {}
  }

  static Future<bool> isPending() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(kPendingFlag) ?? false;
  }

  // ─────────────────────── обмен до открытия базы ───────────────────

  /// Зовётся из `main()` ДО `AppDatabase()`. Возвращает null, если
  /// импорт не заказан.
  static Future<ImportApplyResult?> applyPending() async {
    final prefs = await SharedPreferences.getInstance();
    if (!(prefs.getBool(kPendingFlag) ?? false)) return null;

    Directory support;
    try {
      support = await getApplicationSupportDirectory();
    } catch (e) {
      await prefs.remove(kPendingFlag);
      return ImportApplyResult(ok: false, error: 'no-support-dir: $e');
    }

    final staged = File(p.join(support.path, _pendingDbName));
    if (!await staged.exists()) {
      await prefs.remove(kPendingFlag);
      return ImportApplyResult(ok: false, error: 'staged-missing');
    }

    final livePath = p.join(support.path, liveDbName);
    try {
      // Спутники ПРЕЖНЕЙ базы. Оставить их — значит наложить чужой
      // журнал на новый файл. Сама база не удаляется: `rename` ниже
      // заменит её одним шагом, и падение между удалением и
      // переименованием невозможно по построению.
      for (final suffix in const ['-wal', '-shm', '-journal']) {
        final side = File('$livePath$suffix');
        if (await side.exists()) await side.delete();
      }
      await staged.rename(livePath);
    } catch (e) {
      await prefs.remove(kPendingFlag);
      return ImportApplyResult(ok: false, error: 'swap-failed: $e');
    }

    var restored = 0;
    final prefsFile = File(p.join(support.path, _pendingPrefsName));
    try {
      if (await prefsFile.exists()) {
        restored = await _applyPrefsJson(prefs, await prefsFile.readAsString());
        await prefsFile.delete();
      }
    } catch (e) {
      debugPrint('Import: settings skipped — $e');
    }

    await prefs.remove(kPendingFlag);
    await prefs.setBool(kAppliedFlag, true);
    await prefs.setInt(kAppliedAt, DateTime.now().millisecondsSinceEpoch);
    return ImportApplyResult(ok: true, prefsRestored: restored);
  }

  static Future<int> _applyPrefsJson(
    SharedPreferences prefs,
    String raw,
  ) async {
    final decoded = jsonDecode(raw);
    if (decoded is! Map) return 0;
    final list = decoded['entries'];
    if (list is! List) return 0;
    final allowed = travellingKeys.toSet();
    var n = 0;
    for (final e in list) {
      if (e is! Map) continue;
      final k = e['k'];
      final t = e['t'];
      final v = e['v'];
      if (k is! String || t is! String) continue;
      // Белый список ПРОВЕРЯЕТСЯ И НА ВХОДЕ. Архив — файл на общем
      // диске, и доверять его составу нельзя: без этой проверки чужой
      // `prefs.json` мог бы подменить `device_id` или базовый адрес.
      if (!allowed.contains(k)) continue;
      try {
        switch (t) {
          case 'b':
            if (v is bool) {
              await prefs.setBool(k, v);
              n++;
            }
            break;
          case 'i':
            if (v is int) {
              await prefs.setInt(k, v);
              n++;
            }
            break;
          case 'd':
            if (v is num) {
              await prefs.setDouble(k, v.toDouble());
              n++;
            }
            break;
          case 's':
            if (v is String) {
              await prefs.setString(k, v);
              n++;
            }
            break;
          case 'sl':
            if (v is List) {
              await prefs.setStringList(
                k,
                v.whereType<String>().toList(growable: false),
              );
              n++;
            }
            break;
          default:
            break;
        }
      } catch (_) {}
    }
    return n;
  }

  // ─────────────────── пересборка бухгалтерии синхронизации ─────────

  /// Зовётся из `main()` ПОСЛЕ открытия базы. Возвращает null, если
  /// импорта на этом старте не было.
  static Future<Map<String, int>?> rebuildSyncBookkeeping(
    AppDatabase db,
  ) async {
    final prefs = await SharedPreferences.getInstance();
    if (!(prefs.getBool(kAppliedFlag) ?? false)) return null;
    final out = <String, int>{};
    for (final e in cursorTables.entries) {
      final maxId = await _maxId(db, e.value);
      await prefs.setInt(e.key, maxId);
      out[e.value] = maxId;
    }
    for (final ent in uuidMapEntities) {
      await prefs.setInt('$uuidMapWmPrefix$ent', await _maxId(db, ent));
    }
    // Разовый проход, дописывающий uuid отсутствующим строкам, можно
    // объявить сделанным ТОЛЬКО если дописывать нечего. На реальных
    // данных 31.07 пропусков ноль, но архив может быть старым — и тогда
    // соврать здесь означает навсегда оставить строки без опознавания
    // на стороне сервера.
    final gaps = await _uuidGaps(db);
    if (gaps == 0) {
      await prefs.setBool(uuidMapInitialDone, true);
    }
    out['_uuid_gaps'] = gaps;
    await prefs.remove(kAppliedFlag);
    return out;
  }

  static Future<int> _maxId(AppDatabase db, String table) async {
    try {
      final row =
          await db.customSelect('SELECT MAX(id) AS m FROM $table').getSingle();
      final v = row.data['m'];
      return v is int ? v : 0;
    } catch (e) {
      debugPrint('Import: max(id) on $table failed — $e');
      return 0;
    }
  }

  static Future<int> _uuidGaps(AppDatabase db) async {
    var total = 0;
    for (final t in uuidMapEntities) {
      try {
        final row = await db
            .customSelect(
              'SELECT COUNT(*) AS c FROM $t '
              "WHERE client_uuid IS NULL OR client_uuid = ''",
            )
            .getSingle();
        final v = row.data['c'];
        if (v is int) total += v;
      } catch (e) {
        debugPrint('Import: uuid gap scan on $t failed — $e');
      }
    }
    return total;
  }
}

/// Результат осмотра архива. Ничего не менял и меняться не собирается.
class ImportPreview {
  final String path;
  final bool ok;
  final int sizeBytes;
  final int dbBytes;
  final int schemaVersion;
  final String exportedAt;
  final Map<String, int> counts;
  final int prefsCount;
  final int prefsFormat;
  final String? errorCode;
  final String? errorDetail;

  const ImportPreview({
    required this.path,
    required this.ok,
    required this.sizeBytes,
    required this.dbBytes,
    required this.schemaVersion,
    required this.exportedAt,
    required this.counts,
    required this.prefsCount,
    required this.prefsFormat,
    this.errorCode,
    this.errorDetail,
  });

  factory ImportPreview.bad(String path, String code, String detail) =>
      ImportPreview(
        path: path,
        ok: false,
        sizeBytes: 0,
        dbBytes: 0,
        schemaVersion: -1,
        exportedAt: '',
        counts: const <String, int>{},
        prefsCount: 0,
        prefsFormat: 0,
        errorCode: code,
        errorDetail: detail,
      );

  bool get hasSettings => prefsCount > 0;

  String get humanSize {
    if (sizeBytes >= 1024 * 1024) {
      return '${(sizeBytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    return '${(sizeBytes / 1024).toStringAsFixed(0)} KB';
  }

  /// «trips=135, snapshots=3257, …» — только непустые.
  String get countsSummary => counts.entries
      .where((e) => e.value > 0)
      .map((e) => '${e.key}=${e.value}')
      .join(', ');
}

class ImportStageResult {
  final bool ok;
  final int stagedBytes;
  final String? error;
  const ImportStageResult({
    required this.ok,
    this.stagedBytes = 0,
    this.error,
  });
}

class ImportApplyResult {
  final bool ok;
  final int prefsRestored;
  final String? error;
  const ImportApplyResult({
    required this.ok,
    this.prefsRestored = 0,
    this.error,
  });
}
