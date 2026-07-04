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
