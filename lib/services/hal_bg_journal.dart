import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../data/database.dart';

/// v0.1.83+182 — ВТЯГИВАНИЕ ФОНОВОГО ЖУРНАЛА HAL.
///
/// Сервис автозапуска живёт в том же процессе, что и движок Flutter, но
/// база принадлежит Dart, и сервис в неё не пишет — возражение +169
/// («хранилище у companion на стороне Dart») остаётся в силе и здесь не
/// опровергается, а обходится. Сервис пишет строки в файл, а перекладывает
/// их в `hal_samples` эта сторона, при открытии приложения.
///
/// ТРИ ВЕЩИ, КОТОРЫЕ ЗДЕСЬ ОБЯЗАНЫ БЫТЬ ПРАВИЛЬНЫМИ.
///
/// 1. ВРЕМЯ БЕРЁТСЯ ИЗ СТРОКИ, А НЕ `DateTime.now()`. Готовый
///    `insertHalSignal` ставит время вставки — для живого потока это то же
///    самое, а для журнала это значит уложить всю поездку в одно
///    мгновение. Любой расчёт по времени (Атлас, тренды, графики поездки)
///    получил бы вертикальную стену вместо ряда. Поэтому вставка идёт
///    отдельным пакетным методом с явными метками.
///
/// 2. `tripId` ОСТАЁТСЯ NULL, И ЭТО НЕ НЕДОРАБОТКА. Поездки создаёт
///    машинерия Dart, включая насос 1 Гц из +156 (без него ровная скорость
///    невидима — `speed` приходит только по изменению). Приложение не
///    открыто — поездки не существует, и придумать ей id значит соврать.
///    Строки лягут неприписанными; сшивание их в поездки задним числом —
///    отдельная задача, и она отложена сознательно до ответа на главное
///    неизвестное.
///
/// 3. ФАЙЛ УСЕКАЕТСЯ ТОЛЬКО ПОСЛЕ УСПЕШНОЙ ВСТАВКИ. Обратный порядок при
///    отказе базы потерял бы поездку молча. Усечение — это `delete`, а не
///    обнуление под живой записью: сервис держит свой счётчик длины и на
///    исчезновение файла отвечает созданием нового.
class HalBgJournal {
  /// Имя файла. Совпадает с `JournalHalOut.FILE_NAME` в Kotlin, и это
  /// ЛИТЕРАЛ по обе стороны: приватную константу Kotlin компилятор Dart
  /// не отдаст, поэтому расхождение ловится только текстом — гейтом.
  static const String fileName = 'bz5_hal_bg_journal.jsonl';

  /// Сколько строк класть одной транзакцией. Двадцать тысяч строк по
  /// одной вставке на этой машине — минуты; пакетами по тысяче — секунды.
  static const int batchSize = 1000;

  /// Потолок на разбор за один заход. Файл ограничен восемью мебибайтами
  /// со стороны Kotlin, что при средней строке ~70 Б даёт около 120 тысяч
  /// строк. Читаем всё, но лимит стоит как предохранитель от файла,
  /// пришедшего из архива чужой сборки.
  static const int maxLines = 200000;

  /// Версия формата журнала. ЛИТЕРАЛ, совпадающий с `JournalHalOut.FMT`
  /// в Kotlin: приватную константу Kotlin компилятор Dart не отдаст,
  /// поэтому расхождение ловится только текстом, то есть гейтом.
  static const int fmt = 1;

  /// Имя файла в работе. Переименование в него — АТОМАРНАЯ ПЕРЕДАЧА
  /// ВЛАДЕНИЯ, и она решает сразу две беды.
  ///
  /// ОКНО ПОТЕРИ. Читать живой путь и потом его удалять значит потерять
  /// всё, что писатель дописал между чтением и удалением. На этом ГУ
  /// процесс живёт часами, сервис пишет в журнал, а новый движок Flutter
  /// поднимается в том же процессе — путь обычный, а не краевой. После
  /// переименования писатель создаёт новый файл (с новым заголовком) и
  /// продолжает в него; потерянного окна не существует, и на этот раз
  /// утверждение верно.
  ///
  /// ДУБЛИ. Остаток `.consuming` означает, что прошлый заход упал где-то
  /// между вставкой и удалением, и вставилось ли что-нибудь — неизвестно.
  /// Втянуть его снова значило бы удвоить строки без всякой сверки: у
  /// `hal_samples` нет ни `client_uuid`, ни идемпотентности, и это ровно
  /// тот механизм, что дал лавину 04.07 на поездках. Поэтому остаток
  /// считается втянутым и удаляется. Потерять одну поездку хуже, чем
  /// ничего, но несравнимо лучше, чем удвоить её молча — второе не видно
  /// вообще ничем, включая отчёт о восстановлении.
  static const String consumingName = 'bz5_hal_bg_journal.consuming';

  /// Итог одного втягивания. Все поля — измерения, ничего выведенного.
  static Future<HalBgIngestResult> ingest(AppDatabase db) async {
    var present = false;
    try {
      final support = await getApplicationSupportDirectory();
      final live = File(p.join(support.path, fileName));
      final taken = File(p.join(support.path, consumingName));

      // ── Остаток прошлого захода: считаем втянутым, удаляем. ──
      if (await taken.exists()) {
        final n = await _lineCount(taken);
        await _drop(taken);
        return HalBgIngestResult(present: true, abandoned: n);
      }

      if (!await live.exists()) {
        return const HalBgIngestResult(present: false);
      }
      present = true;

      // ── Передача владения. После неё писатель нас не догонит. ──
      try {
        await live.rename(taken.path);
      } catch (e) {
        debugPrint('HalBgJournal: rename failed — $e');
        return HalBgIngestResult(present: true, error: 'rename: $e');
      }

      final raw = await taken.readAsString();
      if (raw.isEmpty) {
        await _drop(taken);
        return const HalBgIngestResult(present: true);
      }

      final lines = const LineSplitter().convert(raw);
      // ── Версия формата. Чужую отвергаем ЦЕЛИКОМ, а не построчно. ──
      final hdr = _header(lines.isEmpty ? '' : lines.first);
      if (hdr != fmt) {
        await _drop(taken);
        return HalBgIngestResult(
          present: true,
          bytes: raw.length,
          rejectedFmt: hdr,
        );
      }

      var parsed = 0;
      var inserted = 0;
      var bad = 0;
      var capped = false;
      var seenLines = 0;
      // ── ОДНА ТРАНЗАКЦИЯ НА ВЕСЬ ФАЙЛ. ──
      //
      // Прежняя редакция вставляла пачками, каждая своей транзакцией, и
      // отказ на середине не «рисковал» дублями, а ГАРАНТИРОВАЛ их:
      // вставленные пачки остались бы, файл — тоже, следующий старт
      // втянул бы всё заново. Теперь либо весь файл, либо ничего, и
      // тогда остаток `.consuming` разберёт ветка выше.
      //
      // Пачки внутри транзакции остаются: они про ПАМЯТЬ, а не про
      // атомарность. Восемь мебибайт журнала — до ста двадцати тысяч
      // строк, и список записей на них занял бы больше самого файла
      // ровно в момент открытия приложения.
      await db.transaction(() async {
        final chunk = <BgHalRow>[];
        for (final line in lines) {
          if (line.isEmpty) continue;
          if (seenLines == 0 && line.contains('"_":"hdr"')) {
            seenLines++;
            continue;
          }
          if (++seenLines > maxLines) {
            capped = true;
            break;
          }
          final row = _parse(line);
          if (row == null) {
            bad++;
            continue;
          }
          chunk.add(row);
          parsed++;
          if (chunk.length >= batchSize) {
            inserted += await db.insertBackgroundHalSamples(chunk);
            chunk.clear();
          }
        }
        if (chunk.isNotEmpty) {
          inserted += await db.insertBackgroundHalSamples(chunk);
          chunk.clear();
        }
      });

      // Удаление — ПОСЛЕ подтверждённой транзакции.
      await _drop(taken);
      // ПИСАТЕЛЮ СООБЩАЕТ ВЫЗЫВАЮЩИЙ, А НЕ ЭТОТ КЛАСС.
      //
      // Уведомление `noteJournalConsumed` идёт платформенным каналом, а
      // гейт Y4 держит список файлов, которым позволено его касаться, — и
      // держит правильно: этот класс переводит файл в таблицу и не обязан
      // знать, что на другом конце есть платформа. Поэтому здесь только
      // флаг `consumed`, а звонок делает `hal_telemetry_service`, который
      // каналом владеет по праву. Расширять список исключений было бы
      // дешевле на одну строку и дороже на одну размытую границу.
      return HalBgIngestResult(
        present: true,
        consumed: true,
        parsed: parsed,
        inserted: inserted,
        malformed: bad,
        capped: capped,
        bytes: raw.length,
      );
    } catch (e) {
      debugPrint('HalBgJournal: ingest failed — $e');
      return HalBgIngestResult(present: present, error: '$e');
    }
  }

  /// Версия из первой строки, или null — заголовка нет вовсе.
  ///
  /// Отсутствие заголовка — это НЕ «версия 1». Журнал без заголовка писала
  /// сборка, которой мы не знаем, и разбирать её короткие ключи по нашей
  /// раскладке значит гадать.
  static int? _header(String first) {
    try {
      final m = jsonDecode(first);
      if (m is! Map || m['_'] != 'hdr') return null;
      final v = m['fmt'];
      return v is int ? v : null;
    } catch (_) {
      return null;
    }
  }

  static Future<int> _lineCount(File f) async {
    try {
      return const LineSplitter().convert(await f.readAsString()).length;
    } catch (_) {
      return 0;
    }
  }

  static Future<void> _drop(File f) async {
    try {
      if (await f.exists()) await f.delete();
    } catch (e) {
      debugPrint('HalBgJournal: drop failed — $e');
    }
  }
}

/// Итог втягивания. `present: false` — журнала не было вовсе, и это
/// обычное состояние на телефоне и на первом запуске; отличать его от
/// «был и пустой» нужно, потому что второе означает поездку без событий.
class HalBgIngestResult {
  final bool present;
  final int parsed;
  final int inserted;
  final int malformed;
  final bool capped;
  final int bytes;
  final String? error;

  /// Строк в остатке `.consuming`, признанном втянутым и удалённом.
  /// Ненулевое значение означает падение прошлого захода — данные
  /// потеряны сознательно, чтобы не удвоить их.
  final int abandoned;

  /// Версия формата отвергнутого файла, или null. Отличается от
  /// `error`: файл прочитался, он просто не наш.
  final int? rejectedFmt;

  /// Файл забран и удалён после подтверждённой транзакции. Только по
  /// этому флагу вызывающий сообщает писателю, что бюджет потолка можно
  /// начать заново.
  final bool consumed;

  const HalBgIngestResult({
    required this.present,
    this.parsed = 0,
    this.inserted = 0,
    this.malformed = 0,
    this.capped = false,
    this.bytes = 0,
    this.error,
    this.abandoned = 0,
    this.rejectedFmt,
    this.consumed = false,
  });

  bool get didWork => inserted > 0;

  @override
  String toString() => present
      ? 'journal: parsed=$parsed inserted=$inserted bad=$malformed '
          'capped=$capped bytes=$bytes abandoned=$abandoned'
          '${rejectedFmt != null ? ' rejected_fmt=$rejectedFmt' : ''}'
          '${error != null ? ' err=$error' : ''}'
      : 'journal: absent';
}
