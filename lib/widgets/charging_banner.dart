// v0.1.29+56: Charging session UX — banner + full-screen route + auto-push.
//
// Design decision (owner-approved, 2026-06-10): charging does NOT get a
// permanent navigation tab. A tab that's useful only while a cable is
// plugged in would sit dead 95% of the time. Instead:
//
//   1. While [ConnectionService.isCharging] is true, a compact sticky
//      banner appears at the top of EVERY tab (both phone and head-unit
//      scaffolds): "⚡ Charging 48 kW • 67% • ~25 min".
//   2. Tapping the banner pushes the full-screen ChargingViewWide as a
//      route. Back button returns to wherever the user was; the banner
//      stays for the whole session, so "accidentally closed the
//      auto-popup" is recovered with one tap.
//   3. Auto-push (once per session). Head unit (v0.2.7+206, owner
//      decision 2026-08-14): fires from ANY tab — charging implies the
//      car is parked, so "plugged the cable in, screen reacted" wins
//      over "don't yank the user away". Phone: Dashboard tab only,
//      as before.
//   4. When the session ends, an open charging route pops itself and
//      the banner disappears.
//
// History note: ChargingViewWide (v0.1.26) was originally activated by
// conditional substitution inside DriverViewWideScreen. That wiring was
// silently lost in a later refactor — the screen became an orphan while
// its data plumbing (chargingHistory, chargingPhase, etaToFullSeconds)
// kept running in ConnectionService. The banner approach is deliberately
// LOUD in the widget tree (a visible wrapper at scaffold level) so a
// future refactor can't drop it without someone noticing the diff.

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../l10n/strings.dart';
import '../services/connection.dart';
import '../services/hal_telemetry_service.dart';
import '../services/speed_profile_service.dart';
import '../theme/atlas_tokens.dart';
import '../screens/wide/charging_view_wide.dart';

/// Wraps a scaffold body. Shows the charging banner above [child] while
/// a charging session is active. Handles the once-per-session auto-push
/// when [autoPushWhenVisible] is true (Driver tab passes true; all other
/// tabs false).
class ChargingAwareBody extends StatefulWidget {
  final Widget child;

  /// True only for the tab where auto-push is allowed (Driver / Вождение).
  /// The banner itself shows on every tab regardless.
  final bool autoPushWhenVisible;

  /// v0.1.62+161 (§6.11): the sticky summary plate lives here, next to
  /// the charging banner — «над контентом ЛЮБОГО экрана». Set false on
  /// the tab that already hosts the summary card itself, so the driver
  /// never sees two prompts for one fact (the same conjunct the nav
  /// badge uses: `_index != <Замеры>`).
  final bool showAtlasPlate;

  /// Plate tap → the «Замеры» tab. The scaffold owns the tab index, so
  /// it hands the jump down instead of the plate guessing a navigator.
  final VoidCallback? onPlateTap;

  const ChargingAwareBody({
    super.key,
    required this.child,
    this.autoPushWhenVisible = false,
    this.showAtlasPlate = false,
    this.onPlateTap,
  });

  @override
  State<ChargingAwareBody> createState() => _ChargingAwareBodyState();
}

class _ChargingAwareBodyState extends State<ChargingAwareBody> {
  /// Session-scoped guard: auto-push fired for the current charging
  /// session. Reset when isCharging goes false. Static so that the
  /// guard is shared across ALL ChargingAwareBody instances (phone tabs
  /// + HU tabs each wrap their own body — without a shared guard, each
  /// wrapper would fire its own push).
  static bool _autoPushedThisSession = false;

  /// Tracks whether WE pushed a charging route that is still open, so
  /// the end-of-session auto-pop doesn't pop someone else's route.
  static bool _chargingRouteOpen = false;

  @override
  Widget build(BuildContext context) {
    final svc = context.watch<ConnectionService>();
    final charging = svc.isCharging;

    if (!charging) {
      // Session over: reset the auto-push guard so the next session
      // can fire again. Auto-pop an open charging route.
      if (_autoPushedThisSession || _chargingRouteOpen) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          _autoPushedThisSession = false;
          if (_chargingRouteOpen && mounted) {
            _chargingRouteOpen = false;
            // Pop only if the charging route is actually on top.
            // maybePop respects WillPopScope and does nothing if the
            // navigator has nothing to pop.
            Navigator.of(context).popUntil((route) {
              return route.settings.name != _kChargingRouteName;
            });
          }
        });
      }
      return _withPlate(null);
    }

    // Charging active → maybe auto-push (once, only from the allowed tab).
    if (widget.autoPushWhenVisible && !_autoPushedThisSession) {
      _autoPushedThisSession = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && svc.isCharging) _openChargingScreen(context);
      });
    }

    return _withPlate(
        _ChargingBanner(onTap: () => _openChargingScreen(context)));
  }

  /// One layout for both states. When neither the banner nor the plate
  /// has anything to say the tree is the bare child, exactly as before
  /// +161 — no Column, no Expanded, zero layout delta for every screen
  /// that never sees either.
  Widget _withPlate(Widget? banner) {
    if (banner == null && !widget.showAtlasPlate) return widget.child;
    return Column(
      children: [
        if (banner != null) banner,
        // Charging on top when both are up (§6.11).
        if (widget.showAtlasPlate) AtlasSummaryPlate(onTap: widget.onPlateTap),
        Expanded(child: widget.child),
      ],
    );
  }

  static const _kChargingRouteName = '/charging-session';

  void _openChargingScreen(BuildContext context) {
    if (_chargingRouteOpen) return; // already open — don't stack
    _chargingRouteOpen = true;
    Navigator.of(context)
        .push(MaterialPageRoute(
          settings: const RouteSettings(name: _kChargingRouteName),
          builder: (_) => const _ChargingSessionScreen(),
        ))
        .whenComplete(() => _chargingRouteOpen = false);
  }
}

/// The compact sticky banner. Amber accent, one line, tappable.
class _ChargingBanner extends StatelessWidget {
  final VoidCallback onTap;
  const _ChargingBanner({required this.onTap});

  @override
  Widget build(BuildContext context) {
    final svc = context.watch<ConnectionService>();
    final kw = svc.chargingPowerKw;  // non-nullable; 0.0 while calibrating
    final soc = svc.readNumeric('790', '0005');
    final etaSec = svc.etaToFullSeconds;

    final parts = <String>[];
    if (kw > 0) {
      parts.add('${kw.toStringAsFixed(1)} kW');
    }
    if (soc != null) {
      parts.add('${soc.toStringAsFixed(0)}%');
    }
    if (etaSec != null && etaSec > 0) {
      final m = (etaSec / 60).round();
      parts.add(m >= 60 ? '~${m ~/ 60}h ${m % 60}m' : '~${m}m');
    }
    final detail = parts.isEmpty ? S.of('chg.starting') : parts.join(' • ');

    return Material(
      color: Colors.amber.shade900.withValues(alpha: 0.25),
      child: InkWell(
        onTap: onTap,
        child: SafeArea(
          bottom: false,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
            child: Row(
              children: [
                const Icon(Icons.bolt, color: Colors.amber, size: 20),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    S.of('chg.banner').replaceFirst('{detail}', detail),
                    style: const TextStyle(
                      fontWeight: FontWeight.w500,
                      color: Colors.amber,
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                const Icon(Icons.chevron_right, color: Colors.amber, size: 20),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// v0.1.62+161 «липкая плашка итогов» (SPEC.md v1.1 §6.11, mockup [5f]).
///
/// Why it exists: the 8 dp borderless badge of +160 was physically
/// invisible in the field. The plate is the loud half of the pair — the
/// badge stays (14 dp + 2 dp outline since this patch) and both die on
/// the same «Ок».
///
/// Existence conditions, all conjuncts (so «в движении не существует» is
/// true BY EXPRESSION, not by a hidden branch — инвариант И1):
///   • gear P (the isParked precedent — HAL when fresh, else UDS 791/0009)
///   • at least one unrevealed reveal event
/// The trip line reads from the live ledger; on a phone there is no gear
/// at all, so the plate is head-unit-only in practice — consistent with
/// §11 («микро-лут живёт только в локальном состоянии ГУ»).
class AtlasSummaryPlate extends StatelessWidget {
  final VoidCallback? onTap;
  const AtlasSummaryPlate({super.key, this.onTap});

  @override
  Widget build(BuildContext context) {
    final hal = context.watch<HalTelemetryService>();
    final svc = context.watch<ConnectionService>();
    final gear =
        hal.useHalForGear ? hal.halGear : svc.readNumeric('791', '0009');
    final isParked = gear != null && gear.toInt() == 1;
    final unrevealed =
        context.select<SpeedProfileService, int>((s) => s.unrevealedCount);
    if (!isParked || unrevealed <= 0) return const SizedBox.shrink();

    final sp = context.read<SpeedProfileService>();
    final t = sp.currentPackTempC;
    final km = sp.atlasSessionDistKm.toStringAsFixed(1);
    final sub = t == null
        ? S.of('measure.card_trip_nt').replaceFirst('{km}', km)
        : S
            .of('measure.card_trip')
            .replaceFirst('{km}', km)
            .replaceFirst('{t}', '${t.round()}');

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 0),
      child: Material(
        color: AtlasTokens.revealBg,
        borderRadius: BorderRadius.circular(14),
        child: InkWell(
          borderRadius: BorderRadius.circular(14),
          onTap: onTap,
          child: Container(
            height: 56,
            decoration: BoxDecoration(
              border: Border.all(color: AtlasTokens.revealBorder),
              borderRadius: BorderRadius.circular(14),
            ),
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Row(
              children: [
                const Icon(Icons.inventory_2,
                    size: 20, color: AtlasTokens.success),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        S
                            .of('measure.plate_title')
                            .replaceFirst('{n}', '$unrevealed'),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                            fontSize: 13.5,
                            fontWeight: FontWeight.w500,
                            color: AtlasTokens.t100),
                      ),
                      Text(
                        sub,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                            fontSize: 11, color: AtlasTokens.t50),
                      ),
                    ],
                  ),
                ),
                const Icon(Icons.chevron_right,
                    size: 20, color: AtlasTokens.t40),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Full-screen charging session route. Wraps ChargingViewWide with an
/// AppBar (so there's always an explicit back affordance) and shows a
/// session-over state if charging stops while the screen is open and
/// the auto-pop hasn't fired yet.
class _ChargingSessionScreen extends StatelessWidget {
  const _ChargingSessionScreen();

  @override
  Widget build(BuildContext context) {
    final svc = context.watch<ConnectionService>();
    return Scaffold(
      appBar: AppBar(
        title: Text(S.of('chg.session_title')),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () => Navigator.of(context).maybePop(),
        ),
      ),
      body: svc.isCharging
          ? const ChargingViewWide()
          : Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const Icon(Icons.power_off, size: 64, color: Colors.grey),
                  const SizedBox(height: 16),
                  Text(S.of('chg.session_ended'),
                      style: const TextStyle(fontSize: 18, color: Colors.grey)),
                ],
              ),
            ),
    );
  }
}
