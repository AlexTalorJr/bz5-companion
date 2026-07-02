import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../services/locale_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../l10n/strings.dart';
import 'dashboard.dart' show kAppVersion;

/// v0.1.5: About screen — verified Toyota BZ5 battery pack specification
/// derived from reverse engineering + cross-validation with manufacturer specs.
///
/// Math validation:
///   136 cells × 150 Ah × 3.2 V = 65.280 kWh (exact match to marketing spec)
///   136 cells × 3.31 V (LFP @ 81% SOC) = 450 V (exact match to measured)
///
/// Both constraints satisfied simultaneously → high confidence in pack
/// configuration.
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
          _PackSpecCard(),
          SizedBox(height: 16),
          _CellSpecCard(),
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
      child: const Padding(
        padding: EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.info_outline,
                    color: Colors.lightBlueAccent, size: 22),
                SizedBox(width: 8),
                Text('BZ5 Companion',
                    style: TextStyle(
                        fontSize: 18, fontWeight: FontWeight.w500)),
              ],
            ),
            SizedBox(height: 8),
            Text(
              'Open-source companion app for Toyota BZ5 (FAW-Toyota 2025).\n'
              'Reads the high-voltage battery pack via the OBD-II port using '
              'an ELM327 BLE adapter. The pack specifications below were '
              'reverse-engineered from CAN diagnostic responses and '
              'cross-validated with manufacturer cell data.',
              style: TextStyle(fontSize: 13, color: Colors.white70, height: 1.4),
            ),
          ],
        ),
      ),
    );
  }
}

class _PackSpecCard extends StatelessWidget {
  const _PackSpecCard();

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Row(
              children: [
                Icon(Icons.battery_charging_full,
                    color: Colors.greenAccent, size: 22),
                SizedBox(width: 8),
                Text('PACK SPECIFICATION',
                    style: TextStyle(
                        fontSize: 12,
                        letterSpacing: 1.5,
                        color: Colors.grey)),
              ],
            ),
            const SizedBox(height: 12),
            const _SpecRow('Total energy', '65.28 kWh'),
            const _SpecRow('Configuration', '136S × 1P (all in series)'),
            const _SpecRow('Total cells', '136'),
            const _SpecRow('Modules (CMU groups)', '10'),
            const _SpecRow('Nominal pack voltage',
                '435.2 V (3.2 V × 136)'),
            const _SpecRow('Operating range',
                '~410 V (10% SOC) – 477 V (100% SOC)'),
            const _SpecRow('Resting at 81% SOC',
                '~450 V (measured 2026-05-03)'),
            const Divider(height: 24),
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: Colors.green.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(6),
              ),
              child: const Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(Icons.check_circle,
                      color: Colors.green, size: 18),
                  SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'Math check: 136 × 150 Ah × 3.2 V = 65.280 kWh — '
                      'exact match to marketing spec.',
                      style: TextStyle(fontSize: 12, height: 1.4),
                    ),
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

class _CellSpecCard extends StatelessWidget {
  const _CellSpecCard();

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Row(
              children: [
                Icon(Icons.memory,
                    color: Colors.amberAccent, size: 22),
                SizedBox(width: 8),
                Text('CELL SPECIFICATION',
                    style: TextStyle(
                        fontSize: 12,
                        letterSpacing: 1.5,
                        color: Colors.grey)),
              ],
            ),
            const SizedBox(height: 12),
            const _SpecRow('Brand / Model', 'BYD C104F'),
            const _SpecRow('Type', 'LFP (LiFePO₄) blade cell'),
            const _SpecRow('Nominal voltage', '3.2 V'),
            const _SpecRow('Capacity', '150 Ah'),
            const _SpecRow('Energy per cell', '480 Wh'),
            const _SpecRow('Dimensions',
                '960 × 90 × 13.5 mm'),
            const _SpecRow('Weight', '2.61 kg'),
            const _SpecRow('Operating temperature', '−10 to 50 °C'),
            const _SpecRow('Max charge / discharge',
                '200 A / 200 A (1.33C)'),
            const _SpecRow('Cycle life', '3000+ cycles'),
            const SizedBox(height: 8),
            Text(
              'Pack mass (cells only): ${136 * 2.61} kg',
              style: const TextStyle(
                  fontSize: 12, color: Colors.grey, height: 1.4),
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
      child: const Padding(
        padding: EdgeInsets.all(16),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(Icons.warning_amber_rounded,
                color: Colors.orangeAccent, size: 22),
            SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('DISCLAIMER',
                      style: TextStyle(
                          fontSize: 12,
                          letterSpacing: 1.5,
                          color: Colors.orangeAccent)),
                  SizedBox(height: 8),
                  Text(
                    'This app is reverse-engineered from CAN responses and is '
                    'NOT an official Toyota or BYD product. While the pack '
                    'configuration is mathematically validated, individual DID '
                    'interpretations are inferences and may be incorrect. Use '
                    'this app for monitoring purposes — do NOT rely on its '
                    'numbers for safety-critical decisions or warranty '
                    'discussions with Toyota service.',
                    style: TextStyle(
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
              const Text('APP',
                  style: TextStyle(
                      fontSize: 12,
                      letterSpacing: 1.5,
                      color: Colors.grey)),
              const SizedBox(height: 8),
              // v0.1.29+94: show the build version so "which version is on
              // the car?" is answerable on-device (no more guessing whether
              // a patch actually installed). Single source = kAppVersion.
              _SpecRow('Version', kAppVersion),
              const _SpecRow('Source code',
                  'github.com/AlexTalorJr/bz5-companion'),
              const _SpecRow('License', 'MIT'),
              const _SpecRow('Hardware', 'OBD2 Bluetooth adapter'),
              const _SpecRow('Protocol', 'ISO 15765-4 CAN 11/500'),
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

class _DidRow extends StatelessWidget {
  final String address;
  final String name;
  final String description;
  const _DidRow(this.address, this.name, this.description);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 90,
            child: Text(address,
                style: const TextStyle(
                    fontSize: 12,
                    color: Colors.lightBlueAccent,
                    fontFeatures: [FontFeature.tabularFigures()])),
          ),
          SizedBox(
            width: 120,
            child: Text(name,
                style: const TextStyle(
                    fontSize: 12, fontWeight: FontWeight.w500)),
          ),
          Expanded(
            child: Text(description,
                style: const TextStyle(
                    fontSize: 12, color: Colors.grey, height: 1.4)),
          ),
        ],
      ),
    );
  }
}

