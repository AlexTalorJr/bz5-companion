import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../data/database.dart';
import '../services/connection.dart';
import 'trip_detail.dart';
import 'trends.dart';

/// v0.1.9: rebuilt history screen with two tabs:
///   - Trips: list of past + active trip with rich aggregates
///   - Trends: long-term charts (SOC, temp, SOH, etc.) over time windows
///
/// Trip cards now show distance, energy, avg consumption, temp range, etc.
/// Tap a trip → full detail screen with per-sample charts.
class HistoryScreen extends StatelessWidget {
  const HistoryScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 2,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('History'),
          bottom: const TabBar(
            tabs: [
              Tab(text: 'Trips', icon: Icon(Icons.route, size: 18)),
              Tab(text: 'Trends', icon: Icon(Icons.show_chart, size: 18)),
            ],
          ),
        ),
        body: const TabBarView(
          children: [
            _TripsTab(),
            TrendsScreen(),
          ],
        ),
      ),
    );
  }
}

class _TripsTab extends StatelessWidget {
  const _TripsTab();

  @override
  Widget build(BuildContext context) {
    final svc = context.watch<ConnectionService>();
    return FutureBuilder<List<Trip>>(
      // Watching svc triggers rebuilds on connection state changes,
      // which re-runs this future — refreshing the list when trips end.
      future: svc.db.getRecentTrips(),
      builder: (context, snapshot) {
        if (!snapshot.hasData) {
          return const Center(child: CircularProgressIndicator());
        }
        final trips = snapshot.data!;
        if (trips.isEmpty) {
          return Center(
            child: Padding(
              padding: const EdgeInsets.all(32),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.route_outlined,
                      size: 64, color: Colors.grey.shade600),
                  const SizedBox(height: 16),
                  const Text('Поездок пока нет',
                      style: TextStyle(fontSize: 15)),
                  const SizedBox(height: 8),
                  Text(
                    'Подключитесь к адаптеру и поезжайте — '
                    'история начнёт заполняться автоматически.',
                    textAlign: TextAlign.center,
                    style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
                  ),
                ],
              ),
            ),
          );
        }

        // Find the active trip (endedAt == null) for live card on top.
        final active = trips.where((t) => t.endedAt == null).toList();
        final past = trips.where((t) => t.endedAt != null).toList();

        return ListView.builder(
          padding: const EdgeInsets.only(top: 8, bottom: 24),
          itemCount: active.length + past.length,
          itemBuilder: (context, i) {
            if (i < active.length) {
              return _ActiveTripCard(trip: active[i], svc: svc);
            }
            return _TripCard(trip: past[i - active.length]);
          },
        );
      },
    );
  }
}

/// Active trip card — shows live metrics from ConnectionService getters.
/// Updates with every `notifyListeners()` on svc (every poll cycle).
class _ActiveTripCard extends StatelessWidget {
  final Trip trip;
  final ConnectionService svc;
  const _ActiveTripCard({required this.trip, required this.svc});

  @override
  Widget build(BuildContext context) {
    final dateStr = DateFormat('d MMM HH:mm').format(trip.startedAt);
    final duration = svc.tripDuration ?? DateTime.now().difference(trip.startedAt);
    final dist = svc.tripDistanceKm;
    final energy = svc.tripEnergyUsedKwh;
    final cons = svc.tripAvgConsumptionKwh100km;
    final peakPwr = svc.tripPeakPowerKw;

    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      color: Colors.green.shade900.withValues(alpha: 0.25),
      shape: RoundedRectangleBorder(
        side: const BorderSide(color: Colors.greenAccent, width: 1),
        borderRadius: BorderRadius.circular(12),
      ),
      child: InkWell(
        onTap: () => Navigator.of(context).push(MaterialPageRoute(
          builder: (_) => TripDetailScreen(tripId: trip.id),
        )),
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Container(
                    width: 10, height: 10,
                    decoration: const BoxDecoration(
                      shape: BoxShape.circle,
                      color: Colors.greenAccent,
                    ),
                  ),
                  const SizedBox(width: 8),
                  const Text('ACTIVE TRIP',
                      style: TextStyle(
                          fontSize: 11,
                          letterSpacing: 1.5,
                          color: Colors.greenAccent)),
                  const Spacer(),
                  Text('#${trip.id}',
                      style: const TextStyle(
                          fontSize: 12, color: Colors.grey)),
                ],
              ),
              const SizedBox(height: 6),
              Text(dateStr,
                  style: const TextStyle(
                      fontSize: 16, fontWeight: FontWeight.w500)),
              const SizedBox(height: 12),
              Row(
                children: [
                  _MetricChip(label: 'TIME', value: _fmtDuration(duration)),
                  _MetricChip(
                      label: 'DIST',
                      value: dist != null
                          ? '${dist.toStringAsFixed(1)} km'
                          : '—'),
                  _MetricChip(
                      label: 'ENERGY',
                      value: energy != null
                          ? '${energy.toStringAsFixed(2)} kWh'
                          : '—'),
                ],
              ),
              const SizedBox(height: 6),
              Row(
                children: [
                  _MetricChip(
                      label: 'AVG',
                      value: cons != null
                          ? '${cons.toStringAsFixed(1)} kWh/100'
                          : '—'),
                  _MetricChip(
                      label: 'PEAK kW',
                      value: peakPwr != null
                          ? peakPwr.toStringAsFixed(1)
                          : '—'),
                  _MetricChip(
                      label: 'TEMP',
                      value: svc.tripMinTempC != null && svc.tripMaxTempC != null
                          ? '${svc.tripMinTempC!.toStringAsFixed(0)}–${svc.tripMaxTempC!.toStringAsFixed(0)}°'
                          : '—'),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Past trip card — shows aggregates from DB (no live updates).
class _TripCard extends StatelessWidget {
  final Trip trip;
  const _TripCard({required this.trip});

  @override
  Widget build(BuildContext context) {
    final duration =
        (trip.endedAt ?? DateTime.now()).difference(trip.startedAt);
    final dateStr = DateFormat('d MMM HH:mm').format(trip.startedAt);
    // Use new v0.1.9 fields if available, fall back to old start/end computation.
    final distance = trip.distanceKm ??
        ((trip.endOdometer != null && trip.startOdometer != null)
            ? (trip.endOdometer! - trip.startOdometer!).abs()
            : null);
    final energy = trip.energyUsedKwh;
    final consumption = trip.avgConsumptionKwh100km;

    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      child: InkWell(
        onTap: () => Navigator.of(context).push(MaterialPageRoute(
          builder: (_) => TripDetailScreen(tripId: trip.id),
        )),
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(dateStr,
                        style: const TextStyle(
                            fontSize: 14, fontWeight: FontWeight.w500)),
                  ),
                  Text('#${trip.id}',
                      style: const TextStyle(
                          fontSize: 11, color: Colors.grey)),
                ],
              ),
              const SizedBox(height: 6),
              Wrap(
                spacing: 6,
                runSpacing: 4,
                children: [
                  _SmallChip(text: _fmtDuration(duration)),
                  if (distance != null)
                    _SmallChip(text: '${distance.toStringAsFixed(1)} km'),
                  if (energy != null)
                    _SmallChip(text: '${energy.toStringAsFixed(2)} kWh'),
                  if (consumption != null)
                    _SmallChip(text: '${consumption.toStringAsFixed(1)} kWh/100'),
                  if (trip.maxBatteryTempC != null)
                    _SmallChip(text: 'max ${trip.maxBatteryTempC!.toStringAsFixed(0)}°C'),
                  if (trip.maxCellSpreadMv != null)
                    _SmallChip(text: 'Δ${trip.maxCellSpreadMv!.toStringAsFixed(0)}mV'),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _MetricChip extends StatelessWidget {
  final String label;
  final String value;
  const _MetricChip({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: Container(
        margin: const EdgeInsets.only(right: 6),
        padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 8),
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: 0.3),
          borderRadius: BorderRadius.circular(6),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(label,
                style: const TextStyle(
                    fontSize: 9,
                    letterSpacing: 1.0,
                    color: Colors.grey)),
            const SizedBox(height: 2),
            Text(value,
                style: const TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w500,
                    fontFeatures: [FontFeature.tabularFigures()])),
          ],
        ),
      ),
    );
  }
}

class _SmallChip extends StatelessWidget {
  final String text;
  const _SmallChip({required this.text});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: Colors.grey.shade800,
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(text,
          style: const TextStyle(
              fontSize: 11,
              fontFeatures: [FontFeature.tabularFigures()])),
    );
  }
}

String _fmtDuration(Duration d) {
  if (d.inHours > 0) return '${d.inHours}h ${d.inMinutes % 60}m';
  return '${d.inMinutes}m ${d.inSeconds % 60}s';
}
