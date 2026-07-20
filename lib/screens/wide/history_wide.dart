import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:fl_chart/fl_chart.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../../data/database.dart';
import '../../l10n/strings.dart';
import '../../services/connection.dart';
import '../../services/hal_telemetry_service.dart';
import '../../services/locale_service.dart';
import '../../services/speed_profile_service.dart';
import '../speed_profile.dart';
import '../trends.dart';
import '../trip_detail.dart';

/// v0.1.9: Wide layout for History on head unit.
///
/// Layout strategy:
///   - When trip is active: dedicated full-width Active Trip view with
///     large live metrics + sparkline. Past trips collapse to a thin
///     drawer on the left, accessible by tapping a tab.
///   - When no active trip: split-pane — past trips list left (~35%),
///     selected trip detail + charts on the right (~65%).
///   - Trends mode: full-width screen with all charts in a grid.
///
/// Read-only by design: head unit users see data, don't manipulate.
class HistoryWideScreen extends StatefulWidget {
  const HistoryWideScreen({super.key});

  @override
  State<HistoryWideScreen> createState() => _HistoryWideScreenState();
}

enum _Tab { trips, trends, measure }

class _HistoryWideScreenState extends State<HistoryWideScreen> {
  _Tab _tab = _Tab.trips;
  int? _selectedTripId;

  @override
  Widget build(BuildContext context) {
    // v0.1.29+60: re-render on language switch (per-screen subscription).
    context.watch<LocaleService>();
    // v0.1.53+152: «Замеры» lives HERE — the head unit renders THIS
    // wide screen, not the phone HistoryScreen (the +151 lesson: the
    // tab was cut into the wrong entry point; server logs proved the
    // build was right and the door was on the wrong wall). Same
    // honesty gate as the phone side: no HAL verdict → no tab.
    final canHal =
        context.select<HalTelemetryService, bool>((h) => h.canUseHal);
    final recording =
        context.select<SpeedProfileService, bool>((s) => s.active);
    // Defensive: if the verdict flips away while «Замеры» is open
    // (probe re-settles), fall back to Trips instead of a dead pane.
    if (!canHal && _tab == _Tab.measure) _tab = _Tab.trips;
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Top tab control + title
          Row(
            children: [
              Text(S.of('hist.hdr'),
                  style: const TextStyle(
                      fontSize: 14,
                      letterSpacing: 2.0,
                      fontWeight: FontWeight.w500,
                      color: Colors.grey)),
              const SizedBox(width: 16),
              SegmentedButton<_Tab>(
                segments: [
                  ButtonSegment(
                      value: _Tab.trips,
                      label: Text(S.of('hist.tab_trips')),
                      icon: const Icon(Icons.route, size: 16)),
                  ButtonSegment(
                      value: _Tab.trends,
                      label: Text(S.of('hist.tab_trends')),
                      icon: const Icon(Icons.show_chart, size: 16)),
                  if (canHal)
                    ButtonSegment(
                        value: _Tab.measure,
                        label: Text(S.of('hist.tab_measure')),
                        icon: _MeasureSegIcon(recording: recording)),
                ],
                selected: {_tab},
                onSelectionChanged: (s) =>
                    setState(() => _tab = s.first),
                showSelectedIcon: false,
              ),
            ],
          ),
          const SizedBox(height: 16),
          Expanded(
            child: switch (_tab) {
              _Tab.trips => _TripsBody(
                  selectedTripId: _selectedTripId,
                  onSelectTrip: (id) =>
                      setState(() => _selectedTripId = id),
                ),
              _Tab.trends => const TrendsScreen(),
              _Tab.measure => const SpeedProfileScreen(),
            },
          ),
        ],
      ),
    );
  }
}

/// v0.1.53+152: segment icon with the recording dot — same signal as
/// the phone tab (_MeasureTabIcon in history.dart): a live session is
/// visible from any History mode.
class _MeasureSegIcon extends StatelessWidget {
  final bool recording;
  const _MeasureSegIcon({required this.recording});

  @override
  Widget build(BuildContext context) {
    return Stack(
      clipBehavior: Clip.none,
      children: [
        const Icon(Icons.speed, size: 16),
        if (recording)
          Positioned(
            right: -4,
            top: -3,
            child: Container(
              width: 6,
              height: 6,
              decoration: const BoxDecoration(
                color: Colors.redAccent,
                shape: BoxShape.circle,
              ),
            ),
          ),
      ],
    );
  }
}

class _TripsBody extends StatelessWidget {
  final int? selectedTripId;
  final ValueChanged<int> onSelectTrip;
  const _TripsBody({required this.selectedTripId, required this.onSelectTrip});

  @override
  Widget build(BuildContext context) {
    final svc = context.watch<ConnectionService>();
    // v0.1.29+111: the trips query below re-fires per REBUILD, and without
    // a dongle ConnectionService barely notifies — a dongle-free HAL trip
    // row landed in the DB with nothing rebuilding this pane, so the list
    // only caught up when selecting a trip forced a parent setState (the
    // "tap another trip" workaround). select() on the HAL trip row id
    // adds exactly one rebuild per trip open/close.
    context.select<HalTelemetryService, int?>((h) => h.halTripDbId);
    return FutureBuilder<List<Trip>>(
      future: svc.db.getRecentTrips(),
      builder: (context, snap) {
        if (!snap.hasData) {
          return const Center(child: CircularProgressIndicator());
        }
        final trips = snap.data!;
        if (trips.isEmpty) {
          return Center(
            child: Padding(
              padding: const EdgeInsets.all(48),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.route_outlined,
                      size: 80, color: Colors.grey.shade600),
                  const SizedBox(height: 20),
                  Text(S.of('hist.empty_title'),
                      style: const TextStyle(fontSize: 18)),
                  const SizedBox(height: 12),
                  Text(
                    S.of('hist.empty_hint'),
                    textAlign: TextAlign.center,
                    style: TextStyle(fontSize: 13, color: Colors.grey.shade600),
                  ),
                ],
              ),
            ),
          );
        }
        // v0.1.25+3 fix: previously when there was an active trip, the
        // History page collapsed to show ONLY that trip full-screen,
        // hiding the list of past trips entirely. Users complained they
        // could not navigate to any older trip while a trip was active.
        //
        // Now the active trip is just the first item in the trips list
        // (it sorts to the top because trips are returned newest-first,
        // and the active trip is by definition newest). The split-pane
        // layout is used unconditionally — left = list of all trips,
        // right = detail of the selected trip. Active trip is selected
        // by default if present, else most recent completed.
        //
        // The _ActiveTripWideView widget is no longer reached from
        // History; it's preserved in code for possible future use as
        // a "follow live trip" mode but isn't currently wired up.
        final activeIdx = trips.indexWhere((t) => t.endedAt == null);
        final defaultSelectedId = selectedTripId ??
            (activeIdx >= 0 ? trips[activeIdx].id : trips.first.id);
        final selectedTrip = trips.firstWhere(
            (t) => t.id == defaultSelectedId,
            orElse: () => trips.first);

        return Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Left: trips list (~32%)
            SizedBox(
              width: 380,
              child: _TripsListColumn(
                trips: trips,
                selectedId: selectedTrip.id,
                onSelect: onSelectTrip,
              ),
            ),
            const SizedBox(width: 16),
            // Right: selected trip detail + charts
            Expanded(
              child: _SelectedTripDetail(trip: selectedTrip, svc: svc),
            ),
          ],
        );
      },
    );
  }
}

class _TripsListColumn extends StatefulWidget {
  final List<Trip> trips;
  final int selectedId;
  final ValueChanged<int> onSelect;
  const _TripsListColumn({
    required this.trips,
    required this.selectedId,
    required this.onSelect,
  });

  @override
  State<_TripsListColumn> createState() => _TripsListColumnState();
}

class _TripsListColumnState extends State<_TripsListColumn> {
  // v0.1.29+114: 1 Hz repaint while an active trip is present so the
  // "ACTIVE · {dur}" duration ticks live. This lives in the LIST column
  // (not the parent _TripsBody as in +113) so the ticking rebuild does
  // NOT cascade into _SelectedTripDetail — that pane owns four chart
  // FutureBuilders, and rebuilding it every second re-fired ~5 DB queries
  // per second for nothing (the +26+5 anti-thrash lesson). Only the list
  // repaints now. Armed/disarmed from build; no active trip → no timer.
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
  Widget build(BuildContext context) {
    final trips = widget.trips;
    final hasActive = trips.any((t) => t.endedAt == null);
    WidgetsBinding.instance
        .addPostFrameCallback((_) { if (mounted) _syncTicker(hasActive); });
    return Card(
      child: ListView.separated(
        padding: const EdgeInsets.symmetric(vertical: 8),
        itemCount: trips.length,
        // v0.1.26+16: divider was `height: 1` plain Divider — invisible
        // on the BZ5 head-unit dark theme (the 1px hairline blended
        // into the card background). Bumped to indent + visible color
        // so trip entries read as a proper list rather than a wall of
        // text.
        separatorBuilder: (_, __) => Divider(
          height: 1,
          thickness: 1,
          color: Colors.white.withValues(alpha: 0.08),
          indent: 16,
          endIndent: 16,
        ),
        itemBuilder: (context, i) {
          final t = trips[i];
          final selected = t.id == widget.selectedId;
          final duration =
              (t.endedAt ?? DateTime.now()).difference(t.startedAt);
          final dateStr = DateFormat('d MMM HH:mm').format(t.startedAt);
          final dist = t.distanceKm;
          // v0.1.25+3: visually distinguish the active trip in the list
          // with a green pulse-dot icon and "ACTIVE" subtitle, so the
          // user can immediately spot the running trip without having
          // to inspect ended_at by hand.
          final isActive = t.endedAt == null;
          return Container(
            color: selected
                ? Colors.lightBlueAccent.withValues(alpha: 0.1)
                : null,
            child: ListTile(
              dense: true,
              onTap: () => widget.onSelect(t.id),
              leading: isActive
                  ? Container(
                      width: 10,
                      height: 10,
                      decoration: const BoxDecoration(
                        color: Colors.greenAccent,
                        shape: BoxShape.circle,
                      ),
                    )
                  : null,
              title: Text(dateStr,
                  style: TextStyle(
                      fontWeight:
                          selected ? FontWeight.w600 : FontWeight.normal,
                      fontSize: 13)),
              subtitle: Text(
                isActive
                    ? S
                        .of('hist.active_fmt')
                        .replaceFirst('{dur}', _fmtDuration(duration))
                    : '${_fmtDuration(duration)}'
                      '${dist != null ? ' · ${dist.toStringAsFixed(1)} km' : ''}',
                style: TextStyle(
                  fontSize: 11,
                  color: isActive ? Colors.greenAccent : null,
                ),
              ),
              trailing: Text('#${t.id}',
                  style:
                      const TextStyle(fontSize: 10, color: Colors.grey)),
            ),
          );
        },
      ),
    );
  }
}

class _SelectedTripDetail extends StatelessWidget {
  final Trip trip;
  final ConnectionService svc;
  const _SelectedTripDetail({required this.trip, required this.svc});

  @override
  Widget build(BuildContext context) {
    final duration =
        (trip.endedAt ?? DateTime.now()).difference(trip.startedAt);
    final dateStr = DateFormat('d MMMM y, HH:mm').format(trip.startedAt);

    // v0.1.26+13: previously this rendered only a thin date+metrics
    // header plus 4 chart cards (SOC / battery temp / pack V / HV bus),
    // missing the summary, derived metrics, speed histogram, odometer
    // range, and moving/idle donut cards that trip_detail.dart provides
    // on phone. The wide head-unit view should be a superset of the
    // phone view, not a subset.
    //
    // The fix: instead of a hand-rolled compact panel, reuse the same
    // wide-layout structure as TripDetailScreen._buildWideLayout. Those
    // cards (TripSummaryCard / DerivedMetricsCard / OdometerRangeCard /
    // MovingIdleDonutCard / SpeedHistogramCard) are now public exports
    // from trip_detail.dart. The header row at the very top is kept —
    // it duplicates some of TripSummaryCard's info but with a different
    // visual treatment (big inline metrics) that matches the rest of
    // the head-unit chrome.

    Widget pair(Widget left, Widget right) => IntrinsicHeight(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(child: left),
              const SizedBox(width: 12),
              Expanded(child: right),
            ],
          ),
        );

    return ListView(
      padding: EdgeInsets.zero,
      children: [
        // Header card: same as before — the "21 May 2026, 10:21" line +
        // DISTANCE / ENERGY / AVG inline. Kept verbatim to preserve the
        // visual you've been used to.
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(dateStr,
                          style: const TextStyle(
                              fontSize: 18, fontWeight: FontWeight.w500)),
                      const SizedBox(height: 4),
                      Text(_fmtDuration(duration),
                          style: const TextStyle(
                              fontSize: 13, color: Colors.grey)),
                    ],
                  ),
                ),
                _bigMetric(S.of('hist.distance'),
                    trip.distanceKm != null
                        ? '${trip.distanceKm!.toStringAsFixed(1)} km'
                        : '—'),
                _bigMetric(S.of('hist.energy'),
                    trip.energyUsedKwh != null
                        ? '${trip.energyUsedKwh!.toStringAsFixed(2)} kWh'
                        : '—'),
                _bigMetric('AVG',
                    trip.avgConsumptionKwh100km != null
                        ? '${trip.avgConsumptionKwh100km!.toStringAsFixed(1)}'
                        : '—',
                    unit: 'kWh/100'),
              ],
            ),
          ),
        ),
        const SizedBox(height: 12),
        // v0.1.26+13: full trip detail content. Mirrors TripDetailScreen
        // wide layout: summary | metrics on row 1, odometer | donut on
        // row 2, full-width histogram on row 3, charts after that.
        pair(
          TripSummaryCard(trip: trip, svc: svc),
          DerivedMetricsCard(trip: trip),
        ),
        const SizedBox(height: 12),
        pair(
          OdometerRangeCard(trip: trip),
          MovingIdleDonutCard(trip: trip),
        ),
        const SizedBox(height: 12),
        SpeedHistogramCard(tripId: trip.id, trip: trip),
        const SizedBox(height: 12),
        SizedBox(
          height: 240,
          child: pair(
            _ChartCard(
              title: 'SOC',
              tripId: trip.id,
              ecuTx: '790',
              did: '0005',
              halName: 'soc_precise|soc_display',
              snapshotField: 'soc',
                seriesName: 'soc',
              color: Colors.greenAccent,
              unit: '%',
              svc: svc,
            ),
            _ChartCard(
              title: S.of('hist.battery_temp'),
              tripId: trip.id,
              ecuTx: '790',
              did: '002F',
              halName: 'probe_highest_temp|battery_temp_bigdata',
              snapshotField: 'batteryTempC',
                seriesName: 'battery_temp_c',
              color: Colors.orangeAccent,
              unit: '°C',
              // v0.1.26+9: NO valueTransform — registry already
              // applies offset -40 (see trip_detail.dart for the
              // long form of this comment).
              svc: svc,
            ),
          ),
        ),
        const SizedBox(height: 12),
        SizedBox(
          height: 240,
          child: pair(
            _ChartCard(
              title: S.of('hist.pack_voltage'),
              tripId: trip.id,
              ecuTx: '740',
              did: '0022',
              halName: 'pack_voltage',
              snapshotField: 'packVoltageV',
                seriesName: 'pack_voltage_v',
              color: Colors.yellowAccent,
              unit: 'V',
              // No valueTransform — registry decoder already applies scale.
              svc: svc,
            ),
            _PowerBarCard(trip: trip, svc: svc),
          ),
        ),
      ],
    );
  }

  Widget _bigMetric(String label, String value, {String? unit}) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Text(label,
              style: const TextStyle(
                  fontSize: 10, letterSpacing: 1.5, color: Colors.grey)),
          const SizedBox(height: 2),
          Text(value,
              style: const TextStyle(
                  fontSize: 22,
                  fontWeight: FontWeight.w300,
                  fontFeatures: [FontFeature.tabularFigures()])),
          if (unit != null)
            Text(unit,
                style: const TextStyle(fontSize: 10, color: Colors.grey)),
        ],
      ),
    );
  }
}

/// v0.1.9: Active trip wide view — large live metrics + sparkline.
/// Shows on head unit during an ongoing trip.
class _ActiveTripWideView extends StatelessWidget {
  final Trip trip;
  final ConnectionService svc;
  const _ActiveTripWideView({required this.trip, required this.svc});

  @override
  Widget build(BuildContext context) {
    final duration =
        svc.tripDuration ?? DateTime.now().difference(trip.startedAt);
    final dateStr = DateFormat('d MMM, HH:mm').format(trip.startedAt);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // Top bar: ACTIVE + date + time
        Card(
          color: Colors.green.shade900.withValues(alpha: 0.25),
          shape: RoundedRectangleBorder(
            side: const BorderSide(color: Colors.greenAccent, width: 1),
            borderRadius: BorderRadius.circular(12),
          ),
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Row(
              children: [
                Container(
                  width: 12, height: 12,
                  decoration: const BoxDecoration(
                    shape: BoxShape.circle,
                    color: Colors.greenAccent,
                  ),
                ),
                const SizedBox(width: 10),
                Text(S.of('hist.active_trip'),
                    style: const TextStyle(
                        fontSize: 14,
                        letterSpacing: 2.0,
                        fontWeight: FontWeight.w500,
                        color: Colors.greenAccent)),
                const SizedBox(width: 16),
                Text(dateStr,
                    style: const TextStyle(
                        fontSize: 18, color: Colors.white)),
                const Spacer(),
                Text('#${trip.id}',
                    style: const TextStyle(
                        fontSize: 14, color: Colors.grey)),
              ],
            ),
          ),
        ),
        const SizedBox(height: 16),
        // 3-column big-metrics row 1
        Row(
          children: [
            Expanded(
                child: _HugeMetric(
                    label: 'TIME',
                    value: _fmtDuration(duration),
                    color: Colors.white)),
            const SizedBox(width: 12),
            Expanded(
                child: _HugeMetric(
                    label: S.of('hist.distance'),
                    value: svc.tripDistanceKm != null
                        ? svc.tripDistanceKm!.toStringAsFixed(1)
                        : '—',
                    unit: 'km',
                    color: Colors.white)),
            const SizedBox(width: 12),
            Expanded(
                child: _HugeMetric(
                    label: S.of('hist.energy_used'),
                    value: svc.tripEnergyUsedKwh != null
                        ? svc.tripEnergyUsedKwh!.toStringAsFixed(2)
                        : '—',
                    unit: 'kWh',
                    color: Colors.yellowAccent)),
          ],
        ),
        const SizedBox(height: 12),
        // 3-column big-metrics row 2
        Row(
          children: [
            Expanded(
                child: _HugeMetric(
                    label: S.of('hist.avg_cons'),
                    value: svc.tripAvgConsumptionKwh100km != null
                        ? svc.tripAvgConsumptionKwh100km!.toStringAsFixed(1)
                        : '—',
                    unit: 'kWh/100km',
                    color: Colors.greenAccent)),
            const SizedBox(width: 12),
            Expanded(
                child: _HugeMetric(
                    label: S.of('hist.peak_power'),
                    value: svc.tripPeakPowerKw != null
                        ? svc.tripPeakPowerKw!.toStringAsFixed(1)
                        : '—',
                    unit: 'kW',
                    color: Colors.orangeAccent)),
            const SizedBox(width: 12),
            Expanded(
                child: _HugeMetric(
                    label: S.of('hist.temp_range'),
                    value: (svc.tripMinTempC != null && svc.tripMaxTempC != null)
                        ? '${svc.tripMinTempC!.toStringAsFixed(0)}–${svc.tripMaxTempC!.toStringAsFixed(0)}'
                        : '—',
                    unit: '°C',
                    color: Colors.lightBlueAccent)),
          ],
        ),
        const SizedBox(height: 16),
        // Mini SOC chart for active trip
        Expanded(
          child: _ChartCard(
            title: S.of('hist.soc_over_time'),
            tripId: trip.id,
            ecuTx: '790',
            did: '0005',
            color: Colors.greenAccent,
            unit: '%',
            svc: svc,
            big: true,
          ),
        ),
      ],
    );
  }
}

class _HugeMetric extends StatelessWidget {
  final String label;
  final String value;
  final String? unit;
  final Color color;
  const _HugeMetric({
    required this.label,
    required this.value,
    this.unit,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(label,
                style: const TextStyle(
                    fontSize: 12,
                    letterSpacing: 1.5,
                    color: Colors.grey)),
            const SizedBox(height: 8),
            Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text(value,
                    style: TextStyle(
                        fontSize: 44,
                        fontWeight: FontWeight.w300,
                        color: color,
                        height: 1.0,
                        fontFeatures:
                            const [FontFeature.tabularFigures()])),
                if (unit != null) ...[
                  const SizedBox(width: 4),
                  Padding(
                    padding: const EdgeInsets.only(bottom: 4),
                    child: Text(unit!,
                        style: const TextStyle(
                            fontSize: 14, color: Colors.grey)),
                  ),
                ],
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// Inline chart card shared between active and past trip views.
class _ChartCard extends StatelessWidget {
  final String title;
  final int tripId;
  final String ecuTx;
  final String did;
  final Color color;
  final String unit;
  final double Function(double)? valueTransform;
  final ConnectionService svc;
  final bool big;
  /// v0.1.29+111: hal_samples signal name(s) to fall back to when the
  /// trip has no OBD2 samples (a dongle-free HAL trip records nothing
  /// into `samples`, so these charts were permanently empty for it).
  /// '|' separates alternates tried in order, e.g.
  /// 'soc_precise|soc_display'. Null → OBD2 only (honest "no data" when
  /// the HAL stream has no equivalent signal, e.g. HV bus).
  final String? halName;
  /// v0.1.29+128: snapshot fallback column — third loader stage for
  /// restored trips (samples never uploaded, snapshots are). See the
  /// trip_detail.dart twin for the long-form comment.
  final String? snapshotField;
  /// v0.1.41+140: trip_series name — 4th ladder step, see trip_detail twin.
  final String? seriesName;
  const _ChartCard({
    required this.title,
    required this.tripId,
    required this.ecuTx,
    required this.did,
    required this.color,
    required this.unit,
    required this.svc,
    this.valueTransform,
    this.big = false,
    this.halName,
    this.snapshotField,
    this.seriesName,
  });

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<
        ({List<({DateTime ts, double? v})> pts, bool fromSnapshots})>(
      future: _loadPoints(),
      builder: (context, snap) {
        final data = snap.data;
        // v0.1.39+138: same honesty rule as the narrow twin — an error
        // renders as an error, never as an eternal spinner.
        if (snap.hasError) {
          return Card(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Row(children: [
                const Icon(Icons.error_outline, size: 16),
                const SizedBox(width: 6),
                Expanded(
                    child: Text(S.of('trip.chart_error'),
                        style: Theme.of(context).textTheme.bodySmall)),
              ]),
            ),
          );
        }
        return Card(
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Container(
                      width: 8, height: 8,
                      decoration: BoxDecoration(
                        color: color,
                        shape: BoxShape.circle,
                      ),
                    ),
                    const SizedBox(width: 6),
                    Text(title.toUpperCase(),
                        style: const TextStyle(
                            fontSize: 11,
                            letterSpacing: 1.5,
                            color: Colors.grey)),
                    // v0.1.29+128: source caption, snapshot-fed only.
                    if (data != null && data.fromSnapshots) ...[
                      const SizedBox(width: 6),
                      Flexible(
                        child: Text(
                          S.of('trip.chart_src_snapshots'),
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                              fontSize: 10,
                              color: Colors.grey.shade600),
                        ),
                      ),
                    ],
                  ],
                ),
                const SizedBox(height: 8),
                Expanded(
                  child: data == null
                      ? const Center(
                          child:
                              CircularProgressIndicator(strokeWidth: 2))
                      : _buildChart(data.pts),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  /// v0.1.29+111: unified point loader. OBD2 samples first (the dongle
  /// series, exactly what these tiles always drew); when the trip has
  /// none — a dongle-free HAL trip — fall back to the hal_samples series
  /// named [halName]. Both carry decoded physical values in the same
  /// units, so the chart body is source-agnostic.
  /// v0.1.29+128: third stage — snapshots by trip time window (restored
  /// trips have no sample series at all). Twin of trip_detail.dart.
  Future<({List<({DateTime ts, double? v})> pts, bool fromSnapshots})>
      _loadPoints() async {
    final obd =
        await svc.db.getSamplesForTrip(tripId, ecuTx: ecuTx, did: did);
    if (obd.isNotEmpty) {
      return (
        pts: [for (final s in obd) (ts: s.timestamp, v: s.numericValue)],
        fromSnapshots: false
      );
    }
    final names = halName;
    if (names != null) {
      for (final n in names.split('|')) {
        final hal = await svc.db.getHalSamplesForTripByName(tripId, n);
        if (hal.isNotEmpty) {
          return (
            pts: [
              for (final s in hal) (ts: s.timestamp, v: s.numericValue)
            ],
            fromSnapshots: false
          );
        }
      }
    }
    // v0.1.41+140: 4th ladder step — cloud-synced trip_series (see the
    // trip_detail twin for the long-form comment).
    final sName = seriesName;
    if (sName != null) {
      final row = await svc.db.getTripSeriesForChart(tripId, sName);
      if (row != null) {
        final decoded = jsonDecode(row.pointsJson);
        if (decoded is List && decoded.length >= 2) {
          final pts = <({DateTime ts, double? v})>[];
          for (final p in decoded) {
            if (p is List && p.length == 2 && p[0] is num && p[1] is num) {
              pts.add((
                ts: DateTime.fromMillisecondsSinceEpoch(
                    (p[0] as num).toInt() * 1000),
                v: (p[1] as num).toDouble()
              ));
            }
          }
          if (pts.length >= 2) return (pts: pts, fromSnapshots: false);
        }
      }
    }
    final field = snapshotField;
    if (field == null) return (pts: const <({DateTime ts, double? v})>[], fromSnapshots: false);
    final trip = await svc.db.getTrip(tripId);
    if (trip == null) return (pts: const <({DateTime ts, double? v})>[], fromSnapshots: false);
    // Time-window query, not snapshots.trip_id — FK linkage doesn't
    // survive a wipe/restore, captured_at does.
    final to = trip.endedAt ?? trip.lastAliveTs ?? DateTime.now();
    final snaps = await svc.db.getSnapshotsInRange(trip.startedAt, to);
    // chargingPowerKw is 0.0 (not NULL) outside charging — see the
    // trip_detail.dart twin comment. No real charging in the window →
    // "no data", not a flat zero line.
    if (field == 'chargingPowerKw') {
      final hasCharge = snaps.any((s) =>
          (s.isCharging ?? false) || ((s.chargingPowerKw ?? 0) > 0));
      if (!hasCharge) return (pts: const <({DateTime ts, double? v})>[], fromSnapshots: false);
    }
    final pts = <({DateTime ts, double? v})>[];
    for (final s in snaps) {
      final v = switch (field) {
        'soc' => s.soc,
        'batteryTempC' => s.batteryTempC,
        'packVoltageV' => s.packVoltageV,
        'chargingPowerKw' => s.chargingPowerKw,
        _ => null,
      };
      if (v != null) pts.add((ts: s.capturedAt, v: v));
    }
    return (pts: pts, fromSnapshots: pts.isNotEmpty);
  }

  Widget _buildChart(List<({DateTime ts, double? v})> samples) {
    final points = <FlSpot>[];
    if (samples.isEmpty) {
      return Center(
        child: Text(S.of('common.no_data'),
            style: TextStyle(color: Colors.grey.shade600, fontSize: 12)),
      );
    }
    final t0 = samples.first.ts;
    double minY = double.infinity;
    double maxY = double.negativeInfinity;
    for (final s in samples) {
      if (s.v == null) continue;
      final x = s.ts.difference(t0).inSeconds.toDouble();
      final y = valueTransform != null ? valueTransform!(s.v!) : s.v!;
      points.add(FlSpot(x, y));
      if (y < minY) minY = y;
      if (y > maxY) maxY = y;
    }
    // v0.1.29+113: one point is honest data for a slow event-driven
    // signal (battery temp sleeps at standstill). Duplicate it at the
    // last timestamp so fl_chart has a segment — a flat line, not
    // "no data". Zero points still falls through to the notice.
    if (points.length == 1) {
      final only = points.first;
      final lastX = samples.last.ts.difference(t0).inSeconds.toDouble();
      points.add(FlSpot(lastX > only.x ? lastX : only.x + 1, only.y));
    }
    if (points.length < 2) {
      return Center(
        child: Text(S.of('hist.collecting'),
            style: TextStyle(color: Colors.grey.shade600, fontSize: 12)),
      );
    }
    final ySpan = (maxY - minY).abs();
    final pad = ySpan > 0.5 ? ySpan * 0.05 : 0.5;

    return LineChart(
      LineChartData(
        minY: minY - pad,
        maxY: maxY + pad,
        gridData: FlGridData(
          show: true,
          drawVerticalLine: false,
          getDrawingHorizontalLine: (_) => FlLine(
            color: Colors.grey.shade800,
            strokeWidth: 0.5,
          ),
        ),
        titlesData: FlTitlesData(
          rightTitles:
              const AxisTitles(sideTitles: SideTitles(showTitles: false)),
          topTitles:
              const AxisTitles(sideTitles: SideTitles(showTitles: false)),
          leftTitles: AxisTitles(
            sideTitles: SideTitles(
              showTitles: true,
              reservedSize: 40,
              getTitlesWidget: (v, _) => Text(
                v.toStringAsFixed(v.abs() < 10 ? 1 : 0),
                style: TextStyle(
                    fontSize: big ? 12 : 10, color: Colors.grey),
              ),
            ),
          ),
          bottomTitles: AxisTitles(
            sideTitles: SideTitles(
              showTitles: true,
              reservedSize: 22,
              getTitlesWidget: (v, _) => Text(
                '${(v / 60).round()}m',
                style: const TextStyle(fontSize: 10, color: Colors.grey),
              ),
            ),
          ),
        ),
        borderData: FlBorderData(show: false),
        lineBarsData: [
          LineChartBarData(
            spots: points,
            isCurved: false,
            color: color,
            barWidth: big ? 2.0 : 1.5,
            dotData: const FlDotData(show: false),
            belowBarData: BarAreaData(
              show: true,
              color: color.withValues(alpha: 0.1),
            ),
          ),
        ],
      ),
    );
  }
}

String _fmtDuration(Duration d) {
  if (d.inHours > 0) return '${d.inHours}h ${d.inMinutes % 60}m';
  return '${d.inMinutes}m ${d.inSeconds % 60}s';
}

/// v0.1.29+113: Tesla-style trip power profile. Replaces the HV-bus voltage
/// chart (no HAL equivalent, low value). Loads the raw motor_power series
/// (signed kW: + traction, − regen) from hal_samples and bins it into narrow
/// bars over the trip's time span — each bar is the MEAN power in its bin
/// (bin width = span / barCount). Raw data is never smoothed; only the
/// display is binned, matching the "as in a Tesla" ask. Traction bars point
/// up (green), regen bars down (blue). Footer shows the frozen per-trip regen
/// energy and peak regen from the Trip row (+98) — not recomputed here.
class _PowerBarCard extends StatelessWidget {
  final Trip trip;
  final ConnectionService svc;
  const _PowerBarCard({required this.trip, required this.svc});

  static const int _barCount = 60;

  /// v0.1.43+142 §4: shared binner — the raw hal_samples source and the
  /// downsampled trip_series source go through the SAME time-fraction
  /// formula, so equal points always yield bit-identical bins. Semantics
  /// are the old inline loop verbatim: the time anchor/span come from the
  /// FIRST/LAST point regardless of value, null values are skipped in the
  /// accumulation only, an empty bin renders as 0.
  static List<double> _binPoints(List<(DateTime, double?)> pts) {
    if (pts.length < 2) return const [];
    final t0 = pts.first.$1;
    final spanSec = pts.last.$1.difference(t0).inSeconds.toDouble();
    if (spanSec <= 0) return const [];
    final sums = List<double>.filled(_barCount, 0);
    final counts = List<int>.filled(_barCount, 0);
    for (final p in pts) {
      final v = p.$2;
      if (v == null) continue;
      final frac = p.$1.difference(t0).inSeconds / spanSec;
      var idx = (frac * _barCount).floor();
      if (idx < 0) idx = 0;
      if (idx >= _barCount) idx = _barCount - 1;
      sums[idx] += v;
      counts[idx] += 1;
    }
    return [
      for (var i = 0; i < _barCount; i++)
        counts[i] == 0 ? 0.0 : sums[i] / counts[i]
    ];
  }

  /// Two-stage loader. Stage 1: raw hal_samples motor_power — live trips,
  /// look unchanged. Stage 2 (v0.1.43+142 §4): the downsampled 'power_kw'
  /// trip_series (generated by +140, restored via pull) — the restored-trip
  /// case where the raw samples are gone forever. Both stages resample
  /// into the same 60 bars via _binPoints. The bool is true on the series
  /// branch and drives the honesty caption (LTTB-240 coarsens a long
  /// trip's shape; the bins over ≤240 points are still correct means).
  Future<(List<double>, bool)> _bins() async {
    final rows =
        await svc.db.getHalSamplesForTripByName(trip.id, 'motor_power');
    if (rows.length >= 2) {
      return (
        _binPoints([for (final r in rows) (r.timestamp, r.numericValue)]),
        false
      );
    }
    final row = await svc.db.getTripSeriesForChart(trip.id, 'power_kw');
    if (row == null) return (const <double>[], false);
    final decoded = jsonDecode(row.pointsJson);
    if (decoded is! List) return (const <double>[], false);
    final pts = <(DateTime, double?)>[];
    for (final p in decoded) {
      if (p is List && p.length == 2 && p[0] is num && p[1] is num) {
        pts.add((
          DateTime.fromMillisecondsSinceEpoch((p[0] as num).toInt() * 1000),
          (p[1] as num).toDouble()
        ));
      }
    }
    if (pts.length < 2) return (const <double>[], false);
    return (_binPoints(pts), true);
  }

  @override
  Widget build(BuildContext context) {
    final regenKwh = trip.regenEnergyKwh;
    final peakRegen = trip.peakRegenKw;
    return FutureBuilder<(List<double>, bool)>(
      future: _bins(),
      builder: (context, snap) {
        // +138 rule: an error must never hide behind an empty state.
        if (snap.hasError) {
          return Row(children: [
            const Icon(Icons.error_outline, size: 16),
            const SizedBox(width: 6),
            Expanded(
                child: Text(S.of('trip.chart_error'),
                    style: Theme.of(context).textTheme.bodySmall)),
          ]);
        }
        final data = snap.data;
        if (data == null || data.$1.isEmpty) {
          // Loading, or genuinely no source — neither raw hal_samples nor
          // a restored series. v0.1.43+142 §4: hide-when-empty like the
          // _ChartCard precedent (honesty rule: no widget without flowing
          // data) instead of the old permanent "no data" placeholder.
          return const SizedBox.shrink();
        }
        final (bins, fromSeries) = data;
        double maxAbs = 1;
        for (final b in bins) {
          if (b.abs() > maxAbs) maxAbs = b.abs();
        }
        return Card(
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    const Icon(Icons.bolt,
                        size: 14, color: Colors.greenAccent),
                    const SizedBox(width: 6),
                    Text(S.of('trip.power_profile').toUpperCase(),
                        style: const TextStyle(
                            fontSize: 11,
                            letterSpacing: 1.5,
                            color: Colors.grey)),
                    const Spacer(),
                    Text('kW',
                        style: TextStyle(
                            fontSize: 10, color: Colors.grey.shade500)),
                  ],
                ),
                // v0.1.43+142 §4 (Q3): source caption under the title —
                // ONLY on the series branch, so live charts look exactly
                // as before (the +128 chart_src_snapshots precedent).
                if (fromSeries)
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Text(S.of('trip.chart_src_series'),
                        style: TextStyle(
                            fontSize: 10, color: Colors.grey.shade600)),
                  ),
                const SizedBox(height: 8),
                SizedBox(
                  height: 160,
                  child: BarChart(
                    BarChartData(
                      minY: -maxAbs,
                      maxY: maxAbs,
                      alignment: BarChartAlignment.spaceBetween,
                      barTouchData: BarTouchData(enabled: false),
                      gridData: FlGridData(
                        show: true,
                        drawVerticalLine: false,
                        getDrawingHorizontalLine: (v) => FlLine(
                          color: v == 0
                              ? Colors.grey.shade600
                              : Colors.grey.shade800,
                          strokeWidth: v == 0 ? 1 : 0.5,
                        ),
                      ),
                      titlesData: FlTitlesData(
                        rightTitles: const AxisTitles(
                            sideTitles: SideTitles(showTitles: false)),
                        topTitles: const AxisTitles(
                            sideTitles: SideTitles(showTitles: false)),
                        bottomTitles: const AxisTitles(
                            sideTitles: SideTitles(showTitles: false)),
                        leftTitles: AxisTitles(
                          sideTitles: SideTitles(
                            showTitles: true,
                            reservedSize: 34,
                            getTitlesWidget: (v, _) => Text(
                              v.toStringAsFixed(0),
                              style: const TextStyle(
                                  fontSize: 10, color: Colors.grey),
                            ),
                          ),
                        ),
                      ),
                      borderData: FlBorderData(show: false),
                      barGroups: [
                        for (var i = 0; i < bins.length; i++)
                          BarChartGroupData(x: i, barRods: [
                            BarChartRodData(
                              toY: bins[i],
                              width: 3,
                              color: bins[i] >= 0
                                  ? Colors.greenAccent
                                  : Colors.lightBlueAccent,
                              borderRadius: BorderRadius.zero,
                            ),
                          ]),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    const Icon(Icons.arrow_upward,
                        size: 12, color: Colors.greenAccent),
                    Text(' ${S.of('trip.traction')}   ',
                        style: TextStyle(
                            fontSize: 10, color: Colors.grey.shade400)),
                    const Icon(Icons.arrow_downward,
                        size: 12, color: Colors.lightBlueAccent),
                    Text(' ${S.of('trip.regen')}',
                        style: TextStyle(
                            fontSize: 10, color: Colors.grey.shade400)),
                    const Spacer(),
                    if (regenKwh != null)
                      Text(
                        S
                            .of('trip.regen_recovered')
                            .replaceFirst(
                                '{kwh}', regenKwh.toStringAsFixed(2))
                            .replaceFirst(
                                '{peak}',
                                peakRegen != null
                                    ? peakRegen.abs().toStringAsFixed(0)
                                    : '—'),
                        style: const TextStyle(
                            fontSize: 11, color: Colors.lightBlueAccent),
                      ),
                  ],
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}
