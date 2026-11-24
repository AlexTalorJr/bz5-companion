// v0.2.31+230 — КЛИМАТ И ПОДОГРЕВЫ НА СТОЯНКЕ (Друг 3, письмо 09.11;
// «да» владельца 09.11).
//
// На P мотор не тянет, ток инвертора равен 0, и всё, что уходит из
// батареи сверх базы бортовой сети, — климат и подогревы. Правило:
//   P_климат = P_бат − база, база — параметр [ParkedClimateMeter.baseKw];
//   только на P и только при AC_POWER_STATE = 1;
//   подогревы сидений и руля НЕ вычитаются (подпись «Климат и подогревы»).
// v0.2.38+237 (recon v0.10.160): есть ток нагрузки 12 В — вместо базы
//   вычитается он сам: P_климат = P_бат − P_12В, и в климате остаётся
//   высоковольтная часть (компрессор, PTC); подогревы сидений и руля — это
//   12 В, они уходят в «Прочее» ([nowBoardKw], [boardEnergyKwh]). Тока нет
//   — прежнее правило с базой.
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
  double? _lastBoardKw;
  double _boardEnergyKwh = 0;
  bool _boardSeen = false;
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

  /// +237: бортовая сеть 12 В сейчас, кВт; null — тока 12 В нет.
  double? get nowBoardKw => active ? _lastBoardKw : null;

  /// +237: энергия бортовой сети 12 В за стоянку, кВт·ч; null — тока 12 В
  /// за стоянку не было.
  double? get boardEnergyKwh => _boardSeen ? _boardEnergyKwh : null;

  /// Длительность стоянки с включённым климатом.
  Duration get sessionDuration => Duration(seconds: _sessionSec.round());

  /// Один отсчёт. [t] — монотонное время. Возвращает итог закрытой
  /// стоянки (для строки в app_log), если этот отсчёт её закрыл.
  ({Duration dur, double meanKw, double kwh, double? boardKwh})? feed({
    required Duration t,
    required bool parked,
    required bool? acOn,
    required double? packKw,
    double? boardKw,
  }) {
    if (!parked || acOn != true) return _end();
    if (packKw == null) return null;
    final kw = math.max(0.0, packKw - (boardKw ?? baseKw));
    _sessionStart ??= t;
    final lt = _lastT;
    final lk = _lastKw;
    if (lt != null && lk != null && t > lt) {
      final dt = (t - lt).inMilliseconds / 1000.0;
      _energyKwh += lk * dt / 3600.0;
      _sessionSec += dt;
      final lb = _lastBoardKw;
      if (lb != null) _boardEnergyKwh += lb * dt / 3600.0;
    }
    _lastT = t;
    _lastKw = kw;
    _lastBoardKw = boardKw;
    if (boardKw != null) _boardSeen = true;
    _recent.add((t, kw));
    while (_recent.isNotEmpty && t - _recent.first.$1 > window) {
      _recent.removeAt(0);
    }
    return null;
  }

  ({Duration dur, double meanKw, double kwh, double? boardKwh})? _end() {
    if (_sessionStart == null) return null;
    final out = _sessionSec > 0
        ? (
            dur: sessionDuration,
            meanKw: _energyKwh * 3600.0 / _sessionSec,
            kwh: _energyKwh,
            boardKwh: boardEnergyKwh,
          )
        : null;
    _sessionStart = null;
    _lastT = null;
    _lastKw = null;
    _lastBoardKw = null;
    _boardEnergyKwh = 0;
    _boardSeen = false;
    _energyKwh = 0;
    _sessionSec = 0;
    _recent.clear();
    return out;
  }
}
