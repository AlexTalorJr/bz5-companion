import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../services/connection.dart';

class DashboardScreen extends StatelessWidget {
  const DashboardScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final svc = context.watch<ConnectionService>();
    final connected = svc.status == ConnectionStatus.connected;

    return Scaffold(
      appBar: AppBar(
        title: const Text('BZ5 Companion'),
        actions: [
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
      body: !connected ? const _NotConnected() : _Connected(svc: svc),
    );
  }
}

class _NotConnected extends StatelessWidget {
  const _NotConnected();
  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.bluetooth_disabled, size: 80, color: Colors.grey),
            const SizedBox(height: 24),
            Text('Не подключен', style: Theme.of(context).textTheme.headlineSmall),
            const SizedBox(height: 12),
            const Text('Settings → Найти адаптер', textAlign: TextAlign.center),
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
    final soc = svc.readNumeric('790', '0005');
    final soh = svc.readNumeric('790', '0029');
    final tempRaw = svc.readNumeric('790', '002F');
    final cellMin = svc.readNumeric('790', '002B');
    final cellMax = svc.readNumeric('790', '002D');
    final odo = svc.readNumeric('791', '0026');
    final gear = svc.readNumeric('791', '0009');
    final cells = svc.liveCells;
    final isCharging = svc.isCharging;
    final rangeKm = svc.rangeEstimateKm;
    final tripEnergy = svc.tripEnergyKwh;
    final cycles = svc.cycleCount;
    // v0.1.29+2: primary live pack V = sum-of-cells avg × N (BMS cell count).
    // Synchronised with wide dashboard's hero panel. hvBusV and platform
    // nominal kept as fallbacks only — both proven unreliable under load
    // (DC 2026-05-22: hvBus showed -83V offset vs cells; AC 2026-05-23:
    // hvBus showed 405.5V while cells×136 = 458.9V → -53V offset).
    // See connection.dart packVoltageFromCells for full rationale.
    final packFromCells = svc.packVoltageFromCells;
    final packV = svc.packVoltageV;       // platform constant ~450V (fallback only)
    final hvBus = svc.hvBusV;              // HV bus (live but lies under charge)
    final parkingEngaged = svc.parkingPawlEngaged;
    final chargedSession = svc.chargedThisSessionKwh;
    // v0.1.22: live signals from PDU (740) added to UI.
    final vehicleSpeed = svc.vehicleSpeedKmh;       // 740/0x0008 / 14.09
    final pduTemp1 = svc.readNumeric('740', '0010'); // PDU heatsink 1
    final pduTemp2 = svc.readNumeric('740', '0011'); // PDU heatsink 2

    // v0.1.29: detect "tall portrait" head units (BZ3 in particular —
    // 1080×1920 px, 172 PPI → devicePixelRatio ≈ 1.075 → logical
    // ~1005 × ~1786 dp). On these we get massive vertical headroom
    // that we previously left blank, and want to inject a driver-
    // mini section under the metrics grid.
    //
    // Thresholds:
    //   isTall: height > 1400 dp covers BZ3 (~1786) but never fires
    //           on phones (typically 700-1000 dp) or BZ5 head unit in
    //           landscape (~720 dp). Safe one-way enrichment.
    //   isWideEnough: width > 700 dp lets us fit 3 metric columns
    //           comfortably. BZ3 (~1005 dp) yes; phones (~412 dp) no.
    //
    // When both true we switch the metric grid to 3 columns and
    // append a driver-mini section (speed/power/peak) below it.
    // When false the layout is byte-identical to the pre-0.1.29
    // dashboard — phones see no change.
    final mq = MediaQuery.of(context);
    final isTall = mq.size.height > 1400;
    final isWideEnough = mq.size.width > 700;
    final useTallLayout = isTall && isWideEnough;
    final gridCols = useTallLayout ? 3 : 2;

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        _SocCard(soc: soc, socPrecise: svc.socPrecisePct, rangeKm: rangeKm),
        const SizedBox(height: 12),
        if (isCharging) _ChargingBanner(svc: svc, chargedSession: chargedSession),
        if (isCharging) const SizedBox(height: 12),
        _GridCards(
          crossAxisCount: gridCols,
          children: [
            _MetricCard(
              icon: Icons.favorite,
              color: Colors.green,
              label: 'SOH',
              value: soh != null ? '${soh.toInt()}%' : '—',
            ),
            _MetricCard(
              icon: Icons.thermostat,
              color: Colors.orange,
              label: 'Battery',
              // Decoder применяет offset −40, не вычитаем повторно.
              value: tempRaw != null ? '${tempRaw.toInt()}°C' : '—',
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
              label: 'Odometer',
              value: odo != null ? '${odo.toStringAsFixed(1)} km' : '—',
            ),
            _MetricCard(
              icon: Icons.refresh,
              color: Colors.purpleAccent,
              label: 'Cycles',
              value: cycles != null ? '$cycles' : '—',
            ),
            _MetricCard(
              icon: Icons.directions_car,
              color: _gearColor(gear, parkingEngaged, isCharging),
              label: 'Gear',
              // v5: правильный mapping 1=P, 2=R, 3=N, 4=D
              value: _gearStr(gear),
            ),
            // v0.1.22: vehicle speed from 740/0x0008 (verified 2026-05-19).
            // Hidden at standstill — a permanent "0 km/h" is noise. Toyota
            // speedos read ~4-7 % higher than reality by law; expect this
            // value to read slightly lower than your speedometer.
            if (vehicleSpeed != null && vehicleSpeed > 0.5)
              _MetricCard(
                icon: Icons.speed,
                color: Colors.cyanAccent,
                label: 'Speed',
                value: '${vehicleSpeed.toStringAsFixed(0)} km/h',
              ),
            // v0.1.22: PDU heatsink temps (live, 740/0x0010 + 0x0011).
            // Yesterday's hottest values were ~58°C after spirited
            // driving; idle baseline 30-35°C.
            if (pduTemp1 != null)
              _MetricCard(
                icon: Icons.device_thermostat,
                color: _pduTempColor(pduTemp1),
                label: 'PDU T1',
                value: '${pduTemp1.toInt()}°C',
              ),
            if (pduTemp2 != null)
              _MetricCard(
                icon: Icons.device_thermostat,
                color: _pduTempColor(pduTemp2),
                label: 'PDU T2',
                value: '${pduTemp2.toInt()}°C',
              ),
          ],
        ),
        // v0.1.29: tall-only driver mini-section. Shows the live driving
        // figures that the wide head-unit Driver tab gets, condensed into
        // a single card. Hidden on phones (no height for it) and on
        // landscape head units (which have a dedicated Driver tab).
        if (useTallLayout) ...[
          const SizedBox(height: 16),
          _TallDriverSection(
            vehicleSpeed: vehicleSpeed,
            isCharging: isCharging,
            chargingPower: svc.chargingPowerKw,
            tripEnergy: tripEnergy,
            chargedSession: chargedSession,
            tripPeakSpeed: svc.tripPeakSpeedKmh,
            tripDistance: svc.tripDistanceKm,
            tripAvgConsumption: svc.tripAvgConsumptionKwh100km,
          ),
        ],
        const SizedBox(height: 12),
        // v5: Parking pawl indicator (мини-строка под grid)
        if (parkingEngaged != null)
          _ParkingPawlRow(engaged: parkingEngaged),
        if (parkingEngaged != null) const SizedBox(height: 12),
        if (svc.currentTripId != null && tripEnergy != null)
          _TripCard(svc: svc),
        const SizedBox(height: 12),
        _CellsSummaryCard(
          cells: cells,
          cellMin: cellMin,
          cellMax: cellMax,
          soc: soc,
          smoothedSpread: svc.smoothedCellSpread,
        ),
        const SizedBox(height: 16),
        _PhysicsModelCard(),
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
              engaged ? 'Parking pawl engaged' : 'Parking pawl released',
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
            const Text('STATE OF CHARGE',
                style: TextStyle(fontSize: 12, letterSpacing: 1.5, color: Colors.grey)),
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
                        const Text('Range', style: TextStyle(fontSize: 11, color: Colors.grey)),
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
                      const Text('CHARGING',
                          style: TextStyle(letterSpacing: 1.5, color: Colors.amber)),
                      Text(power > 0.1 ? '${power.toStringAsFixed(1)} kW' : 'Connected',
                          style: const TextStyle(fontSize: 24, fontWeight: FontWeight.w500)),
                    ],
                  ),
                ),
                if (etaHours != null)
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      const Text('ETA to 100%',
                          style: TextStyle(fontSize: 11, color: Colors.grey)),
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
                  const Text('This session: ',
                      style: TextStyle(fontSize: 13, color: Colors.grey)),
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
                  Text('Trip #${svc.currentTripId} · LIVE',
                      style: const TextStyle(letterSpacing: 1.0)),
                  if (tripEnergy > 0)
                    Text('${tripEnergy.toStringAsFixed(2)} kWh used',
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
        final cellsText = cellCount != null ? '$cellCount cells' : '136 cells';
        final modText = moduleCount != null
            ? '$moduleCount modules' : '10 modules';

        return Card(
          color: Colors.grey.shade900,
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: const [
                    Icon(Icons.science_outlined, size: 14, color: Colors.grey),
                    SizedBox(width: 4),
                    Text('CALIBRATION',
                        style: TextStyle(fontSize: 11, letterSpacing: 1.0, color: Colors.grey)),
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
                    '• Live extremes: cell #$minIdx = lowest, '
                    'cell #$maxIdx = highest (of $cellsText)',
                    style: const TextStyle(fontSize: 11, color: Colors.grey, height: 1.4),
                  ),
                ],
              ],
            ),
          ),
        );
      },
    );
  }
}

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
      // 3-column layout uses narrower cards, so we slightly tighten
      // the aspect ratio to keep them readable; 2-col stays the
      // familiar 1.6.
      childAspectRatio: crossAxisCount == 3 ? 1.3 : 1.6,
      children: children,
    );
  }
}

class _MetricCard extends StatelessWidget {
  final IconData icon;
  final Color color;
  final String label;
  final String value;
  const _MetricCard({
    required this.icon, required this.color, required this.label, required this.value,
  });

  @override
  Widget build(BuildContext context) {
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
                    style: const TextStyle(fontSize: 10, letterSpacing: 0.5, color: Colors.grey),
                    overflow: TextOverflow.ellipsis),
              ),
            ]),
            const Spacer(),
            FittedBox(
              fit: BoxFit.scaleDown,
              alignment: Alignment.centerLeft,
              child: Text(value, style: const TextStyle(fontSize: 24, fontWeight: FontWeight.w400)),
            ),
          ],
        ),
      ),
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
    if (spread <= excellent) return (label: 'Excellent', color: Colors.green);
    if (spread <= good) return (label: 'Good', color: Colors.lightGreen);
    if (spread <= fair) return (label: 'Fair', color: Colors.orange);
    return (label: 'Poor', color: Colors.red);
  }

  @override
  Widget build(BuildContext context) {
    if (cells.isEmpty) {
      return const Card(child: ListTile(
        leading: Icon(Icons.battery_3_bar),
        title: Text('Cells'),
        subtitle: Text('Загрузка...'),
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
                const Text('CELLS BALANCE',
                    style: TextStyle(fontSize: 11, letterSpacing: 1.5, color: Colors.grey)),
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

/// v0.1.29: tall-portrait driver mini-section. Shows the most
/// important live driving figures in one card so users on tall
/// head-unit screens (BZ3 in particular, where the screen is
/// effectively a portrait tablet ~1005×1786 dp) don't see acres
/// of empty space below the metrics grid.
///
/// Layout:
///   Row 1 (large): SPEED (km/h, only when moving) +
///                  POWER (kW, charging or driving — context-sensitive)
///   Row 2 (small): TRIP DISTANCE | TRIP ENERGY | AVG kWh/100km | PEAK SPEED
///
/// All values are nullable-safe. Hidden gracefully when the BMS or
/// PDU hasn't reported the underlying DID yet — shows "—".
class _TallDriverSection extends StatelessWidget {
  final double? vehicleSpeed;
  final bool isCharging;
  final double chargingPower;
  final double? tripEnergy;
  final double? chargedSession;
  final double? tripPeakSpeed;
  final double? tripDistance;
  final double? tripAvgConsumption;

  const _TallDriverSection({
    required this.vehicleSpeed,
    required this.isCharging,
    required this.chargingPower,
    required this.tripEnergy,
    required this.chargedSession,
    required this.tripPeakSpeed,
    required this.tripDistance,
    required this.tripAvgConsumption,
  });

  @override
  Widget build(BuildContext context) {
    // Context-sensitive primary power figure:
    //   * charging session → show charging power (positive kW into pack)
    //   * driving → ConnectionService doesn't currently expose live drive
    //     power as a public getter (the underlying DID isn't identified
    //     yet — see v0.1.27+1 removal of peak power/regen). We keep
    //     "POWER" hidden in this case, rather than show "—" which would
    //     just be noise on a primary metric.
    final showChargingPower = isCharging && chargingPower > 0.1;
    final speedShown = vehicleSpeed != null && vehicleSpeed! > 0.5;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: const [
              Icon(Icons.timeline, color: Colors.cyanAccent, size: 18),
              SizedBox(width: 8),
              Text('THIS TRIP',
                  style: TextStyle(
                      fontSize: 12, letterSpacing: 1.5, color: Colors.grey)),
            ]),
            const SizedBox(height: 14),
            // Row 1: SPEED + POWER (each takes half width if both shown,
            // full width if one is shown, hidden if neither).
            if (speedShown || showChargingPower)
              Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  if (speedShown)
                    Expanded(
                      child: _BigDriverCell(
                        label: 'SPEED',
                        value: vehicleSpeed!.toStringAsFixed(0),
                        unit: 'km/h',
                        color: Colors.cyanAccent,
                      ),
                    ),
                  if (showChargingPower)
                    Expanded(
                      child: _BigDriverCell(
                        label: isCharging ? 'CHARGING' : 'POWER',
                        value: chargingPower.toStringAsFixed(1),
                        unit: 'kW',
                        color: Colors.amberAccent,
                      ),
                    ),
                ],
              ),
            if (speedShown || showChargingPower) const SizedBox(height: 16),
            // Row 2: 4 mini stats. Uses MainAxisAlignment.spaceBetween so
            // they distribute evenly regardless of how many are shown.
            // Hidden values shown as "—" — this row is informational,
            // showing dashes here doesn't hurt readability the way
            // it would on a primary metric.
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                _MiniStat(
                  'DIST',
                  tripDistance != null
                      ? '${tripDistance!.toStringAsFixed(1)} km'
                      : '—',
                ),
                _MiniStat(
                  'ENERGY',
                  tripEnergy != null
                      ? '${tripEnergy!.toStringAsFixed(2)} kWh'
                      : (chargedSession != null && isCharging
                          ? '+${chargedSession!.toStringAsFixed(2)} kWh'
                          : '—'),
                ),
                _MiniStat(
                  'AVG',
                  tripAvgConsumption != null
                      ? '${tripAvgConsumption!.toStringAsFixed(1)}'
                      : '—',
                  color: tripAvgConsumption != null
                      ? Colors.white
                      : Colors.grey.shade600,
                ),
                _MiniStat(
                  'PEAK',
                  tripPeakSpeed != null
                      ? '${tripPeakSpeed!.toStringAsFixed(0)} km/h'
                      : '—',
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// Large value+unit cell used in the tall driver section's row 1.
/// Pattern mirrors the wide Driver-tab styling (driver_view_wide.dart):
/// big number, small unit, label above in muted color.
class _BigDriverCell extends StatelessWidget {
  final String label;
  final String value;
  final String unit;
  final Color color;
  const _BigDriverCell({
    required this.label,
    required this.value,
    required this.unit,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label,
            style: const TextStyle(
                fontSize: 10, letterSpacing: 1.5, color: Colors.grey)),
        const SizedBox(height: 4),
        Row(
          crossAxisAlignment: CrossAxisAlignment.baseline,
          textBaseline: TextBaseline.alphabetic,
          children: [
            Text(value,
                style: TextStyle(
                    fontSize: 38, fontWeight: FontWeight.w300, color: color, height: 1.0)),
            const SizedBox(width: 6),
            Text(unit,
                style: const TextStyle(fontSize: 12, color: Colors.grey)),
          ],
        ),
      ],
    );
  }
}
