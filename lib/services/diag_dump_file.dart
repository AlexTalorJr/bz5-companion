/// Persistent diagnostic dump writer for Native Explorer recon sessions.
///
/// Purpose: head unit has no ADB, so logcat / debug output is invisible.
/// The Native Explorer already shows things on screen, but the user
/// has no way to take that off-device except by copying to the
/// clipboard and pasting into some other app. That's manual, lossy
/// (clipboard gets overwritten by the next copy), and a poor fit for
/// recon work where you want a running diary of probes & results.
///
/// This service writes/append-writes a single Markdown file to the
/// public Downloads folder so the user can pick it up from any file
/// manager (Toyota's "Проводник") and copy to a USB flash drive.
///
/// Why Markdown and not plain text:
///   * the head-unit "Проводник" file manager opens .md as text
///   * if the user mails the file off, Markdown readers (Telegram,
///     GitHub, VSCode) format it readably
///   * timestamps + section headings ('## YYYY-MM-DD HH:mm:ss — title')
///     give Cmd-F structure
///   * code fences highlight any embedded JSON / hex dumps
///
/// File location strategy (mirrors ExportService — proven path):
///   1. /storage/emulated/0/Download/bz5_companion_diag.md
///      (public Downloads, visible to file manager and USB workflow)
///   2. Fallback: app-private external dir, if (1) is not writable
///      (Android 11+ scoped storage on a strict ROM)
///   3. Last resort: app docs dir (not user-visible)
///
/// The whole class is intentionally side-effect light — no global
/// streams, no listeners, no schedulers. The caller asks for an
/// append; we open the file, write, flush, close. If anyone wants to
/// view live, they should re-read the file path the call returned.
library;

import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';

/// Result of one append. Tells the UI where the data actually landed
/// (which may be the fallback dir if public Downloads was unwritable)
/// and what the file size is now.
class DiagDumpAppendResult {
  /// Absolute path on disk where the data was written.
  final String path;

  /// File size in bytes after this append.
  final int sizeBytes;

  /// True if `path` is under `/storage/emulated/0/Download/`
  /// — the user-visible Downloads folder. False if we fell back to
  /// app-private storage (which the user can still reach but not as
  /// easily, e.g. via Android/data/com.bz5companion/files/...).
  final bool isPublicDownloads;

  /// True if this append created the file (so the caller can show
  /// "started new dump file at ..." rather than "appended to ...").
  final bool wasNewFile;

  const DiagDumpAppendResult({
    required this.path,
    required this.sizeBytes,
    required this.isPublicDownloads,
    required this.wasNewFile,
  });

  /// Compact human label for the result-row UI.
  String describeForUi() {
    final kb = (sizeBytes / 1024).toStringAsFixed(1);
    final loc = isPublicDownloads ? 'Downloads' : 'app-private';
    final verb = wasNewFile ? 'created' : 'appended';
    return 'Dump $verb in $loc — now $kb KB';
  }
}

/// Snapshot of the dump file's current state (without modifying it).
class DiagDumpInfo {
  /// Absolute path. Null only on platforms where no writable dir was
  /// resolvable (very unusual).
  final String? path;

  /// Current file size; 0 if the file doesn't exist yet.
  final int sizeBytes;

  /// Whether `path` (if non-null) points into public Downloads.
  final bool isPublicDownloads;

  /// Whether the file actually exists on disk right now.
  final bool exists;

  const DiagDumpInfo({
    required this.path,
    required this.sizeBytes,
    required this.isPublicDownloads,
    required this.exists,
  });
}

class DiagDumpFile {
  // Single canonical filename — append-mode means everything goes here.
  // .md so the head-unit file manager preview shows formatted text.
  static const String _filename = 'bz5_companion_diag.md';

  static const DiagDumpFile instance = DiagDumpFile._();
  const DiagDumpFile._();

  /// Append a labeled section to the dump file. The section header
  /// is `## <timestamp> — <title>` followed by the [body] verbatim,
  /// then a horizontal-rule separator.
  ///
  /// If the file doesn't exist yet, a small header banner is written
  /// first so a freshly-grabbed file has context for the recipient.
  ///
  /// Caller responsibility: don't pass an unbounded body. Anything
  /// over ~64 KB should be split or summarised first. We don't enforce
  /// a hard cap because some legitimate dumps (HAL probe full enum)
  /// can be larger, and silently truncating would be worse than letting
  /// the writer through.
  /// v0.1.79+178 — ПРИ ОТКАЗЕ БЕРЁМ СВЕЖЕЕ ИМЯ, А НЕ СДАЁМСЯ.
  ///
  /// Поле 30.07 дало три точки в одной папке в один день: экспорт
  /// записал НОВЫЙ файл уже после переустановки — успешно; этот дамп
  /// попытался дописать в `bz5_companion_diag.md`, оставшийся от
  /// сборки 0.1.75.248, — отказ; маркер попытался дописать в свой
  /// постоянный файл — отказ.
  ///
  /// Причина не в scoped storage и не в правах: переустановка меняет
  /// uid, файл в общей папке остаётся за прежним владельцем, и
  /// дописывание в него запрещено — а СОЗДАНИЕ нового разрешено.
  /// Экспорт годами не замечал проблемы ровно потому, что каждый раз
  /// берёт имя со временем.
  ///
  /// Отсюда лестница: канонический файл → свежее имя рядом с ним →
  /// свежее имя в приватной папке. Последняя ступень не отказывает
  /// никогда. Каждый отказ записывается С КЛАССОМ ИСКЛЮЧЕНИЯ: «дамп не
  /// записан» без причины стоило нам целого визита, на котором вывод
  /// «хранилище недоступно» оказался заведомо сильнее данных.
  Future<DiagDumpAppendResult> append({
    required String title,
    required String body,
  }) async {
    final dir = await _resolveDownloadsDir();
    final fresh = _freshFilename();
    final reasons = <String>[];
    final candidates = <File>[File(p.join(dir.path, _filename))];
    candidates.add(File(p.join(dir.path, fresh)));
    try {
      final docs = await getApplicationDocumentsDirectory();
      if (docs.path != dir.path) {
        candidates.add(File(p.join(docs.path, fresh)));
      }
    } catch (e) {
      reasons.add('appDocs: ${e.runtimeType}');
    }
    for (final candidate in candidates) {
      try {
        return await _appendTo(candidate, title, body);
      } catch (e) {
        reasons.add('${candidate.path}: ${e.runtimeType}: $e');
      }
    }
    throw DiagDumpWriteFailure(reasons);
  }

  /// Имя со временем — как у экспорта, который этим и жив.
  String _freshFilename() {
    final n = DateTime.now();
    String two(int v) => v.toString().padLeft(2, '0');
    return 'bz5_companion_diag_${n.year}${two(n.month)}${two(n.day)}'
        '-${two(n.hour)}${two(n.minute)}${two(n.second)}.md';
  }

  Future<DiagDumpAppendResult> _appendTo(
    File file,
    String title,
    String body,
  ) async {
    final isNew = !await file.exists();
    final ts = _isoLikeTimestamp(DateTime.now());

    // Use IOSink with append mode so concurrent appends from the same
    // process serialize at the FS layer (we don't expect cross-process
    // access — this app is single-process).
    final sink = file.openWrite(mode: FileMode.append);
    try {
      if (isNew) {
        sink
          ..writeln('# BZ5 Companion — diagnostic dump')
          ..writeln()
          ..writeln(
              'Persistent append-only log written by Native Explorer.')
          ..writeln(
              'Each section below is one user action (Probe / VIN /')
          ..writeln(
              'HAL Get / Get property / etc.) with its result.')
          ..writeln()
          ..writeln('---')
          ..writeln();
      }
      sink
        ..writeln('## $ts — ${_sanitizeTitle(title)}')
        ..writeln();
      sink.write(body);
      if (!body.endsWith('\n')) sink.writeln();
      sink
        ..writeln()
        ..writeln('---')
        ..writeln();
      await sink.flush();
    } finally {
      await sink.close();
    }

    final size = await file.length();
    return DiagDumpAppendResult(
      path: file.path,
      sizeBytes: size,
      isPublicDownloads: _isPublicDownloads(file.parent.path),
      wasNewFile: isNew,
    );
  }

  /// Info-only — does not create the file. Returns where the file is or
  /// would be, current size (0 if missing), and existence flag.
  Future<DiagDumpInfo> info() async {
    try {
      final dir = await _resolveDownloadsDir();
      final file = File(p.join(dir.path, _filename));
      final exists = await file.exists();
      final size = exists ? await file.length() : 0;
      return DiagDumpInfo(
        path: file.path,
        sizeBytes: size,
        isPublicDownloads: _isPublicDownloads(dir.path),
        exists: exists,
      );
    } catch (e) {
      debugPrint('DiagDumpFile.info failed: $e');
      return const DiagDumpInfo(
        path: null,
        sizeBytes: 0,
        isPublicDownloads: false,
        exists: false,
      );
    }
  }

  /// Delete the dump file if it exists. Returns true if a file was
  /// actually removed, false if nothing was there or deletion failed.
  /// Errors are logged but not rethrown — caller can re-query info()
  /// to confirm.
  Future<bool> clear() async {
    try {
      final dir = await _resolveDownloadsDir();
      final file = File(p.join(dir.path, _filename));
      if (await file.exists()) {
        await file.delete();
        return true;
      }
      return false;
    } catch (e) {
      debugPrint('DiagDumpFile.clear failed: $e');
      return false;
    }
  }

  // ─── internals ─────────────────────────────────────────────────────

  /// Returns "2026-05-22 14:33:07" — sortable, no timezone, no millis.
  /// We intentionally don't use DateFormat from `intl` to avoid pulling
  /// the intl dependency into this file unnecessarily (it's already
  /// transitively available via export_service, but keeping deps
  /// minimal here makes this file copy-pastable into other projects).
  String _isoLikeTimestamp(DateTime t) {
    String two(int n) => n.toString().padLeft(2, '0');
    return '${t.year}-${two(t.month)}-${two(t.day)} '
        '${two(t.hour)}:${two(t.minute)}:${two(t.second)}';
  }

  /// Strip newlines/CRs from titles so they fit a single-line ## header.
  String _sanitizeTitle(String s) {
    final flat = s.replaceAll(RegExp(r'[\r\n]+'), ' ').trim();
    // Cap length so the heading stays readable in a TOC view.
    return flat.length <= 120 ? flat : '${flat.substring(0, 117)}...';
  }

  bool _isPublicDownloads(String dirPath) {
    return dirPath.startsWith('/storage/emulated/0/Download');
  }

  /// Identical strategy to ExportService._resolveDownloadsDir — proven
  /// in v0.1.13+. Kept as a sibling rather than imported because
  /// ExportService's method is private to that class.
  Future<Directory> _resolveDownloadsDir() async {
    // On Android < 11, public Downloads requires WRITE_EXTERNAL_STORAGE.
    // On 11+ that permission is gone (scoped storage). Many BZ5 head
    // units run Android 12, and BZ5's permission policy on shared
    // Downloads is permissive enough that File API often works without
    // any permission grant. Request anyway — it's harmless if denied.
    try {
      if (Platform.isAndroid) {
        final status = await Permission.storage.request();
        if (!status.isGranted) {
          debugPrint(
              'DiagDumpFile: storage permission denied, may fall back');
        }
      }
    } catch (e) {
      debugPrint('DiagDumpFile: permission request threw: $e');
    }

    // 1. Public Downloads (preferred — visible to Toyota Проводник).
    final publicDownloads = Directory('/storage/emulated/0/Download');
    try {
      if (await publicDownloads.exists()) {
        // Probe write access by creating + deleting a tiny test file.
        final probe = File(p.join(
          publicDownloads.path,
          '.bz5_diag_probe_${DateTime.now().millisecondsSinceEpoch}',
        ));
        try {
          await probe.create();
          await probe.delete();
          return publicDownloads;
        } catch (_) {
          // Not writable — fall through.
        }
      }
    } catch (_) {}

    // 2. App-private external storage.
    try {
      final ext = await getExternalStorageDirectory();
      if (ext != null) {
        final dlDir = Directory(p.join(ext.path, 'Downloads'));
        await dlDir.create(recursive: true);
        return dlDir;
      }
    } catch (_) {}

    // 3. App docs dir — always exists, but not visible to file manager.
    return getApplicationDocumentsDirectory();
  }
}

/// Все ступени лестницы отказали. Несёт причины ПОИМЁННО: без класса
/// исключения и пути «дамп не записан» — это вывод, а не измерение, и
/// на нём уже один раз построили неверное объяснение.
class DiagDumpWriteFailure implements Exception {
  DiagDumpWriteFailure(this.reasons);

  final List<String> reasons;

  @override
  String toString() => 'дамп не записан: ${reasons.join(' · ')}';
}
