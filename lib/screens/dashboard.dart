import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../l10n/strings.dart';
import '../services/connection.dart';
import '../services/hal_telemetry_service.dart';
import '../services/locale_service.dart';
import '../widgets/driver_panels.dart';

class DashboardScreen extends StatelessWidget {
  const DashboardScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final svc = context.watch<ConnectionService>();
    // v0.1.29+60: re-render on language switch (per-screen subscription).
    context.watch<LocaleService>();
    // v0.1.29+107: this phone-layout dashboard is the MAIN screen on a
    // vertically-mounted head unit (BZ3 falls to phone layout — see
    // responsive.dart useHeadUnitLayout, which needs width > height). The
    // +83 startup-gate fix shipped to the wide HU screens (dashboard_wide,
    // driver_view_wide) but not here, so a BZ3 without a dongle was stuck on
    // the "connect over BT" wall even though HAL data is flowing. Apply the
    // same gate here: halOnly with HAL available is NOT blocked.
    final hal = context.watch<HalTelemetryService>();
    final connected = svc.status == ConnectionStatus.connected;
    final halActive = hal.canUseHal && hal.mode == HalSourceMode.halOnly;
    final blocked = !connected && !halActive;
    // Polling is an OBD2 concept; hide its toggle in halOnly.
    final showPolling = hal.mode != HalSourceMode.halOnly;

    return Scaffold(
      appBar: AppBar(
        title: const Text('BZ5 Companion'),
        actions: [
          if (showPolling)
            IconButton(
              icon: Icon(svc.isPolling ? Icons.pause_circle : Icons.play_circle),
              onPressed: !connected ? null : () {
                if (svc.isPolling) {
                  svc.stopPolling();
                } else {
                  svc.startPolling();
                }
              },
            ),
        ],
      ),
      body: blocked
          ? _NotConnected(
              halDead: hal.mode == HalSourceMode.halOnly && !hal.running)
          : _Connected(svc: svc),
    );
  }
}

class _NotConnected extends StatelessWidget {
  // v0.1.29+107: halDead = halOnly chosen but the HAL stream isn't running.
  // Then "connect over BT" is a lie (the user picked HAL), so show a
  // HAL-stream message + sync-disabled icon — mirrors dashboard_wide's
  // _NotConnectedHero.
  const _NotConnected({this.halDead = false});
  final bool halDead;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(halDead ? Icons.sync_disabled : Icons.bluetooth_disabled,
                size: 80, color: Colors.grey),
            const SizedBox(height: 24),
            Text(
                halDead
                    ? S.of('settings.datasource.hal_unavailable')
                    : S.of('common.not_connected_title'),
                style: Theme.of(context).textTheme.headlineSmall),
            const SizedBox(height: 12),
            Text(
                halDead
                    ? S.of('datasource.hal_dead_hint')
                    : S.of('dash.find_hint'),
                textAlign: TextAlign.center),
          ],
        ),
      ),
    );
  }
}

class _Connected extends StatelessWidget {
  final ConnectionService svc;
  const _Connected({required this.svc});

  @override
  Widget build(BuildContext context) {
    // v0.1.29+66 overlapping wave: gear / SOC / pack V / power prefer the
    // HAL push stream when fresh, falling back to OBD2 per-value. Each
    // swap is invisible — same card, same place, no source label. Trip
    // aggregates and everything recorded stay pure OBD2 (honesty rule).
    final hal = context.watch<HalTelemetryService>();
    final soc = svc.readNumeric('790', '0005');
    // v0.1.29+104: SOH prefers the independent coulomb-counted estimate
    // (svc.sohAhPct) when available, shown as a bare percent. Until the first
    // qualifying charge session it falls back to the BMS value (0x0029),
    // tagged "(BMS)" so the source is honest. sohDisplay carries the formatted
    // string; sohIsAh distinguishes the two for any downstream styling.
    // v0.1.29+105: HAL coulomb-counted SOH (dongle-free, hal.halSohAhPct) is
    // preferred ahead of the UDS estimate so a dongle-free charge produces a
    // real SOH; UDS (svc.sohAhPct) stays as the dongle path, BMS last.
    final sohAh = hal.halSohAhPct ?? svc.sohAhPct;
    final sohBms = svc.readNumeric('790', '0029');
    final String sohDisplay = sohAh != null
        ? '${sohAh.round()}%'
        : (sohBms != null ? '${sohBms.toInt()}% (BMS)' : '—');
    final tempRaw = svc.readNumeric('790', '002F');
    final cellMin = svc.readNumeric('790', '002B');
    final cellMax = svc.readNumeric('790', '002D');
    final odo = hal.useHalForOdometer ? hal.halOdometerKm : svc.readNumeric('791', '0026');
    final gear = hal.useHalForGear
        ? hal.halGear
        : svc.readNumeric('791', '0009');
    final cells = svc.liveCells;
    final isCharging = svc.isCharging;
    // v0.1.29+102: EV range — HAL hybrid estimate when SOC is available via
    // HAL (dongle-free), else OBD2. Invisible substitution like speed/SOC.
    final rangeKm = hal.useHalForRange ? hal.halRangeKm : svc.rangeEstimateKm;
    final tripEnergy = svc.tripEnergyKwh;
    final cycles = svc.cycleCount;
    // v0.1.29+2: primary live pack V = sum-of-cells avg × N (BMS cell count).
    // Synchronised with wide dashboard's hero panel. hvBusV and platform
    // nominal kept as fallbacks only — both proven unreliable under load
    // (DC 2026-05-22: hvBus showed -83V offset vs cells; AC 2026-05-23:
    // hvBus showed 405.5V while cells×136 = 458.9V → -53V offset).
    // See connection.dart packVoltageFromCells for full rationale.
    // v0.1.29+66: prefer the HAL direct pack-voltage measurement when
    // fresh (445-454 V live-verified); OBD2 sum-of-cells is the fallback.
    final packFromCells = hal.useHalForPackV
        ? hal.halPackVoltage
        : svc.packVoltageFromCells;
    final packV = svc.packVoltageV;       // platform constant ~450V (fallback only)
    final hvBus = svc.hvBusV;              // HV bus (live but lies under charge)
    final parkingEngaged = svc.parkingPawlEngaged;
    final chargedSession = svc.chargedThisSessionKwh;
    // v0.1.22: live signals from PDU (740) added to UI.
    final vehicleSpeed =
        hal.useHalForSpeed ? hal.halSpeedKmh : svc.vehicleSpeedKmh;
    final pduTemp1 = svc.readNumeric('740', '0010'); // PDU heatsink 1
    final pduTemp2 = svc.readNumeric('740', '0011'); // PDU heatsink 2

    // v0.1.29+36: surface the +33 power-flow data layer on the dashboard.
    // These are READ-ONLY getters from connection.dart (P = V×I, flow sign,
    // Wh/km) — no protocol logic touched. Magnitude inherits the
    // PROVISIONAL current scale, so we show power/flow/consumption (which
    // are scale-proportional and sign-exact) and deliberately NOT raw amps.
    // v0.1.29+66: power prefers the HAL-derived product (pack_current ×
    // pack_voltage, both direct measurements, same discharge-positive
    // convention) over the OBD2 provisional-scale path when fresh.
    final powerKw = hal.useHalForPower ? hal.halPowerKw : svc.instantPowerKw;
    final flowDir = hal.useHalForPower
        ? hal.halFlowDir
        : svc.powerFlowDirection;                   // 1 / −1 / 0 (sign exact)
    final consWhKm = svc.instantConsumptionWhKm;    // null below 3 km/h

    // v0.1.29: detect "tall portrait" head units (BZ3 in particular).
    //
    // Field measurement 2026-05-23 (BZ3 owner's screenshot of in-app
    // _LayoutDiagnostic):
    //   logical:    720.0 × 1106.0 dp
    //   physical:   1080 × 1659 px · dpr=1.5
    //   padding:    all zero (system bars don't eat MQ in this context)
    //
    // The original v0.1.29+1 thresholds (height > 1400 && width > 700)
    // assumed dpr ≈ 1.075 (from 172 marketing PPI / 160), which would
    // have given ~1786 dp height. Reality: Android pins hdpi bucket
    // (dpr=1.5) regardless of physical PPI, and the head unit reports
    // only 1659 px usable height (261 px likely consumed by the host
    // OS / inter-app layout) — so logical height tops out at 1106 dp.
    // The 1400 threshold never fired and BZ3 fell to phone-style 2-col
    // for two whole patch cycles.
    //
    // v0.1.29+7 fix: shift the threshold to the actual numbers, with
    // ~10% margin on both sides:
    //   isTall: height >= 1000 dp (BZ3 measured 1106; phones ≤ ~900)
    //   isWide: width  >= 720 dp (BZ3 measured 720; phones ≤ ~500)
    // The width margin is tight (0 dp at the BZ3 number) but we know
    // the value is exact: it's 1080 physical / 1.5 dpr, a clean ratio.
    // If a future head unit reports 700 dp width exactly we can lower
    // to 700; until then 720 stays.
    //
    // Phones in portrait (412-450 dp width) fail isWide. Phones in
    // landscape (700-900 dp width × 350-450 dp height) fail isTall.
    // BZ5 head unit gates earlier in home.dart via useHeadUnitLayout
    // (needs width > height) and never reaches this code.
    final mq = MediaQuery.of(context);
    final isTall = mq.size.height >= 1000;
    final isWideEnough = mq.size.width >= 720;
    final useTallLayout = isTall && isWideEnough;
    final gridCols = useTallLayout ? 3 : 2;

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        // v0.1.29+8: top zone differs between BZ3 tall portrait and phone:
        //   - Tall: Row(Speed/Status | _TallSocCard) at 170 dp height.
        //     Uses the same SpeedAndStatusStrip widget as the BZ5 wide
        //     Driver tab, in compact mode.
        //   - Phone: existing _SocCard full-width (no Speed panel —
        //     phones don't have the real estate for a big speed read
        //     and the existing UX has been stable since v0.1.0).
        if (useTallLayout)
          SizedBox(
            height: 170,
            child: Row(
              children: [
                const Expanded(
                  flex: 3,
                  child: SpeedAndStatusStrip(compact: true),
                ),
                const SizedBox(width: 8),
                Expanded(
                  flex: 2,
                  child: _TallSocCard(
                    soc: soc,
                    socPrecise: hal.useHalForSoc
                        ? hal.halSocPct
                        : svc.socPrecisePct,
                    rangeKm: rangeKm,
                    gear: gear,
                    parkingEngaged: parkingEngaged,
                    isCharging: isCharging,
                  ),
                ),
              ],
            ),
          )
        else
          _SocCard(
              soc: soc,
              // v0.1.29+66: HAL soc_display = the instrument-cluster %
              // (live-verified equal on 2026-06-11); preferred when fresh.
              socPrecise:
                  hal.useHalForSoc ? hal.halSocPct : svc.socPrecisePct,
              rangeKm: rangeKm),
        const SizedBox(height: 12),
        if (isCharging) _ChargingBanner(svc: svc, chargedSession: chargedSession),
        if (isCharging) const SizedBox(height: 12),
        // v5: Parking pawl indicator. Moved BEFORE the grid on tall layout
        // so the safety indicator sits high in the scroll position; on
        // phone it stays below the grid (existing UX).
        if (useTallLayout && parkingEngaged != null) ...[
          _ParkingPawlRow(engaged: parkingEngaged),
          const SizedBox(height: 12),
        ],
        // v0.1.29+8: trip section differs:
        //   - Tall: full TripMetricsPanel (6 cells + cost) from
        //     widgets/driver_panels.dart, in compact mode. Same widget
        //     as BZ5 Driver tab — only one source of truth now.
        //   - Phone: existing _TripCard mini-strip (just trip ID +
        //     kWh used). Compact for phone real estate.
        if (svc.currentTripId != null && tripEnergy != null) ...[
          if (useTallLayout)
            // v0.1.29+16: SizedBox(height: 200) — was 130 in +13 which
            // overlapped row2 onto row1 ("наложение строчек" per BZ3
            // owner). 200 dp gives:
            //   header line (~28dp) + SizedBox(6) + Expanded row1 +
            //   Divider(16) + Expanded row2 ≈ 200 dp
            // Expanded'ы on row1/row2 are added in driver_panels.dart
            // compact mode in the same patch — without them the rows
            // would still collapse to intrinsic size and leave
            // ~44 dp of empty padding at the bottom.
            const SizedBox(
              height: 200,
              child: TripMetricsPanel(compact: true),
            )
          else
            _TripCard(svc: svc),
          const SizedBox(height: 12),
        ],
        _GridCards(
          crossAxisCount: gridCols,
          children: [
            _MetricCard(
              icon: Icons.favorite,
              color: Colors.green,
              label: 'SOH',
              value: sohDisplay,
            ),
            _MetricCard(
              icon: Icons.thermostat,
              color: Colors.orange,
              label: S.of('dash.battery_s'),
              // v0.1.29+72: HAL probe_highest_temp (verified = battery
              // temp) when fresh, else OBD2 790/002F. Decoder применяет
              // offset −40, не вычитаем повторно.
              value: (hal.useHalForBatteryTemp && hal.halBatteryTempC != null)
                  ? '${hal.halBatteryTempC!.toInt()}°C'
                  : tempRaw != null
                      ? '${tempRaw.toInt()}°C'
                      : '—',
            ),
            // v0.1.29+2: Primary = sum-of-cells average × N (the only
            // physically-correct pack V we have). Fallbacks marked '*' kept
            // for visibility when cells haven't been polled yet:
            //   1. packFromCells — primary, sum-of-cells average × N
            //   2. hvBusV — live HV bus (790/0x0015); ±50V offset under charge
            //   3. packV nominal — 740/0x0022 platform constant (~450V)
            _MetricCard(
              icon: Icons.bolt,
              color: Colors.yellowAccent,
              label: 'Pack V',
              value: packFromCells != null
                  ? '${packFromCells.toStringAsFixed(1)} V'
                  : hvBus != null
                      ? '${hvBus.toStringAsFixed(1)} V*'
                      : packV != null
                          ? '${packV.toStringAsFixed(1)} V*'
                          : '—',
            ),
            _MetricCard(
              icon: Icons.speed,
              color: Colors.blue,
              label: S.of('dash.odometer_s'),
              value: odo != null ? '${odo.toStringAsFixed(1)} km' : '—',
            ),
            // v0.1.29+8: Cycles and Gear are hidden on tall layout —
            // Gear is shown inside _TallSocCard as a P/D/R/N badge,
            // and Cycles wasn't critical enough to justify duplication.
            // Phone layout keeps both (existing UX).
            if (!useTallLayout)
              _MetricCard(
                icon: Icons.refresh,
                color: Colors.purpleAccent,
                label: 'Cycles',
                value: cycles != null ? '$cycles' : '—',
              ),
            if (!useTallLayout)
              _MetricCard(
                icon: Icons.directions_car,
                color: _gearColor(gear, parkingEngaged, isCharging),
                label: 'Gear',
                // v5: правильный mapping 1=P, 2=R, 3=N, 4=D
                value: _gearStr(gear),
              ),
            // v0.1.22: vehicle speed from 740/0x0008 (verified 2026-05-19).
            // On tall layout the Speed is the huge cell at top-left, so
            // we don't duplicate it in the grid. On phone it's a small
            // conditional cell that only appears at standstill > 0.5 km/h
            // (a permanent "0 km/h" would be noise).
            if (!useTallLayout && vehicleSpeed != null && vehicleSpeed > 0.5)
              _MetricCard(
                icon: Icons.speed,
                color: Colors.cyanAccent,
                label: 'Speed',
                value: '${vehicleSpeed.toStringAsFixed(0)} km/h',
              ),
            // v0.1.29+36: live pack power (+33 data layer). Discharge is
            // shown blue (energy leaving), regen green (energy returning),
            // near-zero grey. Magnitude is provisional-scale, so we show
            // kW (proportional, sign-exact) — not raw amps. Hidden when
            // current is stale/unavailable (getter returns null).
            //
            // BZ3: VERIFIED 2026-06-04. The earlier caveat ("790/0009 NOT
            // verified on BZ3, different BMS mapping") is retired. A
            // friend's livelog session 2 (1308 cycles over an 18-min
            // city drive) shows the BZ3 BMS responds identically to BZ5
            // on this DID — median standstill raw 5021 (≈ BZ5 zero 5018,
            // ECU-to-ECU variance ±3 LSB → ±0.3 A), peak +264 A and
            // −117 A bound a physically sane discharge/regen envelope
            // for the BZ3 pack. The +47 C33 calibration constants
            // (zero=5018, ampsPerLsb=0.1021) apply unchanged. No more
            // '*' suffix on the value and no '?' on the label — BZ3
            // owners now see the same readout shape as BZ5.
            //
            // v0.1.29+40: these cards are ALWAYS present (no `if`), even
            // when their value is null. Previously they were conditional,
            // so on a stop instantConsumptionWhKm went null → the card
            // dropped out of the grid → every card after it shifted into
            // the gap (BZ3 owner: "consumption disappears at a stop and
            // the other tiles jump around"). Keeping the cells in place
            // and showing '—' holds the layout stable; the figure returns
            // when moving again without anything reflowing.
            // v0.1.29+50: Power/Regen and Consumption cards now use
            // hold-last-value wrappers (_PowerCard, _ConsumptionCard).
            // See their class docstring for the why. The +40 "always
            // present, never reflow" property is preserved — each
            // wrapper always renders one _MetricCard, just with the
            // last-known value (stale=true) instead of a '—' during
            // brief polling gaps. After 8 seconds without fresh data
            // they fall back to '—'.
            _PowerCard(powerKw: powerKw, flowDir: flowDir),
            _ConsumptionCard(consWhKm: consWhKm),
            // v0.1.22: PDU heatsink temps (live, 740/0x0010 + 0x0011).
            // Yesterday's hottest values were ~58°C after spirited
            // driving; idle baseline 30-35°C.
            // v0.1.29+40: also made persistent (show '—' when absent) so
            // the grid tail can't reflow either — same fix as Power/
            // Consumption above.
            _MetricCard(
              icon: Icons.device_thermostat,
              color: pduTemp1 != null ? _pduTempColor(pduTemp1) : Colors.grey,
              label: 'PDU T1',
              value: pduTemp1 != null ? '${pduTemp1.toInt()}°C' : '—',
            ),
            _MetricCard(
              icon: Icons.device_thermostat,
              color: pduTemp2 != null ? _pduTempColor(pduTemp2) : Colors.grey,
              label: 'PDU T2',
              value: pduTemp2 != null ? '${pduTemp2.toInt()}°C' : '—',
            ),
          ],
        ),
        const SizedBox(height: 12),
        // v5: Parking pawl indicator on PHONE layout sits below the grid
        // (existing UX). Tall layout already showed it above the grid.
        if (!useTallLayout && parkingEngaged != null) ...[
          _ParkingPawlRow(engaged: parkingEngaged),
          const SizedBox(height: 12),
        ],
        _CellsSummaryCard(
          cells: cells,
          cellMin: cellMin,
          cellMax: cellMax,
          soc: soc,
          smoothedSpread: svc.smoothedCellSpread,
        ),
        const SizedBox(height: 16),
        // v0.1.29+8: Calibration card hidden on tall layout entirely
        // (per BZ3 owner's request — they have plenty of vertical room
        // for the useful metrics and don't need the technical note).
        // Phone keeps it: still useful as a self-documenting reference
        // when explaining the app to new users.
        if (!useTallLayout) _PhysicsModelCard(),
      ],
    );
  }

  /// v5: Корректный mapping проверен на практике 1 мая 2026.
  String _gearStr(double? g) {
    if (g == null) return '—';
    return switch (g.toInt()) {
      1 => 'P', 2 => 'R', 3 => 'N', 4 => 'D', _ => '?',
    };
  }

  /// v5: Цвет gear-карточки в зависимости от состояния.
  Color _gearColor(double? g, bool? parkingEngaged, bool isCharging) {
    if (g == null) return Colors.grey;
    if (parkingEngaged == true) return Colors.lightBlueAccent;
    if (isCharging) return Colors.amber;
    return switch (g.toInt()) {
      1 => Colors.lightBlueAccent,  // P
      2 => Colors.redAccent,         // R
      3 => Colors.orangeAccent,      // N
      4 => Colors.greenAccent,       // D
      _ => Colors.grey,
    };
  }

  /// v0.1.22: PDU temperature severity gradient.
  /// Calibration based on observed range 2026-05-19:
  ///   - 30 °C  cool / overnight rest        → blue
  ///   - 40 °C  brief driving                 → green
  ///   - 50 °C  sustained driving              → yellow
  ///   - 60 °C  spirited / mountain ascent     → orange
  ///   - 70 °C+ thermal limit approaching      → red
  /// Per BYD spec, IGBT junction redlines around 125 °C; heatsink reads
  /// significantly lower than junction, so 70 °C heatsink ≈ 95-100 °C
  /// junction. Anything above 70 °C here would deserve a warning toast,
  /// but we don't have that infrastructure yet — color is the only cue.
  Color _pduTempColor(double t) {
    if (t < 35) return Colors.lightBlueAccent;
    if (t < 45) return Colors.greenAccent;
    if (t < 55) return Colors.yellowAccent;
    if (t < 65) return Colors.orangeAccent;
    return Colors.redAccent;
  }
}

/// v0.1.29+52: power-flow colour helper hoisted to file scope so the
/// new _PowerCard StatefulWidget (added in +50) can call it. It was
/// previously an instance method on _Connected — CI release-build in
/// +50 caught the cross-class call (_PowerCardState._flowColor: method
/// isn't defined). Pure motion: same body, same callers in _Connected
/// still work (Dart resolves top-level functions from inside class
/// methods without qualifier).
///
/// Regen (energy returning to pack, dir = −1) green, discharge
/// (energy leaving, dir = 1) blue, near-zero deadband grey. Matches
/// the +33 powerFlowDirection contract from connection.dart.
Color _flowColor(int? dir) {
  if (dir == -1) return Colors.greenAccent;
  if (dir == 1) return Colors.lightBlueAccent;
  return Colors.grey;
}

/// v5: Parking pawl status — explicit indicator
class _ParkingPawlRow extends StatelessWidget {
  final bool engaged;
  const _ParkingPawlRow({required this.engaged});

  @override
  Widget build(BuildContext context) {
    return Card(
      color: engaged ? Colors.green.shade900 : Colors.grey.shade900,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 16),
        child: Row(
          children: [
            Icon(
              engaged ? Icons.lock : Icons.lock_open,
              color: engaged ? Colors.greenAccent : Colors.grey,
              size: 20,
            ),
            const SizedBox(width: 12),
            Text(
              engaged
                  ? S.of('dash.pawl_engaged_long')
                  : S.of('dash.pawl_released_long'),
              style: const TextStyle(fontSize: 13, letterSpacing: 0.3),
            ),
          ],
        ),
      ),
    );
  }
}

class _SocCard extends StatelessWidget {
  final double? soc;          // integer SOC from 790/0x0005 (fallback)
  final double? socPrecise;   // v0.1.21: precise SOC from 790/0x1FFD high16/100
  final double? rangeKm;
  const _SocCard({this.soc, this.socPrecise, this.rangeKm});

  @override
  Widget build(BuildContext context) {
    // v0.1.21+3: display SOC with 0.1% resolution. Prefer the precise
    // source (1FFD); fall back to integer (0x0005) until 1FFD has been
    // polled at least once.
    final displaySoc = socPrecise ?? soc;
    final pct = displaySoc ?? 0;
    final color = pct < 20 ? Colors.red : pct < 50 ? Colors.orange : Colors.green;

    return Card(
      elevation: 4,
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(S.of('drv.soc'),
                style: const TextStyle(
                    fontSize: 12, letterSpacing: 1.5, color: Colors.grey)),
            const SizedBox(height: 8),
            Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text(
                  // v0.1.21+3: one decimal place. Split integer and
                  // fractional parts so the big "54" stays prominent and
                  // ".3" is rendered slightly smaller — keeps the card
                  // height stable across whole-number and fractional
                  // values and avoids the giant digit jiggling between
                  // single and triple-digit width.
                  //
                  // Floating-point safety: round to nearest tenth FIRST,
                  // then split. Naive `truncate()` would render 48.30
                  // (stored as 48.2999...) as "48.2" instead of "48.3".
                  // We use round(x*10)/10 to snap to the visible
                  // resolution, then int-truncate to separate digits.
                  displaySoc != null
                      ? (() {
                          final r = (displaySoc * 10).round() / 10;
                          return r.truncate().toString();
                        })()
                      : '—',
                  style: TextStyle(fontSize: 72, fontWeight: FontWeight.w300, color: color, height: 1.0),
                ),
                if (displaySoc != null)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 6),
                    child: Text(
                      (() {
                        final r = (displaySoc * 10).round() / 10;
                        return '.${((r - r.truncate()) * 10).round()}';
                      })(),
                      style: TextStyle(fontSize: 36, fontWeight: FontWeight.w300, color: color, height: 1.0),
                    ),
                  ),
                const SizedBox(width: 4),
                const Padding(
                  padding: EdgeInsets.only(bottom: 12),
                  child: Text('%', style: TextStyle(fontSize: 24, color: Colors.grey)),
                ),
                const Spacer(),
                if (rangeKm != null)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 12),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        Text(S.of('dash.range_s'),
                            style: const TextStyle(
                                fontSize: 11, color: Colors.grey)),
                        Text('~${rangeKm!.toInt()} km',
                            style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w400)),
                      ],
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 8),
            ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: LinearProgressIndicator(
                value: pct / 100,
                minHeight: 8,
                backgroundColor: Colors.grey.shade800,
                valueColor: AlwaysStoppedAnimation(color),
              ),
            ),
            // v0.1.29: removed the factory-spec consumption + capacity
            // footer that lived here. The 14.4 kWh/100km number was a
            // WLTP marketing figure not matching observed reality
            // (16-18 kWh/100km on this car), and the 65.28 kWh
            // capacity is BZ5-specific (BZ3 has 49.92 kWh). Capacity
            // remains documented in the CALIBRATION card at the
            // bottom of the dashboard for diagnostic reference.
          ],
        ),
      ),
    );
  }
}

/// v0.1.29+8: compact SoC card for BZ3 tall portrait Row(Speed | SoC).
///
/// Sits inside `Expanded(flex: 2)` inside a `SizedBox(height: 170)` —
/// so we have bounded height and can use Expanded() internally for the
/// big SOC FittedBox to fill available vertical room.
///
/// Renders:
///   - "STATE OF CHARGE" label (small)
///   - SOC % big with 1 decimal (red < 20, orange < 50, green ≥ 50)
///   - Range estimate (small line)
///   - Progress bar
///   - Gear/Park badge (replaces the standalone Gear cell removed
///     from the metric grid on tall layout)
class _TallSocCard extends StatelessWidget {
  final double? soc;
  final double? socPrecise;
  final double? rangeKm;
  final double? gear;
  final bool? parkingEngaged;
  final bool isCharging;
  const _TallSocCard({
    required this.soc,
    required this.socPrecise,
    required this.rangeKm,
    required this.gear,
    required this.parkingEngaged,
    required this.isCharging,
  });

  @override
  Widget build(BuildContext context) {
    final displaySoc = socPrecise ?? soc;
    final pct = displaySoc ?? 0;
    // Same threshold band as _SocCard for consistency across phone/tall.
    final color = pct < 20
        ? Colors.redAccent
        : pct < 50
            ? Colors.orangeAccent
            : Colors.greenAccent;

    // FP-safe one-decimal split — same approach as the driver wide
    // _SocCard, kept in lockstep so the BZ5 and BZ3 SOC displays show
    // identical values down to the displayed decimal.
    String big = '—', small = '';
    if (displaySoc != null) {
      final r = (displaySoc * 10).round() / 10;
      big = r.truncate().toString();
      small = '.${((r - r.truncate()) * 10).round()}';
    }

    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 10, 14, 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(S.of('drv.soc'),
                style: const TextStyle(
                    fontSize: 10, letterSpacing: 1.0, color: Colors.grey)),
            const SizedBox(height: 4),
            Expanded(
              child: FittedBox(
                fit: BoxFit.scaleDown,
                alignment: Alignment.centerLeft,
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Text(big,
                        style: TextStyle(
                            fontSize: 56,
                            fontWeight: FontWeight.w400,
                            color: color,
                            height: 0.9)),
                    Padding(
                      padding: const EdgeInsets.only(bottom: 4),
                      child: Text(small,
                          style: TextStyle(
                              fontSize: 24,
                              fontWeight: FontWeight.w400,
                              color: color,
                              height: 0.9)),
                    ),
                    const Padding(
                      padding: EdgeInsets.only(bottom: 8),
                      child: Text(' %',
                          style: TextStyle(
                              fontSize: 14, color: Colors.grey)),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 4),
            if (rangeKm != null)
              Text(
                  S
                      .of('dash.range_inline')
                      .replaceFirst('{n}', '${rangeKm!.toInt()}'),
                  style: const TextStyle(
                      fontSize: 11, color: Colors.white70)),
            const SizedBox(height: 4),
            ClipRRect(
              borderRadius: BorderRadius.circular(3),
              child: LinearProgressIndicator(
                value: (pct / 100).clamp(0.0, 1.0),
                minHeight: 4,
                backgroundColor: Colors.grey.shade800,
                valueColor: AlwaysStoppedAnimation(color),
              ),
            ),
            const SizedBox(height: 6),
            Row(
              children: [
                Icon(Icons.directions_car,
                    size: 13,
                    color: _gearTintColor(gear, parkingEngaged, isCharging)),
                const SizedBox(width: 4),
                Text(_gearLabel(gear, isCharging),
                    style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w500,
                        color: _gearTintColor(
                            gear, parkingEngaged, isCharging))),
              ],
            ),
          ],
        ),
      ),
    );
  }

  // Mapping kept inline (not a free function) because it shares the
  // colour table with _gearColor in DashboardScreen but adds the
  // charging glyph case which the top-level helper doesn't.
  String _gearLabel(double? g, bool isCharging) {
    if (g == null && isCharging) return '⚡';
    if (g == null) return '—';
    return switch (g.toInt()) {
      1 => 'P', 2 => 'R', 3 => 'N', 4 => 'D', _ => '?',
    };
  }

  Color _gearTintColor(double? g, bool? parking, bool isCharging) {
    if (g == null && isCharging) return Colors.amber;
    if (g == null) return Colors.grey;
    if (parking == true) return Colors.lightBlueAccent;
    return switch (g.toInt()) {
      1 => Colors.lightBlueAccent,
      2 => Colors.redAccent,
      3 => Colors.orangeAccent,
      4 => Colors.greenAccent,
      _ => Colors.grey,
    };
  }
}

class _ChargingBanner extends StatelessWidget {
  final ConnectionService svc;
  final double? chargedSession;
  const _ChargingBanner({required this.svc, this.chargedSession});

  @override
  Widget build(BuildContext context) {
    final power = svc.chargingPowerKw;
    final soc = svc.readNumeric('790', '0005') ?? 0;
    final remainingKwh = (100 - soc) / 100 * 65.28;
    final etaHours = power > 0.1 ? remainingKwh / power : null;

    return Card(
      color: Colors.indigo.shade900,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            Row(
              children: [
                const Icon(Icons.bolt, color: Colors.amber, size: 36),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(S.of('dash.charging'),
                          style: const TextStyle(
                              letterSpacing: 1.5, color: Colors.amber)),
                      Text(
                          power > 0.1
                              ? '${power.toStringAsFixed(1)} kW'
                              : S.of('dash.connected'),
                          style: const TextStyle(fontSize: 24, fontWeight: FontWeight.w500)),
                    ],
                  ),
                ),
                if (etaHours != null)
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      Text(S.of('dash.eta100'),
                          style: const TextStyle(
                              fontSize: 11, color: Colors.grey)),
                      Text(_fmtHours(etaHours),
                          style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w500)),
                    ],
                  ),
              ],
            ),
            // v5: Charged this session — заменяет старый "Lifetime in"
            if (chargedSession != null && chargedSession! > 0.05) ...[
              const Divider(height: 24, color: Colors.white24),
              Row(
                children: [
                  const Icon(Icons.water_drop, color: Colors.lightBlueAccent, size: 18),
                  const SizedBox(width: 8),
                  Text(S.of('dash.this_session_inline'),
                      style: const TextStyle(fontSize: 13, color: Colors.grey)),
                  Text('${chargedSession!.toStringAsFixed(2)} kWh',
                      style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w500)),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }

  String _fmtHours(double h) {
    final hours = h.floor();
    final mins = ((h - hours) * 60).round();
    return '${hours}h ${mins}m';
  }
}

class _TripCard extends StatelessWidget {
  final ConnectionService svc;
  const _TripCard({required this.svc});

  @override
  Widget build(BuildContext context) {
    final tripEnergy = svc.tripEnergyKwh ?? 0;
    return Card(
      color: Colors.green.shade900,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          children: [
            const Icon(Icons.fiber_manual_record, color: Colors.red),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                      S
                          .of('dash.trip_live')
                          .replaceFirst('{id}', '${svc.currentTripId}'),
                      style: const TextStyle(letterSpacing: 1.0)),
                  if (tripEnergy > 0)
                    Text(
                        S
                            .of('dash.kwh_used')
                            .replaceFirst(
                                '{e}', tripEnergy.toStringAsFixed(2)),
                        style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w500)),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _PhysicsModelCard extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Consumer<ConnectionService>(
      builder: (context, svc, _) {
        final cellCount = svc.packCellCount;
        final moduleCount = svc.packModuleCount;
        final minIdx = svc.globalMinCellIndex;
        final maxIdx = svc.globalMaxCellIndex;

        // Footer line — показываем реальные значения если получили,
        // иначе fallback к жёстко заданным (нашли в реверсе 2026-05-03).
        final cellsText = S
            .of('dash.cells_fmt')
            .replaceFirst('{n}', '${cellCount ?? 136}');
        final modText = S
            .of('dash.modules_fmt')
            .replaceFirst('{n}', '${moduleCount ?? 10}');

        return Card(
          color: Colors.grey.shade900,
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    const Icon(Icons.science_outlined,
                        size: 14, color: Colors.grey),
                    const SizedBox(width: 4),
                    Text(S.of('dash.calibration'),
                        style: const TextStyle(
                            fontSize: 11,
                            letterSpacing: 1.0,
                            color: Colors.grey)),
                  ],
                ),
                const SizedBox(height: 8),
                Text(
                  '65.28 kWh · $cellsText in $modText (LFP blade)\n'
                  '• Pack V: avg(cells) × N (sum-of-cells, primary)\n'
                  '   ↳ fallbacks: 790/0x0015 (HV bus), 740/0x0022 (nominal)\n'
                  '• SOC: BMS 0x0005 · SOH: BMS 0x0029\n'
                  '• Charge counter: BMS 0x0B00, ≈460 Wh/unit\n'
                  '• Cycle count: BMS 0x0B02\n'
                  '• Gear: VCU 0x0009 (1=P, 2=R, 3=N, 4=D)',
                  style: const TextStyle(fontSize: 11, color: Colors.grey, height: 1.5),
                ),
                if (minIdx != null && maxIdx != null) ...[
                  const SizedBox(height: 6),
                  Text(
                    S
                        .of('dash.live_extremes')
                        .replaceFirst('{a}', '$minIdx')
                        .replaceFirst('{b}', '$maxIdx')
                        .replaceFirst('{c}', cellsText),
                    style: const TextStyle(fontSize: 11, color: Colors.grey, height: 1.4),
                  ),
                ],
                // v0.1.29+6: diagnostic — only show on non-tall layouts.
                // Helps identify why BZ3 isn't triggering the tall portrait
                // layout despite being a tall portrait head unit. Hidden on
                // BZ5 wide head unit (it doesn't render this screen anyway —
                // uses dashboard_wide.dart) and on tall layouts where the
                // threshold already worked. Shows: logical size, device
                // pixel ratio, system padding, view insets (keyboard), and
                // the threshold result.
                _LayoutDiagnostic(),
              ],
            ),
          ),
        );
      },
    );
  }
}

/// Inline diagnostic for understanding why a given screen falls into the
/// phone vs tall-portrait layout bucket. Self-contained — reads MediaQuery
/// from its own context. Renders nothing when the tall layout would have
/// activated (threshold worked, no investigation needed).
class _LayoutDiagnostic extends StatelessWidget {
  const _LayoutDiagnostic();

  // v0.1.29+56: master switch, default OFF. The block existed to debug
  // why the BZ3 tall layout wasn't triggering (v0.1.29+7). The tall
  // layout has been verified working on the BZ3 since +48, so the
  // amber debug text is retired from production UI. Flip to true (and
  // rebuild) if a new head-unit model shows layout-detection problems.
  static const bool kShowLayoutDiagnostic = false;

  @override
  Widget build(BuildContext context) {
    if (!kShowLayoutDiagnostic) return const SizedBox.shrink();
    final mq = MediaQuery.of(context);
    final size = mq.size;
    final dpr = mq.devicePixelRatio;
    final pad = mq.padding;
    final ins = mq.viewInsets;
    // v0.1.29+7: thresholds here MUST mirror the detector in
    // DashboardScreen.build above. If you change one, change the other.
    // A divergence would lie to the user about why their layout is what
    // it is.
    final isTall = size.height >= 1000;
    final isWide = size.width >= 720;
    final tallLayoutActive = isTall && isWide;
    // v0.1.29+7: hide unless we're on a head-unit-class screen where
    // the diagnostic actually matters. Phones (short side < 600 dp)
    // never get the tall layout intentionally, so the debug block
    // would be noise. Head units that DO trigger tall layout also
    // hide the block (no investigation needed).
    if (size.shortestSide < 600) return const SizedBox.shrink();
    if (tallLayoutActive) return const SizedBox.shrink();
    final physicalW = (size.width * dpr).round();
    final physicalH = (size.height * dpr).round();
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Text(
        '— layout debug ($_kDiagVersion) —\n'
        'logical: ${size.width.toStringAsFixed(1)} × '
        '${size.height.toStringAsFixed(1)} dp\n'
        'physical: $physicalW × $physicalH px · dpr=$dpr\n'
        'padding: L=${pad.left.toStringAsFixed(0)} T=${pad.top.toStringAsFixed(0)} '
        'R=${pad.right.toStringAsFixed(0)} B=${pad.bottom.toStringAsFixed(0)}\n'
        'viewInsets: B=${ins.bottom.toStringAsFixed(0)}\n'
        'isTall(>=1000)=$isTall · isWide(>=720)=$isWide → '
        'tallLayout=$tallLayoutActive',
        style: const TextStyle(
          fontSize: 10,
          color: Colors.amber,
          height: 1.4,
          fontFeatures: [FontFeature.tabularFigures()],
        ),
      ),
    );
  }
}

/// Bump when changing the diagnostic format — helps cross-reference
/// screenshots to specific app versions while iterating.
const String _kDiagVersion = 'v0.1.29+110';

/// v0.1.29+94: public alias of the build version string for display outside
/// dashboard (e.g. the About screen's APP card). Single literal source — the
/// version-sync gates still pin `_kDiagVersion` above; this just re-exports
/// it so other screens don't duplicate the number.
const String kAppVersion = _kDiagVersion;

class _GridCards extends StatelessWidget {
  final List<Widget> children;
  /// v0.1.29: configurable column count. Defaults to 2 (phone case);
  /// tall portrait head units like BZ3 pass 3 to get more density and
  /// free up vertical space for the driver/cells sections below.
  final int crossAxisCount;
  const _GridCards({required this.children, this.crossAxisCount = 2});

  @override
  Widget build(BuildContext context) {
    return GridView.count(
      crossAxisCount: crossAxisCount,
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      mainAxisSpacing: 8,
      crossAxisSpacing: 8,
      // v0.1.29+16: bumped 4.5 → 3.0 per BZ3 owner feedback
      // ("слишком узко", overall has unused space at the bottom of
      // the screen). At 4.5 cards were 50dp tall and rendered in
      // compact one-row layout (Row(icon, label, value)) which felt
      // cramped. 3.0 yields ~75dp cards — above the _MetricCard
      // compact threshold (maxHeight < 70), so they render in the
      // familiar phone-style Column layout (icon+label header, big
      // value below), but in a denser 3-col grid than phone uses.
      // 2-col phone layout unchanged at 1.6.
      childAspectRatio: crossAxisCount == 3 ? 3.0 : 1.6,
      children: children,
    );
  }
}

class _MetricCard extends StatelessWidget {
  final IconData icon;
  final Color color;
  final String label;
  final String value;
  // v0.1.29+50: when true, the value text renders at reduced opacity
  // to signal "this is the last known reading, not the current one".
  // Used by _PowerCard / _ConsumptionCard during their hold-window to
  // surface continuity without lying about freshness. Default false
  // preserves behaviour for all other cards.
  final bool stale;
  const _MetricCard({
    required this.icon, required this.color, required this.label, required this.value,
    this.stale = false,
  });

  @override
  Widget build(BuildContext context) {
    // v0.1.29+13: auto-detect compact mode via LayoutBuilder. With
    // _GridCards aspect 4.5 on tall portrait (3-col), card height is
    // ~50dp — not enough room for a Column(header, value) layout. We
    // switch to a single Row(icon+label, value) which fits in 50dp.
    // Phone 2-col layout still gets ~120dp tall cards → keeps the
    // original Column layout with Spacer and unchanged sizes.
    return LayoutBuilder(builder: (context, constraints) {
      final compact = constraints.maxHeight < 70;
      if (compact) {
        // One-row layout for tall portrait. Icon + label on the left
        // (Expanded so it eats the slack); value on the right
        // FittedBox-scaled. EdgeInsets tightened to give the value
        // more horizontal room.
        return Card(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(10, 0, 12, 0),
            child: Row(
              children: [
                Icon(icon, color: color, size: 14),
                const SizedBox(width: 5),
                Expanded(
                  child: Text(label.toUpperCase(),
                      style: const TextStyle(
                          fontSize: 9,
                          letterSpacing: 0.5,
                          color: Colors.grey),
                      overflow: TextOverflow.ellipsis),
                ),
                const SizedBox(width: 6),
                FittedBox(
                  fit: BoxFit.scaleDown,
                  alignment: Alignment.centerRight,
                  child: Opacity(
                    opacity: stale ? 0.5 : 1.0,
                    child: Text(value,
                        style: const TextStyle(
                            fontSize: 18, fontWeight: FontWeight.w500)),
                  ),
                ),
              ],
            ),
          ),
        );
      }
      // Phone 2-col: unchanged from pre-v0.1.29+13.
      return Card(
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(children: [
                Icon(icon, color: color, size: 18),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(label.toUpperCase(),
                      style: const TextStyle(
                          fontSize: 10,
                          letterSpacing: 0.5,
                          color: Colors.grey),
                      overflow: TextOverflow.ellipsis),
                ),
              ]),
              const Spacer(),
              FittedBox(
                fit: BoxFit.scaleDown,
                alignment: Alignment.centerLeft,
                child: Opacity(
                  opacity: stale ? 0.5 : 1.0,
                  child: Text(value,
                      style: const TextStyle(
                          fontSize: 24, fontWeight: FontWeight.w400)),
                ),
              ),
            ],
          ),
        ),
      );
    });
  }
}

/// v0.1.29+50: hold-last-value wrappers for the Power/Regen and
/// Consumption cards. Live driving feedback: the owner reports that
/// under heavy throttle the readout drops to '—' and can stay there
/// for stretches — sometimes a minute. Root cause is upstream
/// (BLE/UDS polling cycle under load — 790-chain stalls, 2-second
/// stale-gate on the pack-current getter rejecting values that
/// arrive late), and that's a separate investigation. This patch
/// is the *visible* fix: when the live value is briefly null but we
/// have a recent reading, keep showing it for up to HOLD_WINDOW
/// with reduced opacity (stale=true → Opacity 0.5) so the driver
/// doesn't watch the card flicker.
///
/// The hold window deliberately stops at 8 seconds. Beyond that the
/// value becomes a lie — at typical city-driving acceleration the
/// power changes too fast for 15-30s-old numbers to be useful, and
/// honest '—' is better than confidently-wrong. The opacity cue
/// signals "this is yesterday's news" without erasing continuity.
///
/// Internal state expires via a one-shot Timer rather than polling:
/// on each absorbed live value the timer is reset to HOLD_WINDOW, and
/// when it fires we setState({}) so the next build sees showHeld=false.
/// Cancels in dispose.
///
/// What this does NOT do:
///  * doesn't touch connection.dart, the stale-gate, or any UDS
///    polling logic (protected layer)
///  * doesn't reach back into history or trips
///  * doesn't persist the held value across screen rebuilds — if you
///    navigate away and back, the hold-state resets

class _PowerCard extends StatefulWidget {
  final double? powerKw;
  final int? flowDir;
  const _PowerCard({required this.powerKw, required this.flowDir});

  @override
  State<_PowerCard> createState() => _PowerCardState();
}

class _PowerCardState extends State<_PowerCard> {
  static const _holdWindow = Duration(seconds: 8);
  double? _heldPower;
  int? _heldFlowDir;
  DateTime? _heldAt;
  Timer? _expiry;

  @override
  void initState() {
    super.initState();
    _absorbLive();
  }

  @override
  void didUpdateWidget(_PowerCard old) {
    super.didUpdateWidget(old);
    _absorbLive();
  }

  void _absorbLive() {
    if (widget.powerKw != null) {
      _heldPower = widget.powerKw;
      _heldFlowDir = widget.flowDir;
      _heldAt = DateTime.now();
      _expiry?.cancel();
      _expiry = Timer(_holdWindow, () {
        // When the hold expires, force a rebuild so showHeld evaluates
        // to false and the card falls back to '—'. Guard with mounted
        // — the widget can be disposed mid-window if the user
        // navigates away.
        if (mounted) setState(() {});
      });
    }
  }

  @override
  void dispose() {
    _expiry?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final live = widget.powerKw;
    final liveDir = widget.flowDir;
    final age = _heldAt == null ? null : DateTime.now().difference(_heldAt!);
    final showHeld = live == null &&
        _heldPower != null &&
        age != null &&
        age <= _holdWindow;

    final shownPower = live ?? (showHeld ? _heldPower : null);
    final shownDir = live != null ? liveDir : (showHeld ? _heldFlowDir : null);

    return _MetricCard(
      icon: shownDir == -1 ? Icons.battery_charging_full : Icons.bolt,
      color: _flowColor(shownDir),
      label: shownDir == -1 ? 'Regen' : 'Power',
      value: shownPower != null
          ? '${shownPower.abs().toStringAsFixed(1)} kW'
          : '—',
      stale: showHeld,
    );
  }
}

class _ConsumptionCard extends StatefulWidget {
  final double? consWhKm;
  const _ConsumptionCard({required this.consWhKm});

  @override
  State<_ConsumptionCard> createState() => _ConsumptionCardState();
}

class _ConsumptionCardState extends State<_ConsumptionCard> {
  static const _holdWindow = Duration(seconds: 8);
  double? _heldCons;
  DateTime? _heldAt;
  Timer? _expiry;

  @override
  void initState() {
    super.initState();
    _absorbLive();
  }

  @override
  void didUpdateWidget(_ConsumptionCard old) {
    super.didUpdateWidget(old);
    _absorbLive();
  }

  void _absorbLive() {
    if (widget.consWhKm != null) {
      _heldCons = widget.consWhKm;
      _heldAt = DateTime.now();
      _expiry?.cancel();
      _expiry = Timer(_holdWindow, () {
        if (mounted) setState(() {});
      });
    }
  }

  @override
  void dispose() {
    _expiry?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final live = widget.consWhKm;
    final age = _heldAt == null ? null : DateTime.now().difference(_heldAt!);
    final showHeld = live == null &&
        _heldCons != null &&
        age != null &&
        age <= _holdWindow;

    final shown = live ?? (showHeld ? _heldCons : null);

    return _MetricCard(
      icon: Icons.eco,
      color: (shown != null && shown < 0) ? Colors.green : Colors.tealAccent,
      label: S.of('dash.consumption_s'),
      value: shown != null ? '${shown.abs().toStringAsFixed(0)} Wh/km' : '—',
      stale: showHeld,
    );
  }
}

/// v5: SOC-aware cell balance с smoothed spread
class _CellsSummaryCard extends StatelessWidget {
  final List<int> cells;
  final double? cellMin;
  final double? cellMax;
  final double? soc;
  final int? smoothedSpread;
  const _CellsSummaryCard({
    required this.cells,
    this.cellMin,
    this.cellMax,
    this.soc,
    this.smoothedSpread,
  });

  /// v5: SOC-aware pороги для оценки балансировки.
  /// LFP имеет очень плоскую кривую SOC-V в среднем диапазоне и резкую
  /// на верхушке — поэтому пороги должны зависеть от уровня заряда.
  ({String label, Color color}) _balanceQuality(int spread, double socPct) {
    int excellent, good, fair;
    if (socPct >= 90) {
      // На верхушке spread всегда выше из-за крутого LFP knee
      excellent = 50; good = 100; fair = 150;
    } else if (socPct < 30) {
      excellent = 10; good = 20; fair = 40;
    } else {
      excellent = 20; good = 40; fair = 80;
    }
    if (spread <= excellent) {
      return (label: S.of('dash.excellent_cap'), color: Colors.green);
    }
    if (spread <= good) {
      return (label: S.of('dash.good_cap'), color: Colors.lightGreen);
    }
    if (spread <= fair) {
      return (label: S.of('dash.fair_cap'), color: Colors.orange);
    }
    return (label: S.of('dash.poor_cap'), color: Colors.red);
  }

  @override
  Widget build(BuildContext context) {
    if (cells.isEmpty) {
      return Card(
          child: ListTile(
        leading: const Icon(Icons.battery_3_bar),
        title: Text(S.of('dash.cells_title')),
        subtitle: Text(S.of('common.loading')),
      ));
    }
    final lo = cells.reduce((a, b) => a < b ? a : b);
    final hi = cells.reduce((a, b) => a > b ? a : b);
    final avg = cells.reduce((a, b) => a + b) / cells.length;
    // v5: показываем smoothed spread если есть, иначе instant
    final spreadDisplay = smoothedSpread ?? (hi - lo);
    final quality = _balanceQuality(spreadDisplay, soc ?? 50);

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Text(S.of('dash.cells_balance'),
                    style: const TextStyle(
                        fontSize: 11, letterSpacing: 1.5, color: Colors.grey)),
                const Spacer(),
                Text(quality.label,
                    style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: quality.color)),
              ],
            ),
            const SizedBox(height: 12),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                _MiniStat('Min', '$lo mV'),
                _MiniStat('Avg', '${avg.toInt()} mV'),
                _MiniStat('Max', '$hi mV'),
                _MiniStat('Δ', '$spreadDisplay mV', color: quality.color),
              ],
            ),
            const SizedBox(height: 12),
            SizedBox(height: 60, child: _CellsBars(cells: cells, lo: lo, hi: hi)),
          ],
        ),
      ),
    );
  }
}

class _CellsBars extends StatelessWidget {
  final List<int> cells;
  final int lo;
  final int hi;
  const _CellsBars({required this.cells, required this.lo, required this.hi});

  @override
  Widget build(BuildContext context) {
    final spread = (hi - lo).clamp(1, 99999);
    return Row(
      children: cells.map((v) {
        final ratio = (v - lo) / spread;
        return Expanded(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 1),
            child: FractionallySizedBox(
              alignment: Alignment.bottomCenter,
              heightFactor: 0.3 + 0.7 * ratio,
              child: Container(
                decoration: BoxDecoration(
                  color: Color.lerp(Colors.blue.shade700, Colors.lightBlue.shade300, ratio),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
          ),
        );
      }).toList(),
    );
  }
}

class _MiniStat extends StatelessWidget {
  final String label;
  final String value;
  final Color? color;
  const _MiniStat(this.label, this.value, {this.color});

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Text(label, style: const TextStyle(fontSize: 11, color: Colors.grey)),
        Text(value, style: TextStyle(fontSize: 16, fontWeight: FontWeight.w500, color: color)),
      ],
    );
  }
}
