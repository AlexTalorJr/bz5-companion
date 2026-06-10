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
//   3. Auto-push (once per session): if the user is sitting on the
//      Driver tab when charging starts, the charging screen opens by
//      itself — the "plugged the cable in, screen reacted" scenario.
//      From any other tab we don't yank the user away.
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

import '../services/connection.dart';
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

  const ChargingAwareBody({
    super.key,
    required this.child,
    this.autoPushWhenVisible = false,
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
      return widget.child;
    }

    // Charging active → maybe auto-push (once, only from the allowed tab).
    if (widget.autoPushWhenVisible && !_autoPushedThisSession) {
      _autoPushedThisSession = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && svc.isCharging) _openChargingScreen(context);
      });
    }

    return Column(
      children: [
        _ChargingBanner(onTap: () => _openChargingScreen(context)),
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
    final detail = parts.isEmpty ? 'starting…' : parts.join(' • ');

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
                    'Charging • $detail',
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
        title: const Text('Charging session'),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () => Navigator.of(context).maybePop(),
        ),
      ),
      body: svc.isCharging
          ? const ChargingViewWide()
          : const Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.power_off, size: 64, color: Colors.grey),
                  SizedBox(height: 16),
                  Text('Charging session ended',
                      style: TextStyle(fontSize: 18, color: Colors.grey)),
                ],
              ),
            ),
    );
  }
}
