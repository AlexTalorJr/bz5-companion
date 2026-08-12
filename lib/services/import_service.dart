import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../data/database.dart';
import 'autostart_arm.dart';

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

  /// v0.1.88+187 — ПОСТОЯННОЕ ИМЯ ОКАЗАЛОСЬ НЕДОСТАТОЧНЫМ, И ВОТ ПОЧЕМУ.
  ///
  /// Поле 02.08 отдало отказ, которого этот файл не предусматривал:
  ///
  ///     PathAccessException: Cannot open file, path =
  ///     '/storage/emulated/0/Download/bz5_export_latest.zip'
  ///     (OS Error: Permission denied, errno = 13)
  ///
  /// Удаление приложения меняет uid (маркер 31.07 — `user 10163`, маркер
  /// 02.08 — `user 10330`). Файл переживает удаление, ВЛАДЕНИЕ им — нет,
  /// а под scoped storage чужой не-медийный файл в Downloads по прямому
  /// пути не открывается ничем: `READ_EXTERNAL_STORAGE` при `targetSdk`
  /// 35 даёт только медиа, а экрана выдачи `MANAGE_EXTERNAL_STORAGE` на
  /// этой прошивке нет (0 резолверов, замер 30.07).
  ///
  /// Отсюда вывод, который стоит записать прямо: НИ ОДИН файл в публичных
  /// Downloads не переживает переустановку в смысле ЧИТАЕМОСТИ. Каждая
  /// установка читает только то, что написала сама, а её собственные
  /// файлы становятся чужими для следующей. Поэтому постоянное имя
  /// остаётся первой ступенью (вдруг прошивка мягче), но опорой быть
  /// перестаёт — опорой становится файл, полученный ПО ГРАНТУ: через
  /// выбор файла или «поделиться». Грант к uid не привязан.
  static const String kStagedName = 'imported_archive.zip';

  static const String _pendingDbName = 'bz5_import_pending.sqlite';
  static const String _pendingPrefsName = 'bz5_import_pending_prefs.json';

  /// Имя живой базы. Совпадает с `driftDatabase(name: 'bz5_data')` в
  /// `database.dart` плюс расширение, которое подставляет drift.
  static const String liveDbName = 'bz5_data.sqlite';

  static const String kPendingFlag = 'import_pending';
  static const String kAppliedFlag = 'import_applied';
  static const String kAppliedAt = 'import_applied_at';

  /// v0.1.83+182 — ОТЧЁТ О ВОССТАНОВЛЕНИИ. Долг наблюдаемости, найденный
  /// полем 31.07: `import_applied_at` писался и не читался НИКЕМ, а
  /// единственным следом успеха были две строки `Import:` в журнале
  /// приложения. Поле подтвердило импорт только потому, что владелец
  /// заранее развёл значения настроек, — то есть различающим опытом, а не
  /// показаниями приложения.
  ///
  /// Два ключа, и они разные по смыслу: ОБЕЩАНИЕ пишется при постановке в
  /// очередь (из `metadata.json` архива), ФАКТ — после применения, из
  /// живой базы. Сравнивать одно с другим и есть весь отчёт: числа сошлись
  /// — восстановление полное, разошлись — видно, где и на сколько.
  static const String kPromise = 'import_promise';
  static const String kReport = 'import_report';

  /// Таблицы, по которым отчёт сверяет обещание с фактом. Порядок — тот, в
  /// котором они показываются владельцу.
  ///
  /// `hal_samples` СТОИТ ПЕРВЫМ, и это не алфавит. Именно ради них импорт и
  /// затевался: облако несёт всё остальное, а сырьё умирает с очисткой. При
  /// этом до +181 их не показывал ни один экран — «сверить главное число
  /// нечем» и означало ровно это.
  static const List<String> reportTables = <String>[
    'hal_samples',
    'trips',
    'snapshots',
    'sweep_runs',
    'live_log_sessions',
  ];

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
    // v0.1.90+189: знак фонового строителя описывает БАЗУ — он говорит,
    // до какого места её строки уже разобраны. Уехав без него, архив
    // заставил бы строителя перечитать всю историю стоянок заново.
    'bg_trip_watermark_ms',
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
  /// в cloud_sync_service — теперь ЦЕЛИКОМ, а не первые две.
  ///
  /// v0.1.90+189 — ПОЧЕМУ ЭТО БЫЛО НЕСУЩИМ, А НЕ КОСМЕТИКОЙ. Список
  /// обслуживал два разных дела сразу, и оба делал наполовину:
  ///
  ///   1. переставлял водяные знаки после импорта — для трёх сущностей
  ///      из пяти не переставлял, и клиент слал серверу пары «новый
  ///      локальный id → uuid» по строкам, чьи id могли сдвинуться;
  ///   2. считал строки без uuid, чтобы решить, можно ли объявить
  ///      начальный проход законченным. В `sweep_runs`,
  ///      `live_log_sessions` и `can_monitor_sessions` он НЕ ЗАГЛЯДЫВАЛ
  ///      ВОВСЕ — а Друг 2 справкой 02.08 показал, что строки без uuid
  ///      там существуют: девять штук в каноне.
  ///
  /// Второе опаснее. Объявив проход законченным при живых пропусках,
  /// клиент запирает их навсегда: сериализатор пропускает строку без
  /// uuid, отображение пропускает строку без uuid, а сканер её не
  /// считал. Комментарий над сканером обещал ровно обратное — «соврать
  /// здесь означает навсегда оставить строки без опознавания на стороне
  /// сервера».
  static const List<String> uuidMapEntities = <String>[
    'trips',
    'snapshots',
    'sweeps',
    'livelogs',
    'canmonitor',
  ];

  /// Имя сущности в протоколе → имя таблицы в базе.
  ///
  /// ЛОВУШКА, ИЗ-ЗА КОТОРОЙ ОДНИМ СПИСКОМ НЕ ОБОЙТИСЬ: у трёх сущностей
  /// из пяти имя в протоколе и имя таблицы РАЗНЫЕ (`sweeps` против
  /// `sweep_runs`), а прежний код подставлял имя сущности прямо в
  /// `SELECT ... FROM $t`. Расширь мы список, не заведя эту карту, —
  /// сканер пропусков падал бы на несуществующей таблице, ловил
  /// исключение и возвращал ноль. То есть выглядел бы как «пропусков
  /// нет» ровно там, где они есть.
  static const Map<String, String> uuidMapTables = <String, String>{
    'trips': 'trips',
    'snapshots': 'snapshots',
    'sweeps': 'sweep_runs',
    'livelogs': 'live_log_sessions',
    'canmonitor': 'can_monitor_sessions',
  };

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
  ///
  /// v0.1.88+187: первым идёт СВОЙ каталог. Туда кладёт файл нативная
  /// сторона, получив его по гранту (выбор файла или «поделиться»), и
  /// это единственное место, читаемость которого не зависит от того,
  /// какой uid был у прошлой установки.
  static Future<List<Directory>> _candidateDirs() async {
    final out = <Directory>[];
    try {
      // Соответствует `context.filesDir` на стороне Kotlin — туда пишет
      // `ApkInstall.stageArchive`. Пара «Dart support dir ↔ Kotlin
      // filesDir» задана path_provider на Android и здесь не выводится
      // из общих соображений, а взята как контракт плагина.
      out.add(await getApplicationSupportDirectory());
    } catch (_) {}
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

  /// ЧИТАЕМ ЛИ ФАЙЛ НА САМОМ ДЕЛЕ.
  ///
  /// v0.1.88+187 — сердце патча. До него поиск возвращал файл по
  /// `exists()`, а `exists()` на чужом файле отвечает ПРАВДУ: `stat`
  /// разрешён, `open` — нет. Отсюда полевой отказ 02.08: нечитаемый
  /// `bz5_export_latest.zip` от прежней установки возвращался первым, и
  /// перечисление каталога, которое нашло бы наш собственный свежий
  /// архив, не выполнялось НИКОГДА — до него не доходило управление.
  ///
  /// Читаем один байт, а не весь файл: цена ошибки здесь — выбор не того
  /// кандидата, а не порча, и держать десятки мегабайт в памяти ради
  /// ответа «пускают ли» незачем.
  static Future<String?> _openFailure(File f) async {
    RandomAccessFile? h;
    try {
      h = await f.open();
      final len = await f.length();
      if (len <= 0) return 'empty';
      await h.read(1);
      // v0.1.93+192 — ОТКРЫВАЕТСЯ ЕЩЁ НЕ ЗНАЧИТ ПРИГОДЕН.
      //
      // Поле 03.08: обрезанный архив открывался прекрасно и получал в
      // списке зелёную галочку с размером, а осмотр потом отказывал
      // `FormatException`. Владелец видел одобрение и отказ рядом и не
      // мог понять, какое из них про его файл.
      //
      // Конец zip-архива — запись `PK\x05\x06` (End of Central
      // Directory) в последних 64 КБ. Её отсутствие означает, что файл
      // недописан или недокопирован, и решается это ЗДЕСЬ, до выбора:
      // иначе `searchArchive` предложит обрезанный файл, имея рядом
      // целый. Читаем хвост, а не весь файл: цена вопроса — один блок.
      final tailLen = len < 65536 ? len : 65536;
      await h.setPosition(len - tailLen);
      final tail = await h.read(tailLen);
      if (!hasZipTail(tail)) return 'truncated';
      return null;
    } catch (e) {
      return e is PathAccessException
          ? 'denied'
          : e.runtimeType.toString();
    } finally {
      try {
        await h?.close();
      } catch (_) {}
    }
  }

  /// Есть ли в хвосте признак конца zip-архива.
  ///
  /// v0.1.93+192 — ПУБЛИЧНАЯ, потому что проверку зовут ДВА пути: осмотр
  /// кандидата здесь и самопроверка записи в `export_service`. Первая
  /// редакция патча имела две копии этого скана; ревизия показала, что
  /// сверить их между собой нечем, а разойдись они — экспорт и импорт
  /// стали бы по-разному понимать, что такое дописанный файл.
  ///
  /// Ищем подпись задом наперёд: у настоящей записи после неё стоит
  /// комментарий переменной длины, поэтому последнее вхождение —
  /// правильное. Разбирать структуру полностью незачем: предмет — «файл
  /// дописан до конца», а не «архив корректен во всех деталях», это
  /// проверит осмотр.
  static bool hasZipTail(List<int> tail) {
    for (var i = tail.length - 4; i >= 0; i--) {
      if (tail[i] == 0x50 &&
          tail[i + 1] == 0x4B &&
          tail[i + 2] == 0x05 &&
          tail[i + 3] == 0x06) {
        return true;
      }
    }
    return false;
  }

  /// Все кандидаты, каждый со своим приговором.
  ///
  /// Список, а не первый подходящий, потому что владельцу нужно видеть
  /// РАЗНИЦУ между «файла нет» и «файл есть, но не пускают»: это два
  /// разных действия с его стороны, а прежний экран показывал их одной
  /// красной строкой.
  static Future<List<ArchiveCandidate>> _findArchiveCandidates() async {
    final dirs = await _candidateDirs();
    final seen = <String>{};
    final out = <ArchiveCandidate>[];

    Future<void> consider(File f, String origin) async {
      final path = f.path;
      if (!seen.add(path)) return;
      final reason = await _openFailure(f);
      var size = 0;
      if (reason == null) {
        try {
          size = await f.length();
        } catch (_) {}
      }
      out.add(ArchiveCandidate(
        path: path,
        origin: origin,
        readable: reason == null,
        reason: reason,
        sizeBytes: size,
      ));
    }

    // Ступень 1 — имена, известные без перечисления.
    //
    // Источник у принятой копии свой (`staged`), и это не косметика:
    // файл остаётся в нашем каталоге и после импорта, поэтому в
    // следующий раз он появится в списке наравне со свежими. Владелец
    // должен видеть, что это принятая когда-то копия, а не найденный
    // сейчас архив; дату он всё равно увидит в сухом отчёте до
    // подтверждения, но узнать её лучше раньше.
    final names = <String>[kStagedName, kFixedName];
    for (final d in dirs) {
      for (final n in names) {
        final f = File(p.join(d.path, n));
        try {
          if (!await f.exists()) continue;
        } catch (_) {
          continue;
        }
        await consider(f, n == kStagedName ? 'staged' : 'fixed');
      }
    }

    // Ступень 2 — перечисление. Может вернуть пусто или бросить: под
    // scoped storage чужие файлы в перечислении не показываются вовсе.
    // Это не ошибка и не повод молчать — просто ступень, которой на
    // этой прошивке может не быть.
    //
    // v0.2.4+203 — ОСТАЁТСЯ В КОДЕ, УХОДИТ ИЗ ВЫВОДА. На головном
    // устройстве эта ступень отказывает ВСЕГДА: право чтения внешнего
    // хранилища объявлено до SDK 29, а прибор SDK 32, и журнал 11.08
    // показывает `bz5_export_latest.zip:denied` на каждом проходе. На
    // телефоне она живая и остаётся единственным способом найти файл,
    // который никто не отдавал приложению.
    //
    // Поэтому удалять нечего, а её кандидаты уехали в свёрнутый блок
    // «Не получилось?» на экране данных: в общем выводе они говорили
    // владельцу «отказано» там, где обычный путь уже сработал.
    // Стоимость ступени — один `listSync` внутри try.
    for (final d in dirs) {
      final found = <File>[];
      try {
        for (final e in d.listSync()) {
          if (e is! File) continue;
          final name = p.basename(e.path);
          if (!name.startsWith('bz5_export_') || !name.endsWith('.zip')) {
            continue;
          }
          found.add(e);
        }
      } catch (_) {
        continue;
      }
      found.sort((a, b) {
        try {
          return b.statSync().modified.compareTo(a.statSync().modified);
        } catch (_) {
          return 0;
        }
      });
      for (final f in found) {
        await consider(f, 'listing');
      }
    }
    return out;
  }

  /// ЕСТЬ ЛИ ПРИНЯТАЯ КОПИЯ — ДЁШЕВО И БЕЗ ПОБОЧНЫХ ДЕЙСТВИЙ.
  ///
  /// v0.1.97+196, находка собственной ревизии. Полосу «принят архив»
  /// первая редакция кормила из списка кандидатов, а список наполняется
  /// только после того, как владелец нажмёт «найти архив». То есть
  /// извещение появлялось ровно тогда, когда оно уже не нужно: список и
  /// так на экране. Ради этого патч и затевался, и он бы промахнулся.
  ///
  /// Отдельный метод, а не `searchArchive`: тот спрашивает разрешение,
  /// перечисляет четыре каталога и меняет состояние экрана. Звать его
  /// при открытии нельзя — запрос разрешения обязан стоять на явном
  /// действии владельца (правило +192).
  ///
  /// Смотрит ТОЛЬКО собственный каталог: туда кладут файл и «поделиться»,
  /// и выбор файла. Решение «какой архив брать» здесь не принимается и
  /// остаётся одно, в `searchArchive` — это извещение, а не выбор.
  ///
  /// После успешно применённого импорта файл удаляется, поэтому полоса
  /// гаснет сама и не висит вечным напоминанием о давнем восстановлении.
  static Future<ArchiveCandidate?> stagedCopy() async {
    try {
      final support = await getApplicationSupportDirectory();
      final f = File(p.join(support.path, kStagedName));
      if (!await f.exists()) return null;
      final why = await _openFailure(f);
      var size = 0;
      if (why == null) {
        try {
          size = await f.length();
        } catch (_) {}
      }
      return ArchiveCandidate(
        path: f.path,
        origin: 'staged',
        readable: why == null,
        reason: why,
        sizeBytes: size,
      );
    } catch (_) {
      return null;
    }
  }

  /// ПОИСК И ВЫБОР — ОДНОЙ ОПЕРАЦИЕЙ, И ЭТО ВАЖНО.
  ///
  /// Первая редакция +187 отдавала наружу список, а выбирать давала
  /// экрану. Ревизия показала, чем это плохо: решение «какой архив
  /// брать» оказалось размазано между сервисом и виджетом, `findArchive`
  /// осталась без единого вызова, а гейт BU1 сторожил мёртвую функцию —
  /// то есть был вакуумным, и мутация этого не видит по построению
  /// (она доказывает, что гейт реагирует на свой предмет, но не то, что
  /// предмет лежит на живом пути).
  ///
  /// Теперь наружу уходит и список, и выбор, сделанный ЗДЕСЬ. У экрана
  /// не остаётся ни повода, ни возможности выбирать самому.
  static Future<ArchiveSearch> searchArchive() async {
    final all = await _findArchiveCandidates();
    ArchiveCandidate? chosen;
    for (final c in all) {
      if (c.readable) {
        chosen = c;
        break;
      }
    }
    // ── СТРОКА В ФАЙЛ-ЖУРНАЛ. v0.1.97+196 ──
    //
    // Поле 05.08: «захожу в раздел, архива в списке не видно». Пустой
    // список означает три разных вещи — искали не там, файл не нашёлся,
    // файл нашёлся и не открылся, — и ни одну из них экран не различал
    // для того, кто смотрит потом. Здесь список уходит в файл целиком:
    // сколько кандидатов, кто выбран, и по какой причине отвергнуты
    // остальные.
    //
    // Не больше четырёх причин: журнал читает человек, а каталогов у нас
    // четыре, и длинный хвост однотипных отказов только мешает.
    // Причина, а не `c.readable`: слово `readable` в теле этой функции —
    // предмет гейта BU1, и наблюдательная строка, упомянув его, держала
    // бы гейт зелёным после подмены самого выбора. Пустая причина и
    // означает «открылся».
    final why = all
        .take(4)
        .map((c) => '${p.basename(c.path)}:${c.reason ?? 'ok'}')
        .join(' ');
    await AutostartArm.write(
      'import-see: found=${all.length}'
      ' chosen=${chosen == null ? '-' : p.basename(chosen.path)}'
      ' ${why.isEmpty ? '(пусто)' : why}',
    );
    return ArchiveSearch(candidates: all, chosen: chosen);
  }

  // ─────────────────────────── осмотр архива ────────────────────────

  /// Прочитать архив и сказать, что в нём есть — БЕЗ каких-либо правок.
  ///
  /// Сухой отчёт до подтверждения — не вежливость, а единственная
  /// защита: замена идёт целиком, и владелец должен увидеть числа
  /// заранее.
  /// ЧТО ВНУТРИ АРХИВА — В ФАЙЛ-ЖУРНАЛ. v0.1.97+196.
  ///
  /// Самая нужная строка из шести. Владелец 05.08 отдал приложению
  /// экспорт на 28 КБ, снятый с только что установленной пустой копии, и
  /// час разбирался, почему «восстановление не работает». Внутри было
  /// ноль поездок; сказать об этом было некому — разбор уходил в кольцо
  /// в памяти.
  ///
  /// Обёртка, а не запись в теле: у осмотра девять точек возврата, и
  /// строка в каждой из них разошлась бы с кодом при первой же правке.
  /// Здесь выход один, и он же единственное место записи.
  static Future<ImportPreview> inspect(
    File zip, {
    required int appSchemaVersion,
  }) async {
    final seen = await _inspect(zip, appSchemaVersion: appSchemaVersion);
    final counts = seen.countsSummary;
    await AutostartArm.write(
      'import-read: ok=${seen.ok}'
      ' name=${p.basename(zip.path)}'
      ' bytes=${seen.sizeBytes}'
      ' schema=${seen.schemaVersion}'
      ' at=${seen.exportedAt.isEmpty ? '-' : seen.exportedAt}'
      ' inside=${counts.isEmpty ? '(пусто)' : counts}'
      ' err=${seen.ok ? '-' : '${seen.errorCode}/${seen.errorDetail}'}',
    );
    return seen;
  }

  static Future<ImportPreview> _inspect(
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
      String? metaJson;
      for (final f in archive.files) {
        if (f.name == kDbEntry) db = f.content as List<int>;
        if (f.name == kMetaEntry) {
          metaJson = utf8.decode(f.content as List<int>);
        }
        if (f.name == kPrefsEntry) {
          prefsJson = utf8.decode(f.content as List<int>);
        }
      }
      if (db == null || !_looksLikeSqlite(db)) {
        await AutostartArm.write('import-queue: ok=false err=no-db');
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
      // ОБЕЩАНИЕ. Читается здесь, а не при применении: после обмена файла
      // архив может быть уже недоступен (общий диск, чужой uid после
      // переустановки), а `metadata.json` в нём — единственное место, где
      // записано, СКОЛЬКО строк обещано. Отказ разбора не мешает импорту:
      // отчёт станет односторонним (только факт), и это лучше, чем сорвать
      // восстановление из-за испорченного манифеста.
      await prefs.remove(kPromise);
      if (metaJson != null) {
        try {
          final meta = jsonDecode(metaJson);
          final counts = (meta is Map) ? meta['counts'] : null;
          if (counts is Map) {
            final promise = <String, int>{};
            for (final t in reportTables) {
              final v = counts[t];
              if (v is int) promise[t] = v;
            }
            if (promise.isNotEmpty) {
              await prefs.setString(kPromise, jsonEncode(promise));
            }
          }
        } catch (e) {
          debugPrint('Import: manifest promise unreadable — $e');
        }
      }
      await prefs.setBool(kPendingFlag, true);
      await AutostartArm.write(
        'import-queue: ok=true db_bytes=${db.length}'
        ' prefs=${withSettings && prefsJson != null ? 'yes' : 'no'}'
        ' promise=${prefs.getString(kPromise) ?? '-'}',
      );
      return ImportStageResult(ok: true, stagedBytes: db.length);
    } catch (e) {
      await AutostartArm.write('import-queue: ok=false err=$e');
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
      await AutostartArm.write('import-apply: ok=false err=no-support-dir: $e');
      return ImportApplyResult(ok: false, error: 'no-support-dir: $e');
    }

    final staged = File(p.join(support.path, _pendingDbName));
    if (!await staged.exists()) {
      await prefs.remove(kPendingFlag);
      await AutostartArm.write('import-apply: ok=false err=staged-missing');
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
      await AutostartArm.write('import-apply: ok=false err=swap-failed: $e');
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
    await AutostartArm.write('import-apply: ok=true prefs=$restored');
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
      // Ключ знака — имя СУЩНОСТИ, запрос — имя ТАБЛИЦЫ. Раньше это было
      // одно и то же слово только потому, что список кончался на
      // снапшотах.
      final table = uuidMapTables[ent];
      if (table == null) continue;
      await prefs.setInt('$uuidMapWmPrefix$ent', await _maxId(db, table));
    }
    // Разовый проход, дописывающий uuid отсутствующим строкам, можно
    // объявить сделанным ТОЛЬКО если дописывать нечего. На реальных
    // данных 31.07 пропусков ноль, но архив может быть старым — и тогда
    // соврать здесь означает навсегда оставить строки без опознавания
    // на стороне сервера.
    // v0.1.88+187 — ПРИНЯТАЯ КОПИЯ БОЛЬШЕ НЕ НУЖНА, И ХРАНИТЬ ЕЁ ВРЕДНО.
    //
    // Две причины, и вторая важнее. Копия весит столько же, сколько
    // экспорт (на 02.08 это 21 МБ), и на ГУ это заметно. Но главное —
    // она осталась бы в списке кандидатов НАВСЕГДА и при каждом
    // следующем поиске предлагалась бы первой, будучи месячной
    // давности. Сухой отчёт с датой перед подтверждением это поймал бы,
    // но полагаться на внимательность там, где хватает удаления, не
    // стоит.
    //
    // Удаляется ТОЛЬКО после успешно применённого импорта: отмена и
    // неудача обязаны оставить файл на месте, иначе повторная попытка
    // потребует снова искать его в проводнике.
    try {
      final support = await getApplicationSupportDirectory();
      final staged = File(p.join(support.path, kStagedName));
      if (await staged.exists()) await staged.delete();
    } catch (e) {
      debugPrint('Import: staged archive cleanup skipped — $e');
    }

    final gaps = await _uuidGaps(db);
    if (gaps == 0) {
      await prefs.setBool(uuidMapInitialDone, true);
    }
    out['_uuid_gaps'] = gaps;
    // v0.1.83+182: ФАКТ, и сразу же отчёт. Считается здесь потому, что
    // здесь единственное место, где одновременно доступны живая база и
    // ещё не снятый флаг применения. Отказ подсчёта не должен помешать
    // снятию флага — иначе бухгалтерия пересобиралась бы на каждом
    // старте.
    try {
      await _writeReport(db, prefs);
    } catch (e) {
      debugPrint('Import: report failed — $e');
    }
    await prefs.remove(kAppliedFlag);
    return out;
  }

  /// Сложить обещание и факт в один отчёт и запомнить его. Читается
  /// экраном данных один раз, после чего снимается владельцем.
  static Future<void> _writeReport(
    AppDatabase db,
    SharedPreferences prefs,
  ) async {
    Map<String, int> promise = const {};
    final raw = prefs.getString(kPromise);
    if (raw != null) {
      try {
        final m = jsonDecode(raw);
        if (m is Map) {
          promise = m.map((k, v) => MapEntry('$k', v is int ? v : 0));
        }
      } catch (_) {}
    }
    final actual = <String, int>{};
    for (final t in reportTables) {
      actual[t] = await _rowCount(db, t);
    }
    await prefs.setString(
      kReport,
      jsonEncode({
        'at': DateTime.now().millisecondsSinceEpoch,
        'promise': promise,
        'actual': actual,
      }),
    );
    await prefs.remove(kPromise);
    // ШЕСТАЯ СТРОКА: обещано против получено. v0.1.97+196.
    //
    // Отчёт до сих пор жил только в настройках и показывался на экране
    // данных ОДИН раз, после чего снимался владельцем. То есть свидетель
    // главного вопроса — «доехали ли строки» — исчезал раньше, чем о нём
    // успевали спросить. Копия в файл-журнал не снимается никем.
    //
    // Сверяем только те таблицы, где обещание есть: сверка по всему
    // списку жаловалась бы на чужую длину, как 04.08.
    final pairs = <String>[];
    for (final t in reportTables) {
      final want = promise[t];
      if (want == null) continue;
      pairs.add('$t ${actual[t] ?? 0}/$want');
    }
    await AutostartArm.write(
      'import-report: ${pairs.isEmpty ? 'обещания не было' : pairs.join(' ')}',
    );
  }

  /// Отчёт для показа, или null — импорта не было либо владелец его снял.
  static Future<ImportReport?> readReport() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(kReport);
    if (raw == null) return null;
    try {
      final m = jsonDecode(raw);
      if (m is! Map) return null;
      final at = m['at'];
      final pr = m['promise'];
      final ac = m['actual'];
      return ImportReport(
        at: at is int
            ? DateTime.fromMillisecondsSinceEpoch(at)
            : DateTime.now(),
        promise: pr is Map
            ? pr.map((k, v) => MapEntry('$k', v is int ? v : 0))
            : const {},
        actual: ac is Map
            ? ac.map((k, v) => MapEntry('$k', v is int ? v : 0))
            : const {},
      );
    } catch (e) {
      debugPrint('Import: report unreadable — $e');
      return null;
    }
  }

  static Future<void> clearReport() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(kReport);
  }

  /// COUNT(*) по имени таблицы. Имена приходят только из [reportTables] —
  /// константы этого файла, а не из данных, поэтому подстановка безопасна.
  static Future<int> _rowCount(AppDatabase db, String table) async {
    try {
      final row = await db
          .customSelect('SELECT COUNT(*) AS c FROM $table')
          .getSingle();
      final v = row.data['c'];
      return v is int ? v : 0;
    } catch (e) {
      debugPrint('Import: count on $table failed — $e');
      return 0;
    }
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
    for (final t in uuidMapTables.values) {
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

/// v0.1.88+187 — ИТОГ ПОИСКА: что нашлось и что из этого выбрано.
///
/// Пара, а не два вызова, потому что выбор обязан быть сделан там же,
/// где собран список: разойдись они — и «показали одно, восстановили
/// другое» станет возможным молча.
class ArchiveSearch {
  final List<ArchiveCandidate> candidates;

  /// Первый читаемый. null — читаемых нет вовсе.
  final ArchiveCandidate? chosen;

  const ArchiveSearch({required this.candidates, this.chosen});

  bool get hasReadable => chosen != null;

  /// Ничего не нашлось совсем — против «нашлось, но не пускают».
  bool get isEmpty => candidates.isEmpty;
}

/// v0.1.88+187 — ОДИН КАНДИДАТ И ПРИГОВОР ПО НЕМУ.
///
/// Существует ради различения, которого не было: «файла нет» и «файл
/// есть, открыть не дают» требуют от владельца разных действий, а
/// прежний экран сводил оба к одной оранжевой строке. `denied` теперь
/// читается как «этот архив написан прежней установкой» и ведёт к
/// кнопке выбора файла, а не к недоумению.
class ArchiveCandidate {
  final String path;

  /// `fixed` — найден по известному имени, `listing` — перечислением.
  final String origin;
  final bool readable;

  /// null, когда читается. Иначе `denied`, `empty` или имя типа
  /// исключения.
  final String? reason;
  final int sizeBytes;

  const ArchiveCandidate({
    required this.path,
    required this.origin,
    required this.readable,
    required this.reason,
    required this.sizeBytes,
  });

  String get fileName => p.basename(path);

  String get humanSize {
    if (sizeBytes <= 0) return '—';
    if (sizeBytes < 1024 * 1024) {
      return '${(sizeBytes / 1024).toStringAsFixed(0)} KB';
    }
    return '${(sizeBytes / (1024 * 1024)).toStringAsFixed(1)} MB';
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

/// v0.1.83+182: отчёт о восстановлении. Обещание манифеста против факта
/// живой базы, по таблице.
///
/// `promise` может быть пустым (манифест не прочитался) — тогда отчёт
/// односторонний, и экран обязан сказать «обещание неизвестно», а не
/// показать ноль. Ноль и «неизвестно» — разные вещи, и именно смешение
/// этих двух и стоило окну №10 двух сообщений.
class ImportReport {
  final DateTime at;
  final Map<String, int> promise;
  final Map<String, int> actual;

  const ImportReport({
    required this.at,
    required this.promise,
    required this.actual,
  });

  /// Есть ли с чем сверять.
  bool get twoSided => promise.isNotEmpty;

  /// Совпало ли всё, что обещано. Таблицы без обещания не считаются.
  bool get complete =>
      twoSided &&
      promise.entries.every((e) => (actual[e.key] ?? -1) >= e.value);

  /// Обещание по таблице, или null, если его нет.
  int? promised(String table) => promise[table];

  int restored(String table) => actual[table] ?? 0;
}
