// v0.1.29+117 (C1): hand-rolled UUIDv7 generator (RFC 9562 §5.7).
//
// Why hand-rolled instead of `package:uuid`: a missing pubspec dependency is
// the exact failure class that broke CI four builds in a row around
// v0.1.28+1..v0.1.29+3 (imports parse fine locally, kernel_snapshot dies on
// CI), and the local gates cannot compile Dart to catch it. 25 lines of
// dependency-free code removes the risk entirely. The server treats
// client_uuid as an opaque unique key (spec v1.3 / Q6 review), so no
// interop-grade library behaviour is required — only RFC-correct layout.
//
// Layout (16 bytes):
//   bytes 0..5   unix timestamp in milliseconds, big-endian, 48 bits
//   byte  6      version nibble 0x7 in the high 4 bits + 4 random bits
//   byte  7      random
//   byte  8      variant `10` in the high 2 bits + 6 random bits
//   bytes 9..15  random
//
// 74 random bits come from Random.secure() (OS CSPRNG). Collision odds are
// negligible at our volumes even within a single millisecond.

import 'dart:math';

final Random _uuidRng = Random.secure();

/// Generates an RFC 9562 UUIDv7 string (lowercase, 8-4-4-4-12).
///
/// [time] overrides the timestamp part — used by the schema-14 backfill to
/// stamp historical rows with their own `started_at` / `captured_at` so old
/// uuids sort like the data they identify. Pure cosmetics per the agreed
/// contract (server orders pulls by server_seq, never by uuid); new rows
/// always use `now`.
String uuidV7({DateTime? time}) {
  var ms = (time ?? DateTime.now()).toUtc().millisecondsSinceEpoch;
  // Clamp into the 48-bit unsigned range the format allows. Negative values
  // (pre-1970 garbage timestamps) would otherwise corrupt the version bits.
  if (ms < 0) ms = 0;
  const maxTs48 = 0xFFFFFFFFFFFF; // 2^48 − 1
  if (ms > maxTs48) ms = maxTs48;

  final b = List<int>.filled(16, 0);
  b[0] = (ms >> 40) & 0xFF;
  b[1] = (ms >> 32) & 0xFF;
  b[2] = (ms >> 24) & 0xFF;
  b[3] = (ms >> 16) & 0xFF;
  b[4] = (ms >> 8) & 0xFF;
  b[5] = ms & 0xFF;
  for (var i = 6; i < 16; i++) {
    b[i] = _uuidRng.nextInt(256);
  }
  b[6] = 0x70 | (b[6] & 0x0F); // version 7
  b[8] = 0x80 | (b[8] & 0x3F); // variant 10xx

  final hex = StringBuffer();
  for (var i = 0; i < 16; i++) {
    if (i == 4 || i == 6 || i == 8 || i == 10) hex.write('-');
    hex.write(b[i].toRadixString(16).padLeft(2, '0'));
  }
  return hex.toString();
}

/// v0.1.87+186 — ДЕТЕРМИНИРОВАННЫЙ UUIDv7 ДЛЯ ПЕРЕСОБИРАЕМЫХ СТРОК.
///
/// ЗАЧЕМ. Фоновая поездка собирается ИЗ ДАННЫХ, а не из события, и потому
/// может быть собрана дважды: владелец ставит приложение через удаление и
/// восстанавливает базу из архива. Восстановись он из архива, снятого ДО
/// сборки, — строитель соберёт тот же выезд заново. Со случайным uuid
/// сервер получил бы второй экземпляр и не смог бы его схлопнуть:
/// дедупликация идёт по паре устройство/uuid, а uuid другой.
///
/// Поэтому uuid выводится из того, ЧТО описывает строка, а не из того,
/// КОГДА её собрали. Один и тот же выезд даёт один и тот же uuid сколько
/// угодно раз, и повтор схлопывается сам.
///
/// ФОРМАТ ОСТАЁТСЯ ВАЛИДНЫМ v7: первые 48 бит — метка времени (у поездки
/// это её начало, а не момент сборки), дальше версия 7 и вариант 10xx на
/// своих местах. Сортировка по uuid у сервера продолжает означать
/// сортировку по времени.
///
/// Случайность заменена детерминированным перемешиванием (splitmix64) от
/// строки-семени. Криптостойкость здесь не нужна и не заявляется: задача
/// не «непредсказуемо», а «одинаково при одинаковом входе и разно при
/// разном». Пакет `crypto` ради UUIDv5 не вводится — новая зависимость
/// стоит дороже двадцати строк арифметики.
String uuidV7Deterministic({required DateTime time, required String seed}) {
  var ms = time.toUtc().millisecondsSinceEpoch;
  if (ms < 0) ms = 0;
  const maxTs48 = 0xFFFFFFFFFFFF;
  if (ms > maxTs48) ms = maxTs48;

  // FNV-1a 64 по семени — стабильный вход для перемешивателя.
  var h = 0xcbf29ce484222325;
  for (final c in seed.codeUnits) {
    h ^= c;
    h = (h * 0x100000001b3) & 0xFFFFFFFFFFFFFFFF;
  }

  final b = List<int>.filled(16, 0);
  b[0] = (ms >> 40) & 0xFF;
  b[1] = (ms >> 32) & 0xFF;
  b[2] = (ms >> 24) & 0xFF;
  b[3] = (ms >> 16) & 0xFF;
  b[4] = (ms >> 8) & 0xFF;
  b[5] = ms & 0xFF;
  var x = h;
  for (var i = 6; i < 16; i++) {
    // splitmix64, шаг на байт
    x = (x + 0x9E3779B97F4A7C15) & 0xFFFFFFFFFFFFFFFF;
    var z = x;
    // СДВИГ ЗДЕСЬ ОБЯЗАН БЫТЬ БЕЗЗНАКОВЫМ (`>>>`, не `>>`). В Dart `int`
    // знаковый 64-битный, и после умножения половина значений
    // отрицательна; арифметический `>>` тянет знак и даёт другой результат.
    // Он остался бы детерминированным — и потому ошибка была бы невидимой,
    // — но разошёлся бы с зеркалом на Python, на котором эта функция
    // проверена. Разошёлся бы молча и навсегда: uuid уже уехавших поездок
    // не пересчитать.
    z = ((z ^ (z >>> 30)) * 0xBF58476D1CE4E5B9) & 0xFFFFFFFFFFFFFFFF;
    z = ((z ^ (z >>> 27)) * 0x94D049BB133111EB) & 0xFFFFFFFFFFFFFFFF;
    z = z ^ (z >>> 31);
    b[i] = z & 0xFF;
  }
  b[6] = 0x70 | (b[6] & 0x0F); // версия 7
  b[8] = 0x80 | (b[8] & 0x3F); // вариант 10xx

  final hex = StringBuffer();
  for (var i = 0; i < 16; i++) {
    if (i == 4 || i == 6 || i == 8 || i == 10) hex.write('-');
    hex.write(b[i].toRadixString(16).padLeft(2, '0'));
  }
  return hex.toString();
}
