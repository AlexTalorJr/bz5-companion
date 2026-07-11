/// v0.1.32+131: the ONE place user-facing SOC is resolved.
///
/// Before +131 the expression
///   `hal.useHalForSoc ? hal.halSocPct : svc.socPrecisePct`
/// was copy-pasted across six screens, and it always preferred the
/// BMS-internal (true) SOC — which legitimately differs from the number
/// on the instrument cluster by ~1-2%. Users compared the app against
/// the cluster and read the difference as a bug.
///
/// Now every DISPLAYED SOC digit goes through [resolveUiSocPct], which
/// honours the user's SocSource setting (Settings → "Battery
/// percentage"). Math paths are deliberately NOT routed here: trip
/// energy (halSocForTrip), SOH and the charging-ETA input keep reading
/// precise SOC unconditionally — the setting changes pixels, not
/// physics.
library;

import 'connection.dart';
import 'hal_telemetry_service.dart';

/// User-facing SOC in %, per the SocSource preference.
///
///   - SocSource.display : the cluster figure — HAL soc_display (sticky,
///     event-driven, no hold window) → soc_battery → ROUNDED precise as
///     the last resort, so the scale never jumps between integer and
///     fractional while falling back. On a dongle-only setup (no HAL)
///     display-SOC does not exist in UDS — the honest fallback is the
///     precise OBD2 value, same as the pre-+131 behaviour.
///   - SocSource.precise : the pre-+131 resolution verbatim (BMS-true,
///     0.1% steps).
double? resolveUiSocPct(HalTelemetryService hal, ConnectionService svc) {
  if (hal.socSource == SocSource.precise) {
    return hal.useHalForSoc ? hal.halSocPct : svc.socPrecisePct;
  }
  final d = hal.halSocDisplayPct;
  if (d != null) return d;
  final p = hal.useHalForSoc ? hal.halSocPct : svc.socPrecisePct;
  return p?.roundToDouble();
}

/// FP-safe split of a SOC value into the big integer part and the small
/// fractional suffix, for the "72" + ".4" two-Text layout the SOC cards
/// use. Rounds to the visible tenth FIRST (naive truncate() renders
/// 48.30 stored as 48.2999… as "48.2"), then splits.
///
/// v0.1.32+131: an integral value returns an EMPTY suffix — in
/// SocSource.display mode every value is integral and the card shows a
/// clean "72" like the cluster, not "72.0".
(String, String) splitSocDigits(double? v) {
  if (v == null) return ('—', '');
  final r = (v * 10).round() / 10;
  final frac = ((r - r.truncate()) * 10).round();
  return (r.truncate().toString(), frac == 0 ? '' : '.$frac');
}

/// Plain one-line SOC text ("72" / "72.4") for inline labels and chips.
/// [maxDecimals] caps the fractional digits (the wide charging screen
/// historically showed two); integral values always collapse to "72".
String formatSocPct(double v, {int maxDecimals = 1}) {
  if (v == v.roundToDouble()) return v.toStringAsFixed(0);
  return v.toStringAsFixed(maxDecimals);
}
