import 'dart:async';

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../data/database.dart';
import '../l10n/strings.dart';
import '../services/connection.dart';
import '../services/locale_service.dart';
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
    // v0.1.29+60: re-render on language switch (per-screen subscription).
    context.watch<LocaleService>();
    // v0.1.59+158 (навигация вариант B): «Замеры» moved OUT of History
    // into its own navigation section (BZ5 rail / BZ3 bottom bar) — the
    // semantic fix: История = прошлое, Замеры = живое «сейчас». History
    // is back to a fixed two tabs; the canHal 2↔3 controller-flip
    // machinery (+151) and the recording-dot tab icon went with it (the
    // recording indication lives inside the Замеры screen itself).
    return DefaultTabController(
      length: 2,
      child: Scaffold(
        appBar: AppBar(
          title: Text(S.of('hist.title')),
          bottom: TabBar(
            tabs: [
              Tab(
                  text: S.of('hist.tab_trips'),
                  icon: const Icon(Icons.route, size: 18)),
              Tab(
                  text: S.of('hist.tab_trends'),
                  icon: const Icon(Icons.show_chart, size: 18)),
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

class _TripsTab extends StatefulWidget {
  const _TripsTab();

  @override
  State<_TripsTab> createState() => _TripsTabState();
}

class _TripsTabState extends State<_TripsTab> {
  // v0.1.26+5 fix: cache the trips query in state so it doesn't re-fire
  // on every notifyListeners() (~3×/sec) from ConnectionService. The
  // previous pattern was:
  //   final svc = context.watch<ConnectionService>();
  //   return FutureBuilder(future: svc.db.getRecentTrips(), ...)
  // which created a fresh Future every rebuild — i.e. ~3 DB queries
  // per second hitting the main isolate. On older phones this could
  // stall the rendering thread enough that the active-trip card's
  // live metrics appeared to update only every few minutes. Now we
  // re-query only on these explicit triggers:
  //   - initState (first load)
  //   - connection state change (trip just started or ended)
  //   - manual refresh (pull-to-refresh, if added later)
  Future<List<Trip>>? _tripsFuture;
  bool? _lastTripActive;

  // v0.1.29+113: 1 Hz repaint while an active trip is present so the active
  // card's "ACTIVE · {dur}" ticks live even with no dongle (twin of the wide
  // _TripsBodyState ticker). Does NOT touch _tripsFuture, so the +26+5 query
  // cache is preserved — only the duration text recomputes on repaint.
  Timer? _tick;
  void _syncTicker(bool hasActive) {
    if (hasActive && _tick == null) {
      _tick = Timer.periodic(const Duration(seconds: 1), (_) {
        if (mounted) setState(() {});
      });
    } else if (!hasActive && _tick != null) {
      _tick!.cancel();
      _tick = null;
    }
  }

  @override
  void dispose() {
    _tick?.cancel();
    super.dispose();
  }

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  void _refresh() {
    final svc = context.read<ConnectionService>();
    setState(() {
      _tripsFuture = svc.db.getRecentTrips();
    });
  }

  @override
  Widget build(BuildContext context) {
    // We still want to know when a trip starts/ends to refresh the list.
    // Subscribing via select() to a single bool means we only rebuild
    // when that flag flips, not on every notify.
    final svc = context.watch<ConnectionService>();
    // v0.1.29+111: a dongle-free trip is owned by HalTelemetryService and
    // never flips svc.currentTripId, so the refresh below never fired for
    // it — the row sat in the DB until something else rebuilt the tab
    // (the "tap another trip" workaround). select() on the HAL trip row
    // id rebuilds exactly on trip open/close, not on every 200 ms notify.
    final halTripId =
        context.select<HalTelemetryService, int?>((h) => h.halTripDbId);
    final tripActive = svc.currentTripId != null || halTripId != null;
    if (_lastTripActive != null && _lastTripActive != tripActive) {
      // Active state flipped — refresh the list to pick up new/ended trip.
      WidgetsBinding.instance.addPostFrameCallback((_) => _refresh());
    }
    _lastTripActive = tripActive;

    return FutureBuilder<List<Trip>>(
      future: _tripsFuture,
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
                  Text(S.of('hist.empty_title'),
                      style: const TextStyle(fontSize: 15)),
                  const SizedBox(height: 8),
                  Text(
                    S.of('hist.empty_hint'),
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
        // v0.1.29+113: arm the live-duration ticker (post-frame — never
        // setState during build).
        WidgetsBinding.instance.addPostFrameCallback(
            (_) { if (mounted) _syncTicker(active.isNotEmpty); });
        final past = trips.where((t) => t.endedAt != null).toList();

        return ListView.builder(
          padding: const EdgeInsets.only(top: 8, bottom: 24),
          itemCount: active.length + past.length,
          itemBuilder: (context, i) {
            if (i < active.length) {
              // v0.1.26+5: do NOT pass svc down — _ActiveTripCard will
              // watch it itself, so its live metrics rebuild on every
              // notifyListeners without dragging this whole ListView
              // along for the ride.
              return _ActiveTripCard(trip: active[i]);
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
///
/// v0.1.26+5: takes svc via context.watch (own subscription) instead of
/// via constructor. This lets the parent _TripsTab unsubscribe from
/// the high-frequency notifyListeners stream — only this card needs to
/// rebuild on every poll, not the entire trips list.
class _ActiveTripCard extends StatelessWidget {
  final Trip trip;
  const _ActiveTripCard({required this.trip});

  @override
  Widget build(BuildContext context) {
    final svc = context.watch<ConnectionService>();
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
                  Text(S.of('hist.active_trip'),
                      style: const TextStyle(
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
                  _MetricChip(
                      label: S.of('hist.time'), value: _fmtDuration(duration)),
                  _MetricChip(
                      label: S.of('hist.dist'),
                      value: dist != null
                          ? '${dist.toStringAsFixed(1)} km'
                          : '—'),
                  _MetricChip(
                      label: S.of('hist.energy'),
                      value: energy != null
                          ? '${energy.toStringAsFixed(2)} kWh'
                          : '—'),
                ],
              ),
              const SizedBox(height: 6),
              Row(
                children: [
                  _MetricChip(
                      label: S.of('hist.avg'),
                      value: cons != null
                          ? '${cons.toStringAsFixed(1)} kWh/100'
                          : '—'),
                  _MetricChip(
                      label: S.of('hist.peak_kw'),
                      value: peakPwr != null
                          ? peakPwr.toStringAsFixed(1)
                          : '—'),
                  _MetricChip(
                      label: S.of('hist.temp'),
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
                    _SmallChip(
                        text: S.of('hist.max_temp_chip').replaceFirst(
                            '{t}', trip.maxBatteryTempC!.toStringAsFixed(0))),
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
