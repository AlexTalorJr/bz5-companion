// v0.2.35+234 — СВЕРКА КОНТРОЛЬНЫХ ПОЛЕЙ FIREHOSE С HAL.
//
// Поля firehose декодируются по правилу «фид каталога → место в кадре»
// (recon FirehoseFieldTable, p158). Правило проверено на трёх полях,
// которые есть и в HAL: уставки климата водителя и пассажира и
// ENERGY_STATE. Если они разойдутся с HAL, значит, сменилась прошивка или
// облачный конфиг сборщика BYD, и подтверждённым полям firehose верить
// нельзя (Друг 3, 12.11). Состояние: `unchecked` — пары ещё не
// встречались, `ok` — совпали, `mismatch` — расхождение держится дольше
// [mismatchHoldMs]. `mismatch` держится до начала следующей поездки
// ([resetForTrip]): процесс на голове живёт сутками, и одно ложное
// срабатывание не должно гасить сверку на дни.

class FirehoseCheck {
  static const String unchecked = 'unchecked';
  static const String ok = 'ok';
  static const String mismatch = 'mismatch';

  /// Кадр firehose приходит около раза в секунду, событие HAL — по
  /// изменению; короткое расхождение на смене значения — норма.
  static const int mismatchHoldMs = 10000;

  /// Имя firehose → имя HAL.
  static const Map<String, String> pairs = {
    'fh_ac_temp_main_c': 'ac_temp_main',
    'fh_ac_temp_deputy_c': 'ac_temp_deputy',
    'fh_energy_state': 'energy_state',
  };
  static final Map<String, String> _halToFh = {
    for (final e in pairs.entries) e.value: e.key,
  };

  /// v0.2.36+235: имена HAL-стороны пар. HalTelemetryService кормит их в
  /// сверку до веток, которые их забирают (`ac_` — журнал климата,
  /// `energy_state` нет в фильтре `_range`): в +234 обе стороны
  /// выбрасывались раньше сверки, и она стояла в `unchecked`.
  static bool isHalSide(String name) => _halToFh.containsKey(name);

  String state = unchecked;
  String? lastDetail;
  final Map<String, double> _last = {};
  final Map<String, int> _mismatchSince = {};

  /// Начало поездки: проверка заново. Последние значения обеих сторон
  /// остаются — они действительны, поток шлёт по изменению.
  void resetForTrip() {
    state = unchecked;
    lastDetail = null;
    _mismatchSince.clear();
  }

  /// Событие любого имени; true — [state] изменилось.
  bool feed(String name, double value, int tsMs) {
    final fh = pairs.containsKey(name) ? name : _halToFh[name];
    if (fh == null) return false;
    _last[name] = value;
    final a = _last[fh];
    final b = _last[pairs[fh]!];
    if (a == null || b == null) return false;
    final before = state;
    if ((a - b).abs() < 0.01) {
      _mismatchSince.remove(fh);
      if (state == unchecked) state = ok;
    } else {
      final since = _mismatchSince.putIfAbsent(fh, () => tsMs);
      if (tsMs - since >= mismatchHoldMs) {
        state = mismatch;
        lastDetail = '$fh=$a vs ${pairs[fh]}=$b';
      }
    }
    return state != before;
  }
}
