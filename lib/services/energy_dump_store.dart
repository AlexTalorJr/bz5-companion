// v0.2.39+238 — ФАЙЛЫ СЫРЫХ СОБЫТИЙ ШУМОВОЙ МИНУТЫ.
//
// Буфер [EnergyEventRing] сбрасывается сюда один раз за поездку, когда
// минута бортовой сети уходит ниже −0.5 кВт. Файлы лежат в приватной папке
// приложения (getApplicationSupportDirectory, как маркер автостарта) и
// уходят в архив экспорта папкой energy_dumps/. Хранятся последние [keep]:
// имя начинается с времени начала поездки, поэтому порядок имён —
// порядок поездок, и папка не растёт.
library;

import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

class EnergyDumpStore {
  static const String dirName = 'energy_dumps';
  static const int keep = 5;

  static Future<Directory> _dir() async {
    final base = await getApplicationSupportDirectory();
    final d = Directory(p.join(base.path, dirName));
    await d.create(recursive: true);
    return d;
  }

  /// Файлы, старые первыми.
  static Future<List<File>> list() async {
    final d = await _dir();
    final files = <File>[
      for (final e in d.listSync())
        if (e is File && e.path.endsWith('.csv')) e,
    ]..sort((a, b) => p.basename(a.path).compareTo(p.basename(b.path)));
    return files;
  }

  /// Пишет файл и удаляет лишние старые. Возвращает путь.
  static Future<String> write(String fileName, String text) async {
    final d = await _dir();
    final f = File(p.join(d.path, fileName));
    await f.writeAsString(text, flush: true);
    final all = await list();
    for (var i = 0; i < all.length - keep; i++) {
      await all[i].delete();
    }
    return f.path;
  }
}
