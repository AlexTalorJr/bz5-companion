// v0.1.73+172 — Dart-сторона пути установки.
//
// Обновиться на ГУ нечем: проводник APK не запускает, ADB нет, а
// SilentInstaller на существующий пакет отвечает 系统已安装 и
// засчитывает это в успех, то есть установку не начинает. Пока
// обновление идёт через удаление, каждый патч стирает prefs и Drift, а
// из облака не возвращаются samples/hal_samples и недобранные полосы
// атласа. Установка поверх сохранила бы всё.
//
// Канал зеркалит ApkInstall.kt один в один и НИЧЕГО не решает сам:
// любое суждение о том, жив ли системный установщик, принимается по
// данным пробы, а не по догадке на стороне Dart.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;

class ApkInstallChannel {
  ApkInstallChannel._();

  static const MethodChannel _ch = MethodChannel('bz5/apkinstall');

  /// Только чтение. Безопасно звать где угодно, в том числе на
  /// телефоне — там просто вернётся другой набор резолверов.
  static Future<Map<String, dynamic>> probe() => _call('probe');

  /// Системный выбор файла (SAF). Ответ приходит после закрытия
  /// диалога: `{ok, uri}` или `{ok: false, error}`.
  static Future<Map<String, dynamic>> pick() => _call('pick');

  /// Выбор файла через ACTION_GET_CONTENT — другое действие, чем
  /// ACTION_OPEN_DOCUMENT, и на этой прошивке оно живо (поле 30.07).
  static Future<Map<String, dynamic>> pickContent() => _call('pickContent');

  /// Копия выбранного в кэш приложения. `{ok, bytes, source_name}`.
  static Future<Map<String, dynamic>> stage(String uri) =>
      _call('stage', {'uri': uri});

  /// v0.1.88+187 — тот же выбранный файл, но в слот АРХИВА
  /// (`filesDir/imported_archive.zip`, читается импортом).
  /// `{ok, bytes, source_name, path}`.
  ///
  /// Отдельно от `stage` намеренно: слот APK лежит в кэше и его
  /// переиспользует скачивание сборки. Общий слот означал бы, что
  /// проверка обновления затирает принятый архив.
  static Future<Map<String, dynamic>> stageArchive(String uri) =>
      _call('stageArchive', {'uri': uri});

  /// v0.1.88+187 — три пробы хранилища, только чтение. Отвечает на
  /// вопрос, какая ступень доступа к файлу на этой прошивке живая:
  /// перечисление, MediaStore, выбор файла, приём «поделиться».
  static Future<Map<String, dynamic>> storageProbe() =>
      _call('storageProbe');

  /// Отдать подготовленный файл установщику. `{ok, action, steps}`.
  /// resultCode приезжает не сюда, а в журнал автозапуска: ответ
  /// установщика — главный неизвестный факт темы, и терять его из-за
  /// того, что этот Future уже завершился, нельзя.
  static Future<Map<String, dynamic>> launch() => _call('launch');

  /// Экран «установка из неизвестных источников» для нашего пакета.
  static Future<Map<String, dynamic>> unknownSources() =>
      _call('unknownSources');

  // ── v0.1.77+176 — §A1: свой обозреватель ──────────────────────────

  /// Спросить у владельца ТОМ (флешку) через SAF-дерево. Ответ
  /// приходит после закрытия диалога: `{ok, uri, tree}`.
  static Future<Map<String, dynamic>> openTree() => _call('openTree');

  /// Закрепить отданное дерево — грант переживает перезагрузку.
  static Future<Map<String, dynamic>> rememberTree(String uri) =>
      _call('rememberTree', {'uri': uri});

  /// Найти APK всеми открытыми путями. `{ok, apks, notes}`.
  static Future<Map<String, dynamic>> listApks() => _call('listApks');

  /// Открыть названную дверь из пробы. Имя — ровно то, что стоит
  /// ключом в `probe()['doors']`.
  static Future<Map<String, dynamic>> openDoor(String door) =>
      _call('openDoor', {'door': door});

  /// Куда писать скачанное, чтобы провайдер это увидел. Путь берётся у
  /// нативной стороны, а не собирается здесь: «cacheDir и
  /// getTemporaryDirectory это одно и то же» — верное, но
  /// непроверенное здесь утверждение, а цена ошибки — цикл установки.
  static Future<Map<String, dynamic>> stagedPath() => _call('stagedPath');

  /// Единая точка: платформенный отказ не должен ронять экран —
  /// на телефоне без нативной части канала просто нет, и это
  /// нормальный ответ, а не сбой.
  static Future<Map<String, dynamic>> _call(
    String method, [
    Map<String, dynamic>? args,
  ]) async {
    try {
      final res = await _ch.invokeMapMethod<String, dynamic>(method, args);
      return res ?? <String, dynamic>{'ok': false, 'error': 'null reply'};
    } catch (e) {
      debugPrint('ApkInstall.$method failed: $e');
      return <String, dynamic>{'ok': false, 'error': '$e'};
    }
  }
}

/// Чем закончился поиск релиза. Отдельные состояния вместо `null`
/// намеренно: «нет обновлений» и «нас не пустили» — разные ответы, и
/// показать второе как первое значит соврать.
enum UpdateLookup {
  /// Релиз найден, поля разобраны.
  ok,

  /// HTTP 403 с лимитом. Без авторизации GitHub даёт 60 запросов в час
  /// НА IP — для кнопки, которую жмут руками, этого хватает с запасом,
  /// но принять этот ответ за «обновлений нет» нельзя.
  rateLimited,

  /// Релизов нет либо репозиторий недостижим по правам.
  notFound,

  /// Сети нет, таймаут, обрыв.
  offline,

  /// Ответ пришёл, но не разобрался: нет тега build-N либо ни одного
  /// .apk среди ассетов.
  malformed,
}

/// Разобранный релиз. `buildNumber` = versionCode: CI считает его как
/// `git rev-list --count HEAD` и кладёт И в тег `build-N`, И в
/// `--build-number` сборки — значит сравнивать версии можно ДО
/// скачивания, по одному тегу.
class UpdateRelease {
  const UpdateRelease({
    required this.tag,
    required this.buildNumber,
    required this.assetName,
    required this.url,
    required this.bytes,
  });

  final String tag;
  final int buildNumber;
  final String assetName;
  final String url;
  final int bytes;
}

/// Результат поиска: состояние + релиз + человекочитаемая причина.
class UpdateLookupResult {
  const UpdateLookupResult(this.state, {this.release, this.detail = ''});

  final UpdateLookup state;
  final UpdateRelease? release;
  final String detail;
}

/// v0.1.77+176 — §B: скачивание APK из GitHub Releases.
///
/// РАЗБЛОКИРОВАНО ТЕМ, ЧТО РЕПОЗИТОРИЙ СТАЛ ПУБЛИЧНЫМ. В окне №8 проба
/// показала HTTP 404 без авторизации, и §B был условным. Сейчас
/// открытый доступ проверен кодами ответа.
///
/// ТОКЕН НЕ ШЬЁТСЯ НИ ПРИ КАКИХ УСЛОВИЯХ. Публичный релиз читается
/// анонимно; вшитый в APK токен — это выданный наружу ключ к
/// репозиторию, и никакое удобство этого не стоит.
///
/// ИМЯ ФАЙЛА НЕ УГАДЫВАЕТСЯ. Оно берётся из `assets[].name`, а ссылка —
/// из `browser_download_url`. Шаг CI «Rename APK» зовёт файл
/// `bz5-companion-<base>.<N>.apk`, но собирать эту строку здесь значит
/// завести вторую копию правды, которая разойдётся с workflow при первой
/// же его правке.
class ApkUpdate {
  ApkUpdate._();

  static const String latestUrl =
      'https://api.github.com/repos/AlexTalorJr/bz5-companion'
      '/releases/latest';

  /// v0.1.79+178 — ДВА РАЗНЫХ ВОПРОСА, КОТОРЫЕ Я СЛИЛ В ОДИН.
  ///
  /// «Есть ли сборка новее» и «можно ли это ставить» — не одно и то же,
  /// а в +176 на оба отвечало строгое «больше». Поле 30.07 показало
  /// цену: на ГУ установлено 254, доступно 254, и скачивание отказало —
  /// то есть ЕДИНСТВЕННЫЙ работающий путь к файлу (сеть; SAF на этой
  /// прошивке мёртв, системный выбор перехвачен галереей) закрылся
  /// ровно тогда, когда он и нужен.
  ///
  /// Равная версия — не откат. Система ставит одинаковый versionCode
  /// поверх себя штатно, это проверено на телефоне 30.07: данные целы,
  /// приложение обновилось. Отказ остаётся только строго младшей.
  static bool canInstall(int installed, int available) =>
      available >= installed && installed > 0 && available > 0;

  /// Строго новее — только для уведомления «есть свежая сборка».
  static bool isNewer(int installed, int available) =>
      available > installed && installed > 0 && available > 0;

  /// Номер сборки из тега `build-N`. null, если тег не такой.
  static int? buildFromTag(String tag) {
    final m = RegExp(r'^build-(\d+)$').firstMatch(tag.trim());
    if (m == null) return null;
    return int.tryParse(m.group(1)!);
  }

  /// Спросить у GitHub последний релиз.
  ///
  /// Каждый исход отдаётся своим состоянием. 403 с лимитом отделён
  /// особо: он приходит с телом-JSON и означает «спроси позже», а не
  /// «обновлений нет». Свести их к одному ответу — это соврать
  /// владельцу тем самым прибором, который делается ради честности.
  static Future<UpdateLookupResult> lookupLatest() async {
    try {
      final r = await http
          .get(
            Uri.parse(latestUrl),
            headers: const {
              'Accept': 'application/vnd.github+json',
              'User-Agent': 'bz5-companion',
            },
          )
          .timeout(const Duration(seconds: 12));
      if (r.statusCode == 403 || r.statusCode == 429) {
        final body = r.body.toLowerCase();
        if (body.contains('rate limit')) {
          return const UpdateLookupResult(
            UpdateLookup.rateLimited,
            detail: 'GitHub: 60 запросов в час на адрес, лимит выбран',
          );
        }
        return UpdateLookupResult(
          UpdateLookup.notFound,
          detail: 'HTTP ${r.statusCode}',
        );
      }
      if (r.statusCode != 200) {
        return UpdateLookupResult(
          UpdateLookup.notFound,
          detail: 'HTTP ${r.statusCode}',
        );
      }
      final j = jsonDecode(r.body);
      if (j is! Map) {
        return const UpdateLookupResult(
          UpdateLookup.malformed,
          detail: 'ответ не объект',
        );
      }
      final tag = '${j['tag_name'] ?? ''}';
      final build = buildFromTag(tag);
      if (build == null) {
        return UpdateLookupResult(
          UpdateLookup.malformed,
          detail: 'тег не вида build-N: «$tag»',
        );
      }
      final assets = j['assets'];
      if (assets is! List) {
        return const UpdateLookupResult(
          UpdateLookup.malformed,
          detail: 'нет списка ассетов',
        );
      }
      for (final a in assets) {
        if (a is! Map) continue;
        final name = '${a['name'] ?? ''}';
        final url = '${a['browser_download_url'] ?? ''}';
        if (!name.toLowerCase().endsWith('.apk') || url.isEmpty) continue;
        return UpdateLookupResult(
          UpdateLookup.ok,
          release: UpdateRelease(
            tag: tag,
            buildNumber: build,
            assetName: name,
            url: url,
            bytes: (a['size'] as num?)?.toInt() ?? 0,
          ),
          detail: name,
        );
      }
      return const UpdateLookupResult(
        UpdateLookup.malformed,
        detail: 'среди ассетов нет .apk',
      );
    } on TimeoutException catch (e) {
      return UpdateLookupResult(UpdateLookup.offline, detail: '$e');
    } catch (e) {
      return UpdateLookupResult(UpdateLookup.offline, detail: '$e');
    }
  }

  /// Скачать релиз в подготовленный файл.
  ///
  /// ПИШЕТ ТУДА, ОТКУДА ЧИТАЕТ ПРОВАЙДЕР — путь берётся у нативной
  /// стороны (`stagedPath`), а не собирается здесь.
  ///
  /// ЧАСТИЧНЫЙ ФАЙЛ УДАЛЯЕТСЯ ВСЕГДА. Оборванная закачка, оставшаяся
  /// под именем `staged_update.apk`, — это APK, который установщик
  /// возьмёт и отвергнет, а владелец прочтёт отказ как «путь не
  /// работает». Докачки нет сознательно: файл целиком меньше сотни
  /// мегабайт, а лишнее состояние здесь дороже повторной попытки.
  ///
  /// Размер сверяется с обещанным: совпадение — единственное, что у нас
  /// есть от целостности без подписи.
  static Future<Map<String, dynamic>> download({
    required UpdateRelease release,
    required String path,
    required DownloadHandle handle,
    void Function(int received, int total)? onProgress,
  }) async {
    final out = <String, dynamic>{};
    final file = File(path);
    IOSink? sink;
    final client = http.Client();
    try {
      final req = http.Request('GET', Uri.parse(release.url));
      req.headers['User-Agent'] = 'bz5-companion';
      final resp = await client.send(req).timeout(
            const Duration(seconds: 20),
          );
      if (resp.statusCode != 200) {
        out['ok'] = false;
        out['error'] = 'HTTP ${resp.statusCode}';
        return out;
      }
      final total = resp.contentLength ?? release.bytes;
      var got = 0;
      sink = file.openWrite();
      await for (final chunk in resp.stream) {
        if (handle.cancelled) {
          out['ok'] = false;
          out['error'] = 'отменено';
          return out;
        }
        sink.add(chunk);
        got += chunk.length;
        onProgress?.call(got, total);
      }
      await sink.flush();
      await sink.close();
      sink = null;
      final size = await file.length();
      if (release.bytes > 0 && size != release.bytes) {
        out['ok'] = false;
        out['error'] = 'размер $size вместо ${release.bytes}';
        return out;
      }
      out['ok'] = true;
      out['bytes'] = size;
      return out;
    } catch (e) {
      out['ok'] = false;
      out['error'] = '$e';
      return out;
    } finally {
      client.close();
      try {
        await sink?.close();
      } catch (e) {
        debugPrint('download: sink close failed: $e');
      }
      if (out['ok'] != true) {
        // Частичный файл не остаётся НИКОГДА — см. докстринг.
        try {
          if (await file.exists()) await file.delete();
        } catch (e) {
          debugPrint('download: partial cleanup failed: $e');
        }
      }
    }
  }
}

/// Отмена закачки. Отдельный объект, а не флаг в состоянии экрана:
/// закачка живёт дольше кадра, и владеть отменой должен тот, кто
/// переживёт перестроение.
class DownloadHandle {
  bool _cancelled = false;

  bool get cancelled => _cancelled;

  void cancel() => _cancelled = true;
}
