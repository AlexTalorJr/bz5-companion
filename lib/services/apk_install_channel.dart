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

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

class ApkInstallChannel {
  ApkInstallChannel._();

  static const MethodChannel _ch = MethodChannel('bz5/apkinstall');

  /// Только чтение. Безопасно звать где угодно, в том числе на
  /// телефоне — там просто вернётся другой набор резолверов.
  static Future<Map<String, dynamic>> probe() => _call('probe');

  /// Системный выбор файла (SAF). Ответ приходит после закрытия
  /// диалога: `{ok, uri}` или `{ok: false, error}`.
  static Future<Map<String, dynamic>> pick() => _call('pick');

  /// Копия выбранного в кэш приложения. `{ok, bytes, source_name}`.
  static Future<Map<String, dynamic>> stage(String uri) =>
      _call('stage', {'uri': uri});

  /// Отдать подготовленный файл установщику. `{ok, action, steps}`.
  static Future<Map<String, dynamic>> launch() => _call('launch');

  /// Экран «установка из неизвестных источников» для нашего пакета.
  static Future<Map<String, dynamic>> unknownSources() =>
      _call('unknownSources');

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
