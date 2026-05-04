import 'package:flutter/material.dart';

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
    return Scaffold(
      appBar: AppBar(title: const Text('About / Pack Specification')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: const [
          _IntroCard(),
          SizedBox(height: 16),
          _PackSpecCard(),
          SizedBox(height: 16),
          _CellSpecCard(),
          SizedBox(height: 16),
          _DidSourcesCard(),
          SizedBox(height: 16),
          _ExperimentsCard(),
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

class _DidSourcesCard extends StatelessWidget {
  const _DidSourcesCard();

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
                Icon(Icons.code,
                    color: Colors.lightBlueAccent, size: 22),
                SizedBox(width: 8),
                Text('DATA SOURCES (DIDs)',
                    style: TextStyle(
                        fontSize: 12,
                        letterSpacing: 1.5,
                        color: Colors.grey)),
              ],
            ),
            const SizedBox(height: 12),
            const Text(
              'BZ5 uses non-standard ECU addresses (CarScanner does not work). '
              'Discovered via brute-force DID sweep:',
              style: TextStyle(fontSize: 12, height: 1.4, color: Colors.white70),
            ),
            const SizedBox(height: 12),
            const _DidRow('790 → 798', 'BMS Master',
                'SOC, SOH, cells, temps, charge counter'),
            const _DidRow('791 → 799', 'VCU',
                'gear, odometer, parking pawl, VIN'),
            const _DidRow('740 → 748', 'Pack Monitor',
                'pack voltage (filtered/instant/avg)'),
            const _DidRow('782 → 78A', 'OBC', 'on-board charger'),
            const _DidRow('752, 753', 'BMS slaves',
                'subpack monitors (limited UDS access)'),
            const _DidRow('744, 745', 'Pack Monitor 2/3',
                'duplicate views of pack stats'),
            const Divider(height: 20),
            const Text(
              'Key DIDs — Master 790:',
              style: TextStyle(
                  fontSize: 11, color: Colors.grey, letterSpacing: 0.5),
            ),
            const SizedBox(height: 4),
            const _CompactDidRow('0x0005', 'SOC %'),
            const _CompactDidRow('0x0029', 'SOH %'),
            const _CompactDidRow('0x002B / 0x002D', 'global min / max cell mV'),
            const _CompactDidRow('0x002C / 0x002E', 'min / max cell index (0..135)'),
            const _CompactDidRow('0x002F', 'battery temp (offset −40)'),
            const _CompactDidRow('0x016D – 0x01BB',
                'per-module data (8 DIDs × 10 modules)'),
            const _CompactDidRow('0x0B00', 'charge counter'),
            const _CompactDidRow('0x0B02', 'cycle count'),
            const _CompactDidRow('0x0B03', 'total cells (= 136)'),
            const _CompactDidRow('0x0A07', 'module count (= 10)'),
            const SizedBox(height: 8),
            const Text(
              'Pack Monitor 740:',
              style: TextStyle(
                  fontSize: 11, color: Colors.grey, letterSpacing: 0.5),
            ),
            const SizedBox(height: 4),
            const _CompactDidRow('0x0014', 'pack V instant (× 0.025)'),
            const _CompactDidRow('0x0022', 'pack V filtered (× 0.025) ★'),
          ],
        ),
      ),
    );
  }
}

class _ExperimentsCard extends StatelessWidget {
  const _ExperimentsCard();

  @override
  Widget build(BuildContext context) {
    return Card(
      color: Colors.deepPurple.shade900.withValues(alpha: 0.4),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Row(
              children: [
                Icon(Icons.science_outlined,
                    color: Colors.purpleAccent, size: 22),
                SizedBox(width: 8),
                Text('FUTURE EXPERIMENTS',
                    style: TextStyle(
                        fontSize: 12,
                        letterSpacing: 1.5,
                        color: Colors.grey)),
              ],
            ),
            const SizedBox(height: 12),
            _ExperimentItem(
              title: 'Independent SOH calculation',
              text:
                  'The BMS reports SOH via 0x0029 (currently 98%). An '
                  'independent estimate could be computed by tracking voltage '
                  'sag under known discharge load (if a current DID is found) '
                  'or by tracking ΔSOC vs Δcharge-counter over many cycles. '
                  'Useful as a cross-check on BMS-reported value.',
            ),
            _ExperimentItem(
              title: 'Charge counter calibration (0x0B00)',
              text:
                  'Currently calibrated at ~460 Wh/unit from a single charge '
                  'session. To verify, charge from a metered station: record '
                  'kWh delivered, ΔSOC, and Δ0x0B00 — compute true Wh/unit. '
                  'Counter behavior at idle (monotonic decrease) suggests it '
                  'may not be a pure energy counter.',
            ),
            _ExperimentItem(
              title: 'Pack-V scale verification',
              text:
                  'Scale 0.025 V/LSB inferred from theoretical match at '
                  '81% SOC. Verify at low (10-20%) and high (95%+) SOC where '
                  'expected voltage range is well-known.',
            ),
            _ExperimentItem(
              title: 'M6 temperature sensor status',
              text:
                  'M6 returns 0xFF on all 4 temperature DIDs. Likely by-design '
                  '(the only module without sensors) but could be a real fault. '
                  'Read DTCs (UDS service 0x19) to verify — if there is a code '
                  'related to M6 temp sensor, the sensor is broken.',
            ),
            _ExperimentItem(
              title: 'Per-module cell semantics',
              text:
                  'Per-module DIDs (0x016D, 0x016F per module) currently '
                  'interpreted as min/max of cells in that module. To verify, '
                  'compare individual DID values vs global min/max (0x002B, '
                  '0x002D) over time — if module readings always bracket the '
                  'globals, interpretation is correct.',
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

class _AppInfoCard extends StatelessWidget {
  const _AppInfoCard();

  @override
  Widget build(BuildContext context) {
    return Card(
      color: Colors.grey.shade900,
      child: const Padding(
        padding: EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('APP',
                style: TextStyle(
                    fontSize: 12,
                    letterSpacing: 1.5,
                    color: Colors.grey)),
            SizedBox(height: 8),
            _SpecRow('Source code',
                'github.com/AlexTalorJr/bz5-companion'),
            _SpecRow('License', 'MIT'),
            _SpecRow('Hardware', 'ELM327 BLE (e.g., Vgate iCar Pro)'),
            _SpecRow('Protocol', 'ISO 15765-4 CAN 11/500'),
          ],
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

class _CompactDidRow extends StatelessWidget {
  final String did;
  final String description;
  const _CompactDidRow(this.did, this.description);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 1),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 130,
            child: Text(did,
                style: const TextStyle(
                    fontSize: 11,
                    color: Colors.lightBlueAccent,
                    fontFeatures: [FontFeature.tabularFigures()])),
          ),
          Expanded(
            child: Text(description,
                style: const TextStyle(
                    fontSize: 11, color: Colors.white70, height: 1.4)),
          ),
        ],
      ),
    );
  }
}

class _ExperimentItem extends StatelessWidget {
  final String title;
  final String text;
  const _ExperimentItem({required this.title, required this.text});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('• $title',
              style: const TextStyle(
                  fontSize: 13, fontWeight: FontWeight.w500)),
          const SizedBox(height: 2),
          Padding(
            padding: const EdgeInsets.only(left: 12),
            child: Text(text,
                style: const TextStyle(
                    fontSize: 12, color: Colors.white70, height: 1.4)),
          ),
        ],
      ),
    );
  }
}
