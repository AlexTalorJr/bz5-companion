import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../services/connection.dart';

/// v0.1.4: Head-unit Dashboard.
///
/// Single-page passive monitor for at-a-glance reading while driving.
/// Layout: 3 columns, no scroll, all critical metrics visible.
///
/// Column 1 (priority — driver glances here first):
///   - SOC + range (large)
///   - PACK V (filtered + instant)
///   - Charging banner placeholder (only visible when isCharging)
///
/// Column 2 (status):
///   - 2x2 grid of small metrics (SOH, Battery temp, Odometer, Cycles)
///   - Large GEAR card with parking pawl indicator
///
/// Column 3 (battery health):
///   - Pack extremes (across 136 cells)
///   - Per-module list (10 rows: M1..M10) with min..max mV and temp
///
/// No interaction except pause/play polling in app bar — read-only by design
/// per v0.1.4 product decision.
class DashboardWideScreen extends StatelessWidget {
  const DashboardWideScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final svc = context.watch<ConnectionService>();
    final connected = svc.status == ConnectionStatus.connected;

    return Scaffold(
      appBar: AppBar(
        title: const Text('BZ5 Companion · Dashboard'),
        actions: [
          IconButton(
            icon: Icon(svc.isPolling ? Icons.pause_circle : Icons.play_circle),
            iconSize: 32,
            tooltip: svc.isPolling ? 'Pause polling' : 'Start polling',
            onPressed: !connected
                ? null
                : () {
                    if (svc.isPolling) {
                      svc.stopPolling();
                    } else {
                      svc.startPolling();
                    }
                  },
          ),
          const SizedBox(width: 12),
        ],
      ),
      body: !connected
          ? const _NotConnectedHero()
          : Padding(
              padding: const EdgeInsets.all(16),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  // Column 1: SOC, PACK V, charging
                  Expanded(flex: 14, child: _LeftColumn(svc: svc)),
                  const SizedBox(width: 12),
                  // Column 2: status grid + gear
                  Expanded(flex: 10, child: _MiddleColumn(svc: svc)),
                  const SizedBox(width: 12),
                  // Column 3: pack extremes + modules
                  Expanded(flex: 11, child: _RightColumn(svc: svc)),
                ],
              ),
            ),
    );
  }
}

// ─────────────────────────── Empty / disconnected ──────────────────────────

class _NotConnectedHero extends StatelessWidget {
  const _NotConnectedHero();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Icon(Icons.bluetooth_disabled, size: 96, color: Colors.grey),
          const SizedBox(height: 24),
          Text('Адаптер не подключен',
              style: Theme.of(context).textTheme.headlineMedium),
          const SizedBox(height: 12),
          Text('Перейдите в Settings и нажмите «Найти адаптер»',
              style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                    color: Colors.grey,
                  )),
        ],
      ),
    );
  }
}

// ───────────────────────────── Left column ─────────────────────────────────

class _LeftColumn extends StatelessWidget {
  final ConnectionService svc;
  const _LeftColumn({required this.svc});

  @override
  Widget build(BuildContext context) {
    final soc = svc.readNumeric('790', '0005');
    final rangeKm = svc.rangeEstimateKm;
    final packV = svc.packVoltageV;
    final packVInst = svc.packVoltageInstantV;
    final isCharging = svc.isCharging;
    final chargingPower = svc.chargingPowerKw;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(flex: 5, child: _SocHero(soc: soc, rangeKm: rangeKm)),
        const SizedBox(height: 12),
        Expanded(
          flex: 3,
          child: _PackVoltageHero(
            filteredV: packV,
            instantV: packVInst,
          ),
        ),
        const SizedBox(height: 12),
        Expanded(
          flex: 2,
          child: _ChargingPanel(
            isCharging: isCharging,
            powerKw: chargingPower,
            chargedSession: svc.chargedThisSessionKwh,
          ),
        ),
      ],
    );
  }
}

class _SocHero extends StatelessWidget {
  final double? soc;
  final double? rangeKm;
  const _SocHero({this.soc, this.rangeKm});

  @override
  Widget build(BuildContext context) {
    final pct = soc ?? 0;
    final color = pct < 20
        ? Colors.red
        : pct < 50
            ? Colors.orange
            : Colors.green;

    return Card(
      elevation: 2,
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('STATE OF CHARGE',
                style: TextStyle(
                    fontSize: 13, letterSpacing: 1.5, color: Colors.grey)),
            const SizedBox(height: 8),
            Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text(
                  soc != null ? '${soc!.toInt()}' : '—',
                  style: TextStyle(
                      fontSize: 96,
                      fontWeight: FontWeight.w300,
                      color: color,
                      height: 1.0),
                ),
                const SizedBox(width: 6),
                const Padding(
                  padding: EdgeInsets.only(bottom: 18),
                  child:
                      Text('%', style: TextStyle(fontSize: 28, color: Colors.grey)),
                ),
                const Spacer(),
                if (rangeKm != null)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 18),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        const Text('RANGE',
                            style:
                                TextStyle(fontSize: 12, color: Colors.grey)),
                        Text('~${rangeKm!.toInt()} km',
                            style: const TextStyle(
                                fontSize: 32, fontWeight: FontWeight.w300)),
                      ],
                    ),
                  ),
              ],
            ),
            const Spacer(),
            ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: LinearProgressIndicator(
                value: pct / 100,
                minHeight: 10,
                backgroundColor: Colors.grey.shade800,
                valueColor: AlwaysStoppedAnimation(color),
              ),
            ),
            const SizedBox(height: 10),
            const Text('@ 14.4 kWh/100km · 65.28 kWh capacity',
                style: TextStyle(fontSize: 12, color: Colors.grey)),
          ],
        ),
      ),
    );
  }
}

class _PackVoltageHero extends StatelessWidget {
  final double? filteredV;
  final double? instantV;
  const _PackVoltageHero({this.filteredV, this.instantV});

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Row(
              children: [
                Icon(Icons.bolt, color: Colors.yellowAccent, size: 22),
                SizedBox(width: 6),
                Text('PACK VOLTAGE',
                    style: TextStyle(
                        fontSize: 12,
                        letterSpacing: 1.5,
                        color: Colors.grey)),
              ],
            ),
            const SizedBox(height: 8),
            Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text(
                  filteredV != null
                      ? '${filteredV!.toStringAsFixed(1)} V'
                      : '—',
                  style: const TextStyle(
                      fontSize: 48,
                      fontWeight: FontWeight.w300,
                      color: Colors.yellowAccent,
                      height: 1.0),
                ),
                const Spacer(),
                if (instantV != null)
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      const Text('INSTANT',
                          style: TextStyle(
                              fontSize: 11, color: Colors.grey)),
                      Text('${instantV!.toStringAsFixed(1)} V',
                          style: const TextStyle(
                              fontSize: 18, fontWeight: FontWeight.w300)),
                    ],
                  ),
              ],
            ),
            const Spacer(),
            const Text('filtered · 740/0x0022 × 0.025',
                style: TextStyle(fontSize: 11, color: Colors.grey)),
          ],
        ),
      ),
    );
  }
}

class _ChargingPanel extends StatelessWidget {
  final bool isCharging;
  final double powerKw;
  final double? chargedSession;
  const _ChargingPanel({
    required this.isCharging,
    required this.powerKw,
    this.chargedSession,
  });

  @override
  Widget build(BuildContext context) {
    if (!isCharging) {
      return Card(
        color: Colors.grey.shade900,
        child: const Padding(
          padding: EdgeInsets.all(14),
          child: Row(
            children: [
              Icon(Icons.bolt_outlined, color: Colors.grey, size: 28),
              SizedBox(width: 10),
              Expanded(
                child: Text('Not charging',
                    style: TextStyle(
                        color: Colors.grey,
                        letterSpacing: 1.0,
                        fontSize: 13)),
              ),
            ],
          ),
        ),
      );
    }

    return Card(
      color: Colors.indigo.shade900,
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Row(
          children: [
            const Icon(Icons.bolt, color: Colors.amber, size: 32),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Text('CHARGING',
                      style: TextStyle(
                          letterSpacing: 1.5,
                          color: Colors.amber,
                          fontSize: 12)),
                  Text(
                    powerKw > 0.1
                        ? '${powerKw.toStringAsFixed(1)} kW'
                        : 'Connected',
                    style: const TextStyle(
                        fontSize: 24, fontWeight: FontWeight.w400),
                  ),
                ],
              ),
            ),
            if (chargedSession != null && chargedSession! > 0.05)
              Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  const Text('THIS SESSION',
                      style: TextStyle(
                          fontSize: 11, color: Colors.lightBlueAccent)),
                  Text('${chargedSession!.toStringAsFixed(2)} kWh',
                      style: const TextStyle(
                          fontSize: 18, fontWeight: FontWeight.w400)),
                ],
              ),
          ],
        ),
      ),
    );
  }
}

// ──────────────────────────── Middle column ────────────────────────────────

class _MiddleColumn extends StatelessWidget {
  final ConnectionService svc;
  const _MiddleColumn({required this.svc});

  @override
  Widget build(BuildContext context) {
    final soh = svc.readNumeric('790', '0029');
    final tempRaw = svc.readNumeric('790', '002F');
    final odo = svc.readNumeric('791', '0026');
    final cycles = svc.cycleCount;
    final gear = svc.readNumeric('791', '0009');
    final parkingEngaged = svc.parkingPawlEngaged;
    final isCharging = svc.isCharging;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // v0.1.4 hotfix: replaced GridView.count(childAspectRatio:...) with
        // manual Row/Column nesting because GridView with a fixed aspect ratio
        // inside Expanded leaves vertical empty space when the available height
        // is larger than (width / aspect) * rows. With Expanded+flex on rows,
        // cells grow to fill exactly the available space.
        Expanded(
          flex: 5,
          child: Column(
            children: [
              Expanded(
                child: Row(
                  children: [
                    Expanded(
                      child: _SmallMetricCard(
                        icon: Icons.favorite,
                        color: Colors.green,
                        label: 'SOH',
                        value: soh != null ? '${soh.toInt()}%' : '—',
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: _SmallMetricCard(
                        icon: Icons.thermostat,
                        color: Colors.orange,
                        label: 'BATTERY',
                        value:
                            tempRaw != null ? '${tempRaw.toInt()}°C' : '—',
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 12),
              Expanded(
                child: Row(
                  children: [
                    Expanded(
                      child: _SmallMetricCard(
                        icon: Icons.speed,
                        color: Colors.blue,
                        label: 'ODOMETER',
                        value: odo != null ? odo.toStringAsFixed(1) : '—',
                        unit: 'km',
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: _SmallMetricCard(
                        icon: Icons.refresh,
                        color: Colors.purpleAccent,
                        label: 'CYCLES',
                        value: cycles != null ? '$cycles' : '—',
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 12),
        Expanded(
          flex: 3,
          child: _GearHero(
            gear: gear,
            parkingEngaged: parkingEngaged,
            isCharging: isCharging,
          ),
        ),
      ],
    );
  }
}

class _SmallMetricCard extends StatelessWidget {
  final IconData icon;
  final Color color;
  final String label;
  final String value;
  final String? unit;
  const _SmallMetricCard({
    required this.icon,
    required this.color,
    required this.label,
    required this.value,
    this.unit,
  });

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(icon, color: color, size: 20),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(label,
                      style: const TextStyle(
                          fontSize: 11,
                          letterSpacing: 0.8,
                          color: Colors.grey),
                      overflow: TextOverflow.ellipsis),
                ),
              ],
            ),
            const Spacer(),
            FittedBox(
              fit: BoxFit.scaleDown,
              alignment: Alignment.centerLeft,
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Text(value,
                      style: const TextStyle(
                          fontSize: 32, fontWeight: FontWeight.w300)),
                  if (unit != null) ...[
                    const SizedBox(width: 4),
                    Padding(
                      padding: const EdgeInsets.only(bottom: 5),
                      child: Text(unit!,
                          style: const TextStyle(
                              fontSize: 13, color: Colors.grey)),
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _GearHero extends StatelessWidget {
  final double? gear;
  final bool? parkingEngaged;
  final bool isCharging;
  const _GearHero({this.gear, this.parkingEngaged, required this.isCharging});

  @override
  Widget build(BuildContext context) {
    final gearStr = _gearStr(gear);
    final gearColor = _gearColor(gear, parkingEngaged, isCharging);

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          children: [
            Expanded(
              flex: 2,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('GEAR',
                      style: TextStyle(
                          fontSize: 11,
                          letterSpacing: 1.5,
                          color: Colors.grey)),
                  Expanded(
                    child: Center(
                      child: FittedBox(
                        fit: BoxFit.scaleDown,
                        child: Text(gearStr,
                            style: TextStyle(
                                fontSize: 84,
                                fontWeight: FontWeight.w300,
                                color: gearColor,
                                height: 1.0)),
                      ),
                    ),
                  ),
                ],
              ),
            ),
            Expanded(
              flex: 3,
              child: _ParkingPawlBlock(engaged: parkingEngaged),
            ),
          ],
        ),
      ),
    );
  }

  String _gearStr(double? g) {
    if (g == null) return '—';
    return switch (g.toInt()) {
      1 => 'P',
      2 => 'R',
      3 => 'N',
      4 => 'D',
      _ => '?',
    };
  }

  Color _gearColor(double? g, bool? engaged, bool isCharging) {
    if (g == null) return Colors.grey;
    if (engaged == true) return Colors.lightBlueAccent;
    if (isCharging) return Colors.amber;
    return switch (g.toInt()) {
      1 => Colors.lightBlueAccent,
      2 => Colors.redAccent,
      3 => Colors.orangeAccent,
      4 => Colors.greenAccent,
      _ => Colors.grey,
    };
  }
}

class _ParkingPawlBlock extends StatelessWidget {
  final bool? engaged;
  const _ParkingPawlBlock({this.engaged});

  @override
  Widget build(BuildContext context) {
    if (engaged == null) {
      return const SizedBox.shrink();
    }
    final eng = engaged!;
    return Container(
      decoration: BoxDecoration(
        color: eng ? Colors.green.shade900 : Colors.grey.shade800,
        borderRadius: BorderRadius.circular(8),
      ),
      padding: const EdgeInsets.all(12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(eng ? Icons.lock : Icons.lock_open,
              color: eng ? Colors.greenAccent : Colors.grey,
              size: 28),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(eng ? 'PAWL ENGAGED' : 'PAWL RELEASED',
                    style: TextStyle(
                        fontSize: 12,
                        letterSpacing: 1.0,
                        color: eng ? Colors.greenAccent : Colors.grey)),
                Text(eng ? 'parking lock active' : 'mechanical lock disengaged',
                    style: const TextStyle(fontSize: 11, color: Colors.grey)),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ───────────────────────────── Right column ────────────────────────────────

class _RightColumn extends StatelessWidget {
  final ConnectionService svc;
  const _RightColumn({required this.svc});

  @override
  Widget build(BuildContext context) {
    final modules = svc.moduleSnapshots;
    final cellCount = svc.packCellCount;
    final moduleCount = svc.packModuleCount;
    // v0.1.6: prefer new getters (read via _pollExtraDids) over readNumeric
    // (which fails because cells category is filtered out of _pollEcu).
    // Fallback to readNumeric in case future versions add proper polling.
    final minV = svc.globalMinCellMv?.toDouble()
        ?? svc.readNumeric('790', '002B');
    final maxV = svc.globalMaxCellMv?.toDouble()
        ?? svc.readNumeric('790', '002D');
    final minIdx = svc.globalMinCellIndex;
    final maxIdx = svc.globalMaxCellIndex;
    final soc = svc.readNumeric('790', '0005') ?? 50;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _PackExtremesPanel(
          minV: minV,
          maxV: maxV,
          minIdx: minIdx,
          maxIdx: maxIdx,
          cellCount: cellCount ?? 136,
          socPct: soc,
        ),
        const SizedBox(height: 12),
        Expanded(
          child: _ModulesListPanel(
            modules: modules,
            moduleCount: moduleCount ?? 10,
          ),
        ),
      ],
    );
  }
}

class _PackExtremesPanel extends StatelessWidget {
  final double? minV;
  final double? maxV;
  final int? minIdx;
  final int? maxIdx;
  final int cellCount;
  final double socPct;
  const _PackExtremesPanel({
    this.minV,
    this.maxV,
    this.minIdx,
    this.maxIdx,
    required this.cellCount,
    required this.socPct,
  });

  /// Same SOC-aware thresholds as cells.dart _PackExtremesCard and
  /// dashboard.dart _CellsSummaryCard. Keep in sync.
  ({String label, Color color}) _classifySpread(int spread, double soc) {
    int excellent, good, fair;
    if (soc >= 90) {
      excellent = 50; good = 100; fair = 150;
    } else if (soc < 30) {
      excellent = 10; good = 20; fair = 40;
    } else {
      excellent = 20; good = 40; fair = 80;
    }
    if (spread <= excellent) return (label: 'excellent', color: Colors.green);
    if (spread <= good) return (label: 'good', color: Colors.lightGreen);
    if (spread <= fair) return (label: 'fair', color: Colors.orange);
    return (label: 'check', color: Colors.red);
  }

  @override
  Widget build(BuildContext context) {
    if (minV == null || maxV == null) {
      return Card(
        color: Colors.grey.shade900,
        child: const Padding(
          padding: EdgeInsets.all(14),
          child: Text('Pack extremes: loading…',
              style: TextStyle(color: Colors.grey, fontSize: 13)),
        ),
      );
    }
    final spread = (maxV! - minV!).round();
    final quality = _classifySpread(spread, socPct);

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.battery_full,
                    color: Colors.lightBlueAccent, size: 18),
                const SizedBox(width: 6),
                Text('PACK EXTREMES (across $cellCount cells)',
                    style: const TextStyle(
                        fontSize: 11,
                        letterSpacing: 1.0,
                        color: Colors.grey)),
              ],
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                    child: _ExtremeTile(
                  label: 'MIN',
                  valueMv: minV!.toInt(),
                  cellIdx: minIdx,
                )),
                Expanded(
                    child: _ExtremeTile(
                  label: 'MAX',
                  valueMv: maxV!.toInt(),
                  cellIdx: maxIdx,
                )),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text('Δ',
                          style:
                              TextStyle(fontSize: 11, color: Colors.grey)),
                      const SizedBox(height: 2),
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.end,
                        children: [
                          Text('$spread',
                              style: TextStyle(
                                  fontSize: 24,
                                  fontWeight: FontWeight.w400,
                                  color: quality.color)),
                          const Padding(
                            padding: EdgeInsets.only(bottom: 3, left: 3),
                            child: Text('mV',
                                style: TextStyle(
                                    fontSize: 11, color: Colors.grey)),
                          ),
                        ],
                      ),
                      Text(quality.label,
                          style: TextStyle(
                              fontSize: 11,
                              color: quality.color,
                              letterSpacing: 0.3)),
                    ],
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _ExtremeTile extends StatelessWidget {
  final String label;
  final int valueMv;
  final int? cellIdx;
  const _ExtremeTile({
    required this.label,
    required this.valueMv,
    this.cellIdx,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: const TextStyle(fontSize: 11, color: Colors.grey)),
        const SizedBox(height: 2),
        Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Text('$valueMv',
                style: const TextStyle(
                    fontSize: 24, fontWeight: FontWeight.w400)),
            const Padding(
              padding: EdgeInsets.only(bottom: 3, left: 3),
              child: Text('mV',
                  style: TextStyle(fontSize: 11, color: Colors.grey)),
            ),
          ],
        ),
        Text(cellIdx != null ? 'cell #$cellIdx' : 'cell #—',
            style: const TextStyle(
                fontSize: 11, color: Colors.grey, letterSpacing: 0.3)),
      ],
    );
  }
}

class _ModulesListPanel extends StatelessWidget {
  final List<ModuleSnapshot> modules;
  final int moduleCount;
  const _ModulesListPanel({required this.modules, required this.moduleCount});

  @override
  Widget build(BuildContext context) {
    // Compute global temp range once for color normalization
    final reportedTemps = <double>[];
    for (final m in modules) {
      if (m.temp1C != null) reportedTemps.add(m.temp1C!);
      if (m.temp2C != null) reportedTemps.add(m.temp2C!);
    }
    double? tmin, tmax;
    if (reportedTemps.isNotEmpty) {
      tmin = reportedTemps.reduce((a, b) => a < b ? a : b);
      tmax = reportedTemps.reduce((a, b) => a > b ? a : b);
    }

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Text('$moduleCount MODULES · MIN..MAX mV · TEMP',
                    style: const TextStyle(
                        fontSize: 11,
                        letterSpacing: 1.0,
                        color: Colors.grey)),
              ],
            ),
            const SizedBox(height: 8),
            Expanded(
              child: ListView.builder(
                physics: const ClampingScrollPhysics(),
                itemCount: modules.length,
                itemBuilder: (context, i) {
                  return _ModuleRow(
                    module: modules[i],
                    tempMin: tmin,
                    tempMax: tmax,
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ModuleRow extends StatelessWidget {
  final ModuleSnapshot module;
  final double? tempMin;
  final double? tempMax;
  const _ModuleRow({required this.module, this.tempMin, this.tempMax});

  @override
  Widget build(BuildContext context) {
    final temp = module.avgTemp;
    final hasTemp = module.hasAnyTemp && temp != null;

    Color barColor = const Color(0xFF7AB9D4);
    if (hasTemp && tempMin != null && tempMax != null) {
      if ((tempMax! - tempMin!) > 0.5) {
        final ratio =
            ((temp - tempMin!) / (tempMax! - tempMin!)).clamp(0.0, 1.0);
        barColor = Color.lerp(
          const Color(0xFF7AB9D4),
          const Color(0xFFD4944A),
          ratio,
        )!;
      } else {
        barColor = const Color(0xFFA8A496);
      }
    }

    final cellMin = module.cellMinmV;
    final cellMax = module.cellMaxmV;

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          SizedBox(
            width: 32,
            child: Text('M${module.index}',
                style: const TextStyle(
                    fontSize: 13, color: Colors.white70)),
          ),
          Expanded(
            child: Container(
              height: 18,
              decoration: BoxDecoration(
                color: hasTemp ? barColor : Colors.transparent,
                borderRadius: BorderRadius.circular(9),
                border: hasTemp
                    ? null
                    : Border.all(color: Colors.grey.shade700, width: 1),
              ),
            ),
          ),
          const SizedBox(width: 8),
          SizedBox(
            width: 92,
            child: Text(
              (cellMin != null && cellMax != null)
                  ? '$cellMin–$cellMax'
                  : '—',
              style: const TextStyle(
                  fontSize: 12,
                  color: Colors.white70,
                  fontFeatures: [FontFeature.tabularFigures()]),
              textAlign: TextAlign.right,
            ),
          ),
          SizedBox(
            width: 56,
            child: Text(
              hasTemp
                  ? ((tempMax != null &&
                          tempMin != null &&
                          (tempMax! - tempMin!) > 0.5)
                      ? '${temp >= 0 ? '+' : ''}${temp.toStringAsFixed(1)}°'
                      : '${temp >= 0 ? '+' : ''}${temp.toStringAsFixed(0)}°')
                  // v0.1.6: 'no temp' clearer than 'no s.' — emphasises that
                  // only the temperature reading is missing for this module
                  // (cell voltages still readout normally — see column to left)
                  : 'no temp',
              style: TextStyle(
                  fontSize: 12,
                  color: hasTemp ? Colors.white70 : Colors.grey,
                  fontFeatures: const [FontFeature.tabularFigures()]),
              textAlign: TextAlign.right,
            ),
          ),
        ],
      ),
    );
  }
}
