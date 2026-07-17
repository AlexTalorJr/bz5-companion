import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../services/locale_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../l10n/strings.dart';
import 'dashboard.dart' show kAppVersion;

/// About screen: app identity, disclaimer and the APP info card (which
/// doubles as the 15-tap Advanced unlock). v0.1.32+131: the development
/// narrative and the hardcoded BZ5 pack/cell specification cards are gone
/// — the app is multi-model (BZ5/BZ3) and those numbers were only ever
/// true for one of them.
class AboutScreen extends StatelessWidget {
  const AboutScreen({super.key});

  @override
  Widget build(BuildContext context) {
    // v0.1.29+60: re-render on language switch (per-screen subscription).
    // Full About l10n lands in +61 — the +59 adv-unlock strings already
    // resolve via S.of, so the screen must hold the rebuild contract now.
    context.watch<LocaleService>();
    return Scaffold(
      appBar: AppBar(title: Text(S.of('about.title'))),
      body: ListView(
        padding: const EdgeInsets.all(16),
        // v0.1.29+59: _AppInfoCard became stateful (hidden-Advanced tap
        // counter) — its constructor stays const, so the const list is
        // still valid (the State object is created at element-mount,
        // not in the constructor).
        children: const [
          _IntroCard(),
          SizedBox(height: 16),
          _DisclaimerCard(),
          SizedBox(height: 16),
          _AppInfoCard(),
        ],
      ),
    );
  }
}

class _IntroCard extends StatelessWidget {
  const _IntroCard();

  @override
  Widget build(BuildContext context) {
    return Card(
      color: Colors.blueGrey.shade900,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Row(
              children: [
                Icon(Icons.info_outline,
                    color: Colors.lightBlueAccent, size: 22),
                SizedBox(width: 8),
                Text('BZ5 Companion',
                    style: TextStyle(
                        fontSize: 18, fontWeight: FontWeight.w500)),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              S.of('about.intro.body'),
              style: const TextStyle(
                  fontSize: 13, color: Colors.white70, height: 1.4),
            ),
          ],
        ),
      ),
    );
  }
}

class _DisclaimerCard extends StatelessWidget {
  const _DisclaimerCard();

  @override
  Widget build(BuildContext context) {
    return Card(
      color: Colors.orange.shade900.withValues(alpha: 0.3),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Icon(Icons.warning_amber_rounded,
                color: Colors.orangeAccent, size: 22),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(S.of('about.disclaimer.label'),
                      style: const TextStyle(
                          fontSize: 12,
                          letterSpacing: 1.5,
                          color: Colors.orangeAccent)),
                  const SizedBox(height: 8),
                  Text(
                    S.of('about.disclaimer.body'),
                    style: const TextStyle(
                        fontSize: 12, height: 1.5, color: Colors.white70),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// v0.1.29+59: the APP card doubles as the hidden unlock for the
/// Advanced research tools in Settings (Android developer-options
/// pattern): 15 taps set the persistent `advanced_unlocked` pref. A
/// countdown snackbar appears for the last 5 taps so the gesture is
/// discoverable-by-intent but not by accident. Already-unlocked state
/// is loaded once in initState; further taps are then no-ops.
class _AppInfoCard extends StatefulWidget {
  const _AppInfoCard();

  @override
  State<_AppInfoCard> createState() => _AppInfoCardState();
}

class _AppInfoCardState extends State<_AppInfoCard> {
  static const int _unlockTaps = 15;
  int _taps = 0;
  bool _unlocked = false;

  @override
  void initState() {
    super.initState();
    SharedPreferences.getInstance().then((prefs) {
      if (!mounted) return;
      setState(() {
        _unlocked = prefs.getBool('advanced_unlocked') ?? false;
      });
    });
  }

  Future<void> _onTap() async {
    if (_unlocked) return;
    _taps++;
    final left = _unlockTaps - _taps;
    final messenger = ScaffoldMessenger.of(context);
    if (left <= 0) {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool('advanced_unlocked', true);
      if (!mounted) return;
      setState(() => _unlocked = true);
      messenger.hideCurrentSnackBar();
      messenger.showSnackBar(
        SnackBar(content: Text(S.of('about.adv.unlocked'))),
      );
    } else if (left <= 5) {
      messenger.hideCurrentSnackBar();
      messenger.showSnackBar(
        SnackBar(
          content: Text(
              S.of('about.adv.progress').replaceFirst('{n}', '$left')),
          duration: const Duration(milliseconds: 700),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Card(
      color: Colors.grey.shade900,
      child: InkWell(
        onTap: _onTap,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(S.of('about.app.label'),
                  style: const TextStyle(
                      fontSize: 12,
                      letterSpacing: 1.5,
                      color: Colors.grey)),
              const SizedBox(height: 8),
              // v0.1.29+94: show the build version so "which version is on
              // the car?" is answerable on-device (no more guessing whether
              // a patch actually installed). Single source = kAppVersion.
              _SpecRow(S.of('about.spec.version'), kAppVersion),
              _SpecRow(S.of('about.spec.source'),
                  'github.com/AlexTalorJr/bz5-companion'),
              _SpecRow(S.of('about.spec.license'), 'MIT'),
              _SpecRow(S.of('about.spec.hardware'), 'OBD2 Bluetooth adapter'),
            ],
          ),
        ),
      ),
    );
  }
}

// ─────────────────────────── Helper widgets ──────────────────────────────

class _SpecRow extends StatelessWidget {
  final String label;
  final String value;
  const _SpecRow(this.label, this.value);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 170,
            child: Text(label,
                style: const TextStyle(
                    fontSize: 13, color: Colors.grey, height: 1.4)),
          ),
          Expanded(
            child: Text(value,
                style: const TextStyle(
                    fontSize: 13,
                    color: Colors.white,
                    height: 1.4,
                    fontFeatures: [FontFeature.tabularFigures()])),
          ),
        ],
      ),
    );
  }
}
