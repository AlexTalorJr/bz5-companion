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

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        _SocCard(soc: soc, rangeKm: rangeKm),
        const SizedBox(height: 12),
        if (isCharging) _ChargingBanner(svc: svc),
        if (isCharging) const SizedBox(height: 12),
        _GridCards(
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
              value: tempRaw != null ? '${(tempRaw - 40).toInt()}°C' : '—',
            ),
            _MetricCard(
              icon: Icons.speed,
              color: Colors.blue,
              label: 'Odometer',
              value: odo != null ? '${odo.toStringAsFixed(1)} km' : '—',
            ),
            _MetricCard(
              icon: Icons.bolt,
              color: Colors.amber,
              label: 'Range',
              value: rangeKm != null ? '~${rangeKm.toInt()} km' : '—',
            ),
            _MetricCard(
              icon: Icons.electric_bolt,
              color: Colors.cyanAccent,
              label: 'Lifetime ⚡in',
              value: svc.lifetimeChargedKwh != null
                  ? '${svc.lifetimeChargedKwh!.toStringAsFixed(0)} kWh'
                  : '—',
            ),
            _MetricCard(
              icon: Icons.directions_car,
              color: Colors.lightBlueAccent,
              label: 'Gear',
              value: _gearStr(gear),
            ),
          ],
        ),
        const SizedBox(height: 12),
        if (svc.currentTripId != null && tripEnergy != null)
          _TripCard(svc: svc),
        const SizedBox(height: 12),
        _CellsSummaryCard(cells: cells, cellMin: cellMin, cellMax: cellMax),
        const SizedBox(height: 16),
        _PhysicsModelCard(svc: svc),
      ],
    );
  }

  String _gearStr(double? g) {
    if (g == null) return '—';
    return switch (g.toInt()) {
      1 => 'D', 2 => 'N', 3 => 'R', 4 => 'P', _ => '?',
    };
  }
}

class _SocCard extends StatelessWidget {
  final double? soc;
  final double? rangeKm;
  const _SocCard({this.soc, this.rangeKm});

  @override
  Widget build(BuildContext context) {
    final pct = soc ?? 0;
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
                  soc != null ? '${soc!.toInt()}' : '—',
                  style: TextStyle(fontSize: 72, fontWeight: FontWeight.w300, color: color, height: 1.0),
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
            const SizedBox(height: 8),
            const Text('@ 14.4 kWh/100km · 65.28 kWh capacity',
                style: TextStyle(fontSize: 10, color: Colors.grey)),
          ],
        ),
      ),
    );
  }
}

class _ChargingBanner extends StatelessWidget {
  final ConnectionService svc;
  const _ChargingBanner({required this.svc});

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
  final ConnectionService svc;
  const _PhysicsModelCard({required this.svc});

  @override
  Widget build(BuildContext context) {
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
            const Text(
              'Calibrated against real charging session at 2.1 kW.\n'
              '• Battery: 65.28 kWh (Toyota datasheet)\n'
              '• Charge counter (BMS 0B00): 1 unit ≈ 45.6 Wh\n'
              '• Avg consumption: 14.4 kWh/100km',
              style: TextStyle(fontSize: 11, color: Colors.grey, height: 1.5),
            ),
          ],
        ),
      ),
    );
  }
}

class _GridCards extends StatelessWidget {
  final List<Widget> children;
  const _GridCards({required this.children});

  @override
  Widget build(BuildContext context) {
    return GridView.count(
      crossAxisCount: 2,
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      mainAxisSpacing: 8,
      crossAxisSpacing: 8,
      childAspectRatio: 1.6,
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

class _CellsSummaryCard extends StatelessWidget {
  final List<int> cells;
  final double? cellMin;
  final double? cellMax;
  const _CellsSummaryCard({required this.cells, this.cellMin, this.cellMax});

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
    final spread = hi - lo;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('CELLS BALANCE',
                style: TextStyle(fontSize: 11, letterSpacing: 1.5, color: Colors.grey)),
            const SizedBox(height: 12),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                _MiniStat('Min', '$lo mV'),
                _MiniStat('Avg', '${avg.toInt()} mV'),
                _MiniStat('Max', '$hi mV'),
                _MiniStat('Δ', '$spread mV',
                    color: spread > 50 ? Colors.red : (spread > 20 ? Colors.orange : Colors.green)),
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
