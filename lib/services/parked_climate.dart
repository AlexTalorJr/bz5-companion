// v0.2.31+230 — КЛИМАТ И ПОДОГРЕВЫ НА СТОЯНКЕ (Друг 3, письмо 09.11;
// «да» владельца 09.11).
//
// На P мотор не тянет, ток инвертора равен 0, и всё, что уходит из
// батареи сверх базы бортовой сети, — климат и подогревы. Правило:
//   P_климат = P_бат − база, база — параметр [ParkedClimateMeter.baseKw];
//   только на P и только при AC_POWER_STATE = 1;
//   подогревы сидений и руля НЕ вычитаются (подпись «Климат и подогревы»).
// Значение «сейчас» — среднее за последние [window] (или за сколько есть,
// чтобы показывать сразу); в итог идёт среднее за всю стоянку с включённым
// климатом и его энергия.
//
// AC-номера шлются только по событию, начального значения нет. До первого
// события AC_POWER_STATE состояние климата неизвестно, и карточки нет —
// прочерк не показываем (правило честности Друга 3).
//
// Чистый класс без таймеров: время приходит снаружи (Stopwatch в
// HalTelemetryService, не часы — они прыгают при приходе GPS-времени).

import 'dart:math' as math;

class ParkedClimateMeter {
  /// База бортовой сети на стоянке, кВт. Параметр: Друг 3 мерил 0.34–0.41
  /// без климата и 0.45 с прогретым салоном; уточнит калибровкой.
  static const double baseKw = 0.45;

  /// Окно значения «сейчас».
  static const Duration window = Duration(seconds: 30);

  Duration? _sessionStart;
  Duration? _lastT;
  double? _lastKw;
  double _energyKwh = 0;
  double _sessionSec = 0;
  final List<(Duration, double)> _recent = [];

  /// Идёт ли стоянка с включённым климатом и есть ли хоть один отсчёт.
  bool get active => _sessionStart != null && _lastKw != null;

  /// Среднее за последние [window], кВт.
  double? get nowKw {
    if (!active || _recent.isEmpty) return null;
    var sum = 0.0;
    for (final r in _recent) {
      sum += r.$2;
    }
    return sum / _recent.length;
  }

  /// Среднее за стоянку (по времени), кВт. Пока времени нет — «сейчас».
  double? get meanKw {
    if (!active) return null;
    return _sessionSec > 0 ? _energyKwh * 3600.0 / _sessionSec : nowKw;
  }

  /// Энергия климата за стоянку, кВт·ч.
  double get energyKwh => _energyKwh;

  /// Длительность стоянки с включённым климатом.
  Duration get sessionDuration => Duration(seconds: _sessionSec.round());

  /// Один отсчёт. [t] — монотонное время. Возвращает итог закрытой
  /// стоянки (для строки в app_log), если этот отсчёт её закрыл.
  ({Duration dur, double meanKw, double kwh})? feed({
    required Duration t,
    required bool parked,
    required bool? acOn,
    required double? packKw,
  }) {
    if (!parked || acOn != true) return _end();
    if (packKw == null) return null;
    final kw = math.max(0.0, packKw - baseKw);
    _sessionStart ??= t;
    final lt = _lastT;
    final lk = _lastKw;
    if (lt != null && lk != null && t > lt) {
      final dt = (t - lt).inMilliseconds / 1000.0;
      _energyKwh += lk * dt / 3600.0;
      _sessionSec += dt;
    }
    _lastT = t;
    _lastKw = kw;
    _recent.add((t, kw));
    while (_recent.isNotEmpty && t - _recent.first.$1 > window) {
      _recent.removeAt(0);
    }
    return null;
  }

  ({Duration dur, double meanKw, double kwh})? _end() {
    if (_sessionStart == null) return null;
    final out = _sessionSec > 0
        ? (
            dur: sessionDuration,
            meanKw: _energyKwh * 3600.0 / _sessionSec,
            kwh: _energyKwh,
          )
        : null;
    _sessionStart = null;
    _lastT = null;
    _lastKw = null;
    _energyKwh = 0;
    _sessionSec = 0;
    _recent.clear();
    return out;
  }
}
