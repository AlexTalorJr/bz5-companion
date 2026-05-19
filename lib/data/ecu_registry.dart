/// v0.1.2: добавлены module temperatures (DID 0x0171/0x0173 ... 0x01B9/0x01BB)
/// Структура каждого модуля 0x016D-0x01B7: 8 DID-ов
///   +0 (2 байта): Cell A voltage (mV)
///   +1: 0x00 placeholder
///   +2 (2 байта): Cell B voltage (mV)
///   +3: 0x00 placeholder
///   +4 (1 байт): Temp sensor 1, offset −40 °C
///   +5: 0x00 placeholder
///   +6 (1 байт): Temp sensor 2, offset −40 °C
///   +7 (1 байт): module flag/state (0..13, semantic unknown)

enum DidCategory {
  identity, battery, cells, packVoltage, charging,
  drive, status, counter, thermal, gps, unknown,
  // v0.1.21:
  soc,     // any SOC-bearing DID (raw or precise)
  dynamic, // changes under driving load (speed, motor signals)
}

class DidSpec {
  final String did;
  final String name;
  final String unit;
  final double scale;
  final double offset;
  final DidCategory category;
  final int? expectedBytes;
  final String? notes;

  /// v0.1.21: optional sanity range for **raw** (pre-scale, pre-offset)
  /// integer value. If a livelog read returns a value outside this
  /// range, the entry is recorded with errorCode='SANITY:...' instead
  /// of as a real reading. Two failure modes this catches:
  ///   1. BMS returns 0xFFFF (or other all-ones) under heavy load to
  ///      signal "data not available" — we saw this on 790/0x0015
  ///      during session 13 heavy regen (7 cycles of 1638.4 V).
  ///   2. ELM frame misalignment producing a payload from a different
  ///      DID that happens to parse but is wildly out of range.
  final int? sanityRawMin;
  final int? sanityRawMax;

  const DidSpec({
    required this.did,
    required this.name,
    this.unit = '',
    this.scale = 1.0,
    this.offset = 0.0,
    this.category = DidCategory.unknown,
    this.expectedBytes,
    this.notes,
    this.sanityRawMin,
    this.sanityRawMax,
  });

  /// Returns null if value passes sanity, or a short error tag otherwise.
  String? checkSanityRaw(int raw) {
    // Universal: 0xFFFF / 0xFFFFFFFF and friends are UDS "not available"
    // markers for u16/u32 DIDs.
    if (expectedBytes == 2 && raw == 0xFFFF) return 'SANITY:NA';
    if (expectedBytes == 4 && raw == 0xFFFFFFFF) return 'SANITY:NA';
    if (sanityRawMin != null && raw < sanityRawMin!) {
      return 'SANITY:LOW:$raw';
    }
    if (sanityRawMax != null && raw > sanityRawMax!) {
      return 'SANITY:HIGH:$raw';
    }
    return null;
  }
}

class EcuSpec {
  final String txId;
  final String rxId;
  final String name;
  final String description;
  final List<DidSpec> dids;

  const EcuSpec({
    required this.txId,
    required this.rxId,
    required this.name,
    required this.description,
    required this.dids,
  });
}

const bmsEcu = EcuSpec(
  txId: '790', rxId: '798', name: 'BMS',
  description: 'Battery Management System',
  dids: [
    DidSpec(did: '0105', name: 'Part number', category: DidCategory.identity),
    DidSpec(did: '0005', name: 'SOC', unit: '%', category: DidCategory.soc, sanityRawMin: 0, sanityRawMax: 100),
    DidSpec(did: '0029', name: 'SOH', unit: '%', category: DidCategory.battery, sanityRawMin: 0, sanityRawMax: 100),
    DidSpec(did: '002F', name: 'Battery temp', unit: '°C', offset: -40, category: DidCategory.thermal, sanityRawMin: 0, sanityRawMax: 200),
    // v0.1.21: sanity ranges added. LFP cell physical envelope 2000-3700 mV.
    DidSpec(did: '002B', name: 'Cell V min', unit: 'mV', expectedBytes: 2, category: DidCategory.cells, sanityRawMin: 2000, sanityRawMax: 3700),
    DidSpec(did: '002D', name: 'Cell V max', unit: 'mV', expectedBytes: 2, category: DidCategory.cells, sanityRawMin: 2000, sanityRawMax: 3700),
    // v0.1.2: pack voltage realtime — DEPRECATED INTERPRETATION
    // v0.1.8 update: this DID is actually HV bus voltage (downstream of
    // main contactor), NOT pack voltage. Pack V comes from 740/0x0022.
    // Scale corrected 0.02 → 0.025 based on Ready-state measurement
    // 2026-05-15 (raw 0x42FE × 0.025 = 428.75V matches predicted bus V).
    // Category 'packVoltage' kept for backward compat with poll filter logic.
    //
    // v0.1.21: sanity range 8000..24000 raw (200..600V after × 0.025).
    // Catches the 0xFFFF / 65535 (1638V) "not available" marker that
    // BMS returns under sustained heavy regen — observed 7 cycles in
    // livelog session 13 (2026-05-19 10:09:34-09:51).
    DidSpec(did: '0015', name: 'HV bus voltage', unit: 'V', scale: 0.025, expectedBytes: 2, category: DidCategory.packVoltage, sanityRawMin: 8000, sanityRawMax: 24000),
    DidSpec(did: '0009', name: 'Energy counter', category: DidCategory.counter),
    DidSpec(did: '000A', name: 'Counter A', category: DidCategory.counter),
    DidSpec(did: '0B00', name: 'Total energy 1', category: DidCategory.counter),
    DidSpec(did: '0B01', name: 'Total energy 2', category: DidCategory.counter),
    DidSpec(did: '0B02', name: 'Cycle count', category: DidCategory.counter),
    // v0.1.21: 4-byte structure decoded after 2026-05-19 cross-check
    // against snapshot SOC readings:
    //   1FFD layout = [SOC × 100 : u16 BE][0x3B09 const : u16]
    //   1FFE layout = [0x0960 platform const : u16][hours? : u16]
    //
    // 1FFD high16 verified against 4 paired (sweep, snapshot) points:
    //   18-May 19:43 sweep=5550 → 55.50%, snapshot SOC=56% ✓
    //   19-May 10:05 livelog=5540 → 55.40%, snapshot SOC=55% ✓
    //   19-May 10:13 livelog=5390 → 53.90%, snapshot SOC=54% ✓
    //   19-May 10:30 sweep=4940 → 49.40%, snapshot SOC=49% ✓
    //
    // The lower16 of 1FFD is platform-constant 0x3B09 (15113) — same on
    // both BZ5 and BZ3 from cross-validation. Not part of the SOC value.
    //
    // 1FFE: high16 0x0960 (2400) is identical on BZ5 and BZ3 → platform
    // constant. Low16 differs by ~85 between cars; semantics TBD (slow
    // counter, possibly OBC-style operating hours, didn't tick during
    // 7.5 min livelog so rate ≤ 1 unit / 7.5 min if monotonic).
    //
    // Decoder is custom (not the standard scale × raw + offset). Read
    // path: ConnectionService.socPrecisePct getter parses raw 4-byte
    // payload and returns high16 / 100.0. Sanity on the full u32 is
    // not meaningful, so we only catch 0xFFFFFFFF.
    DidSpec(did: '1FFD', name: 'SOC precise (×0.01)', unit: '%', expectedBytes: 4, category: DidCategory.soc, notes: 'high16 / 100 = SOC%; low16 = platform const 0x3B09'),
    DidSpec(did: '1FFE', name: 'Platform counter', expectedBytes: 4, category: DidCategory.counter, notes: 'high16 = platform const 0x0960; low16 = slow counter, semantics TBD'),
    DidSpec(did: '0006', name: 'Power rated', unit: '×0.1 kW', scale: 0.1, category: DidCategory.battery),
    DidSpec(did: '0008', name: 'Current limit', unit: '×0.1 A', scale: 0.1, category: DidCategory.battery),
    // 20 cell voltages (10 modules × 2 cells)
    DidSpec(did: '016D', name: 'Module 1 cell A', unit: 'mV', category: DidCategory.cells),
    DidSpec(did: '016F', name: 'Module 1 cell B', unit: 'mV', category: DidCategory.cells),
    DidSpec(did: '0175', name: 'Module 2 cell A', unit: 'mV', category: DidCategory.cells),
    DidSpec(did: '0177', name: 'Module 2 cell B', unit: 'mV', category: DidCategory.cells),
    DidSpec(did: '017D', name: 'Module 3 cell A', unit: 'mV', category: DidCategory.cells),
    DidSpec(did: '017F', name: 'Module 3 cell B', unit: 'mV', category: DidCategory.cells),
    DidSpec(did: '0185', name: 'Module 4 cell A', unit: 'mV', category: DidCategory.cells),
    DidSpec(did: '0187', name: 'Module 4 cell B', unit: 'mV', category: DidCategory.cells),
    DidSpec(did: '018D', name: 'Module 5 cell A', unit: 'mV', category: DidCategory.cells),
    DidSpec(did: '018F', name: 'Module 5 cell B', unit: 'mV', category: DidCategory.cells),
    DidSpec(did: '0195', name: 'Module 6 cell A', unit: 'mV', category: DidCategory.cells),
    DidSpec(did: '0197', name: 'Module 6 cell B', unit: 'mV', category: DidCategory.cells),
    DidSpec(did: '019D', name: 'Module 7 cell A', unit: 'mV', category: DidCategory.cells),
    DidSpec(did: '019F', name: 'Module 7 cell B', unit: 'mV', category: DidCategory.cells),
    DidSpec(did: '01A5', name: 'Module 8 cell A', unit: 'mV', category: DidCategory.cells),
    DidSpec(did: '01A7', name: 'Module 8 cell B', unit: 'mV', category: DidCategory.cells),
    DidSpec(did: '01AD', name: 'Module 9 cell A', unit: 'mV', category: DidCategory.cells),
    DidSpec(did: '01AF', name: 'Module 9 cell B', unit: 'mV', category: DidCategory.cells),
    DidSpec(did: '01B5', name: 'Module 10 cell A', unit: 'mV', category: DidCategory.cells),
    DidSpec(did: '01B7', name: 'Module 10 cell B', unit: 'mV', category: DidCategory.cells),
    // v0.1.2: 20 module temperatures (10 modules × 2 sensors), offset -40
    // M6 (0x0199, 0x019B) returns 0xFF — BMS не заполняет этот слот
    DidSpec(did: '0171', name: 'Module 1 temp 1', unit: '°C', offset: -40, category: DidCategory.thermal),
    DidSpec(did: '0173', name: 'Module 1 temp 2', unit: '°C', offset: -40, category: DidCategory.thermal),
    DidSpec(did: '0179', name: 'Module 2 temp 1', unit: '°C', offset: -40, category: DidCategory.thermal),
    DidSpec(did: '017B', name: 'Module 2 temp 2', unit: '°C', offset: -40, category: DidCategory.thermal),
    DidSpec(did: '0181', name: 'Module 3 temp 1', unit: '°C', offset: -40, category: DidCategory.thermal),
    DidSpec(did: '0183', name: 'Module 3 temp 2', unit: '°C', offset: -40, category: DidCategory.thermal),
    DidSpec(did: '0189', name: 'Module 4 temp 1', unit: '°C', offset: -40, category: DidCategory.thermal),
    DidSpec(did: '018B', name: 'Module 4 temp 2', unit: '°C', offset: -40, category: DidCategory.thermal),
    DidSpec(did: '0191', name: 'Module 5 temp 1', unit: '°C', offset: -40, category: DidCategory.thermal),
    DidSpec(did: '0193', name: 'Module 5 temp 2', unit: '°C', offset: -40, category: DidCategory.thermal),
    DidSpec(did: '0199', name: 'Module 6 temp 1', unit: '°C', offset: -40, category: DidCategory.thermal, notes: 'BMS returns 0xFF — temp not reported'),
    DidSpec(did: '019B', name: 'Module 6 temp 2', unit: '°C', offset: -40, category: DidCategory.thermal, notes: 'BMS returns 0xFF — temp not reported'),
    DidSpec(did: '01A1', name: 'Module 7 temp 1', unit: '°C', offset: -40, category: DidCategory.thermal),
    DidSpec(did: '01A3', name: 'Module 7 temp 2', unit: '°C', offset: -40, category: DidCategory.thermal),
    DidSpec(did: '01A9', name: 'Module 8 temp 1', unit: '°C', offset: -40, category: DidCategory.thermal),
    DidSpec(did: '01AB', name: 'Module 8 temp 2', unit: '°C', offset: -40, category: DidCategory.thermal),
    DidSpec(did: '01B1', name: 'Module 9 temp 1', unit: '°C', offset: -40, category: DidCategory.thermal),
    DidSpec(did: '01B3', name: 'Module 9 temp 2', unit: '°C', offset: -40, category: DidCategory.thermal),
    DidSpec(did: '01B9', name: 'Module 10 temp 1', unit: '°C', offset: -40, category: DidCategory.thermal),
    DidSpec(did: '01BB', name: 'Module 10 temp 2', unit: '°C', offset: -40, category: DidCategory.thermal),
  ],
);

const vcuEcu = EcuSpec(
  txId: '791', rxId: '799', name: 'VCU',
  description: 'Vehicle Control Unit',
  dids: [
    DidSpec(did: '0105', name: 'Part number', category: DidCategory.identity),
    DidSpec(did: '0190', name: 'VIN', category: DidCategory.identity),
    DidSpec(did: '0026', name: 'Odometer', unit: 'km', scale: 0.1, expectedBytes: 4, category: DidCategory.drive),
    DidSpec(did: '0038', name: 'Power-A', unit: '×0.1 kW', scale: 0.1, category: DidCategory.drive),
    DidSpec(did: '0039', name: 'Power-B', scale: 0.1, category: DidCategory.drive),
    DidSpec(did: '0104', name: 'RPM-like', category: DidCategory.drive),
    DidSpec(did: '0007', name: 'Parking pawl', category: DidCategory.status),
    // v0.1.15 fix: 0x0009 Gear is 2 bytes, not 1.
    // Sweep evidence: raw="6200090003" payload="0003"=3 (N).
    // Sample log evidence: raw="6200090001" payload="0001"=1 (P).
    // Encoding: 0001=P, 0002=R, 0003=N, 0004=D.
    DidSpec(did: '0009', name: 'Gear', expectedBytes: 2, category: DidCategory.status),
    DidSpec(did: '0016', name: 'Mode', category: DidCategory.status),
    DidSpec(did: '004A', name: 'BigCounter A', expectedBytes: 4, category: DidCategory.counter),
    DidSpec(did: '004B', name: 'BigCounter B', expectedBytes: 4, category: DidCategory.counter),
    DidSpec(did: '0043', name: 'Temp value', unit: '°C', scale: 0.25, category: DidCategory.thermal),
  ],
);

// v0.1.20 reverse-engineering update (cross-validation with BZ3 + multi-day
// stability tests on BZ5):
//
//   0x0014, 0x0016, 0x0022, 0x0023 are NOT live pack voltage. They are
//   platform-nominal CONSTANTS (~450V class on BZ5). Evidence:
//   - 5 trips on 2026-05-18 with SOC 64→55%, HV bus 393→413V swing,
//     cells -35mV under load: pack_v (740/0x0022) glued at 450.0 ± 0.3 V
//   - Same byte values across two sweeps 2 hours apart, including driving
//     in between: 0x0014=4671, 0x0022=4650, 0x0023=C64F, 0x0024 80-byte
//     struct all byte-identical → static configuration
//   - On BZ3 the same DIDs return ~450V despite that pack physically being
//     ~85S/280V → confirms platform constant, not pack measurement
//
//   For live pack voltage under load use 790/0x0015 (HV bus, ×0.025) which
//   has a 46V swing during driving and is the only genuinely live V source.
//
//   0x0010 and 0x0011 ARE LIVE (component temps): values dropped 19/18 raw
//   units between yesterday-after-driving and today-after-cooldown sweeps.
//   Interpretation: PDU/junction heatsink temps, offset -40 °C.
const packMonitorEcu = EcuSpec(
  txId: '740', rxId: '748', name: 'PDU/HV Junction',
  description: 'HV junction box: pack config constants + PDU temps',
  dids: [
    DidSpec(did: '0105', name: 'Part number', category: DidCategory.identity),
    // v0.1.21: 740/0x0008 confirmed as VEHICLE SPEED from livelog
    // session 14 (2026-05-19 10:15-10:20):
    //   raw=0 at full stop (cycles 1-4)
    //   raw=1268 (0x04F4) during user-set 90 km/h cruise (cycles 121+)
    //   → scale = raw / 14.09, expressed below as ×0.07097 (≈ 1/14.09)
    //
    // Scale precision: user's 90.0 km/h cruise gave raw 1267-1272, so
    // raw/14.09 = 89.92-90.28. 14.09 is the empirical divisor; with
    // odometer integration of ∫speed dt over a known segment we can
    // refine to 5 decimal places if needed.
    //
    // Sanity range: 0..3000 raw covers 0..213 km/h. Real-world BZ5 top
    // speed is ~160 km/h. 3000 leaves headroom for false-high outliers
    // before they corrupt trip-averages.
    DidSpec(did: '0008', name: 'Vehicle speed', unit: 'km/h', scale: 0.07097, expectedBytes: 2, category: DidCategory.dynamic, sanityRawMin: 0, sanityRawMax: 3000, notes: 'raw / 14.09 = km/h. CONFIRMED 2026-05-19 livelog 16: scale 1/14.09 precise. Reading is TRUE wheel speed (UN R39 — about 5% LOWER than analog speedometer display). At cruise 90 km/h on speedometer, this reads ~85.4 km/h.'),
    DidSpec(did: '0009', name: 'Transient indicator (noise)', expectedBytes: 2, category: DidCategory.unknown, notes: 'v0.1.24: tested 2026-05-19 (livelog 16, 2028 cycles). Median 982 ± 20 across all driving regimes. NO correlation with speed/accel/regen bins. Spikes to 1100+ briefly during sharp transients (brake or accel), but base value identical at idle, cruise, and load — not torque, not power. Likely raw ADC noise on an unused channel. Kept in registry as documentation; removed from active polling (category = unknown).'),
    DidSpec(did: '0014', name: 'Pack V nominal (const)', unit: 'V', scale: 0.025, expectedBytes: 2, category: DidCategory.unknown, notes: 'Platform constant ~450V — not live; use HV bus (790/0x0015) for live V'),
    DidSpec(did: '0016', name: 'Pack V nominal alt (const)', unit: 'V', scale: 0.025, expectedBytes: 2, category: DidCategory.unknown, notes: 'Platform constant — not live'),
    DidSpec(did: '0022', name: 'Pack V reference (slow-drift)', unit: 'V', scale: 0.025, expectedBytes: 2, category: DidCategory.unknown, notes: 'Slowly-drifting V reference ~450V. v0.1.24: confirmed not constant (4650 morning → 4659 evening after driving) but updates much too slowly for live use. Drift mechanism unknown; possibly calibration adjustment vs temperature or aging. Use HV bus (790/0x0015) for live V instead.'),
    DidSpec(did: '0023', name: 'Status word (dynamic, semantics TBD)', expectedBytes: 2, category: DidCategory.unknown, notes: 'v0.1.24: previously thought to be "0x0022 OR 0x8000" pattern (constant flag). Sweep 17 showed structure changes after driving: 0xC64F → 0x46D5 (no longer 0x8000-bit set). Now believed to be a status/state word that changes on certain events (post-drive snapshot or thermal cycle). Semantics not decoded. Not useful for live UI yet.'),
    DidSpec(did: '0007', name: 'Status', category: DidCategory.status),
    // v0.1.20: 0x0010 and 0x0011 ARE LIVE component temperatures, not
    // contactor flags. Offset -40 °C. Yesterday after driving: 58°C/50°C.
    // Today after cooldown: 39°C/32°C. Likely PDU/junction heatsink sensors.
    DidSpec(did: '0010', name: 'PDU temp 1', unit: '°C', offset: -40, category: DidCategory.thermal, sanityRawMin: 0, sanityRawMax: 200),
    DidSpec(did: '0011', name: 'PDU temp 2', unit: '°C', offset: -40, category: DidCategory.thermal, sanityRawMin: 0, sanityRawMax: 200),
  ],
);

// v0.1.20: 782 OBC re-mapped after parking sweep + BZ3 cross-validation:
//   - 0x0006, 0x000B = 500 on both BZ3 and BZ5 → charge V target (500V max)
//   - 0x000C = 1000 on both → charge I max ×0.1 = 100.0 A
//   - 0x0009 = ~447-451 → charger-side V (semantics TBD: scale ×1.0 gives ~V,
//     but on BZ3 actual HV is ~283V while DID shows 451 — may be target ref,
//     verify in driving log)
//   - 0x000A = 14999-15000 → slow counter, +1 unit between BZ3 and our pack
//     → OBC operating hours candidate
//   - 0x000F, 0x0010 = LIVE temps with offset -40 (BZ5=29°C cool, BZ3=39°C
//     after activity)
//   - 0x0057 = state flag, BZ5-only
//   - 0x0053-0x0056 = zero placeholders, BZ5-only (future features)
const chargerEcu = EcuSpec(
  txId: '782', rxId: '78A', name: 'OBC',
  description: 'On-Board Charger',
  dids: [
    DidSpec(did: '0105', name: 'Part number', category: DidCategory.identity),
    DidSpec(did: '0006', name: 'Charge V target', unit: 'V', scale: 1.0, expectedBytes: 2, category: DidCategory.charging, notes: '500V on BZ5/BZ3'),
    DidSpec(did: '0009', name: 'Charger V reading', unit: 'V', scale: 1.0, expectedBytes: 2, category: DidCategory.charging, notes: 'Semantics TBD — verify in driving/charging'),
    DidSpec(did: '000A', name: 'OBC hours', expectedBytes: 2, category: DidCategory.counter, notes: 'BZ3 14999, BZ5 15000 → operating-hours candidate'),
    DidSpec(did: '000B', name: 'Charge V target (alt)', unit: 'V', scale: 1.0, expectedBytes: 2, category: DidCategory.charging),
    DidSpec(did: '000C', name: 'Charge I max', unit: 'A', scale: 0.1, expectedBytes: 2, category: DidCategory.charging, notes: '×0.1 → 100.0 A'),
    DidSpec(did: '000F', name: 'OBC temp 1', unit: '°C', offset: -40, category: DidCategory.thermal),
    DidSpec(did: '0010', name: 'OBC temp 2', unit: '°C', offset: -40, category: DidCategory.thermal),
    DidSpec(did: '0057', name: 'OBC state flag', category: DidCategory.charging, notes: 'BZ5-only, value 0x01 at rest'),
  ],
);

const gpsEcu = EcuSpec(
  txId: '757', rxId: '75F', name: 'GPS',
  description: 'Asensing GNSS positioning',
  dids: [
    DidSpec(did: '0105', name: 'Part number', category: DidCategory.identity),
    DidSpec(did: '0111', name: 'Module version', category: DidCategory.identity),
    DidSpec(did: '0113', name: 'Module serial', category: DidCategory.identity),
    DidSpec(did: '0114', name: 'Hardware version', category: DidCategory.identity),
    DidSpec(did: '0115', name: 'Firmware build', category: DidCategory.identity),
    DidSpec(did: '0116', name: 'CY firmware', category: DidCategory.identity),
  ],
);

const gatewayEcu = EcuSpec(
  txId: '702', rxId: '70A', name: 'Gateway',
  description: 'CAN gateway / VCU extension',
  dids: [
    DidSpec(did: '0105', name: 'Part number', category: DidCategory.identity),
    DidSpec(did: '0005', name: 'Status', category: DidCategory.status),
    DidSpec(did: '002C', name: 'Param A', category: DidCategory.unknown),
    DidSpec(did: '002D', name: 'Param B', category: DidCategory.unknown),
    DidSpec(did: '004C', name: 'Param C', category: DidCategory.unknown),
  ],
);

class EcuRegistryEntry {
  final String txId;
  final String rxId;
  final String label;
  final EcuSpec? detailed;

  const EcuRegistryEntry({
    required this.txId,
    required this.rxId,
    required this.label,
    this.detailed,
  });
}

const allBz5Ecus = <EcuRegistryEntry>[
  EcuRegistryEntry(txId: '701', rxId: '709', label: 'Gateway/VCU#1'),
  EcuRegistryEntry(txId: '702', rxId: '70A', label: 'Gateway', detailed: gatewayEcu),
  EcuRegistryEntry(txId: '703', rxId: '70B', label: 'Gateway/VCU#3'),
  EcuRegistryEntry(txId: '713', rxId: '71B', label: 'Motor controller 1'),
  EcuRegistryEntry(txId: '714', rxId: '71C', label: 'Motor controller 2'),
  EcuRegistryEntry(txId: '716', rxId: '71E', label: 'Motor controller 3'),
  EcuRegistryEntry(txId: '717', rxId: '71F', label: 'Motor controller 4'),
  EcuRegistryEntry(txId: '721', rxId: '729', label: 'Inverter/DC-DC 1'),
  EcuRegistryEntry(txId: '722', rxId: '72A', label: 'Inverter/DC-DC 2'),
  EcuRegistryEntry(txId: '724', rxId: '72C', label: 'Inverter/DC-DC 3'),
  EcuRegistryEntry(txId: '732', rxId: '73A', label: 'Aux #1'),
  EcuRegistryEntry(txId: '740', rxId: '748', label: 'PDU/HV Junction', detailed: packMonitorEcu),
  EcuRegistryEntry(txId: '744', rxId: '74C', label: 'PDU 2'),
  EcuRegistryEntry(txId: '745', rxId: '74D', label: 'PDU 3'),
  EcuRegistryEntry(txId: '746', rxId: '74E', label: 'PDU 4'),
  EcuRegistryEntry(txId: '750', rxId: '758', label: 'BMS slave 1'),
  EcuRegistryEntry(txId: '751', rxId: '759', label: 'BMS slave 2'),
  EcuRegistryEntry(txId: '752', rxId: '75A', label: 'BMS slave 3'),
  EcuRegistryEntry(txId: '753', rxId: '75B', label: 'BMS slave 4'),
  EcuRegistryEntry(txId: '755', rxId: '75D', label: 'BMS slave 5'),
  EcuRegistryEntry(txId: '756', rxId: '75E', label: 'BMS slave 6'),
  EcuRegistryEntry(txId: '757', rxId: '75F', label: '🛰 GPS', detailed: gpsEcu),
  EcuRegistryEntry(txId: '760', rxId: '768', label: 'Aux #2'),
  EcuRegistryEntry(txId: '777', rxId: '77F', label: 'Aux #3'),
  EcuRegistryEntry(txId: '782', rxId: '78A', label: '🔌 Charger', detailed: chargerEcu),
  EcuRegistryEntry(txId: '786', rxId: '78E', label: 'Aux #4'),
  EcuRegistryEntry(txId: '790', rxId: '798', label: '🔋 BMS master', detailed: bmsEcu),
  EcuRegistryEntry(txId: '791', rxId: '799', label: '🚗 VCU', detailed: vcuEcu),
  EcuRegistryEntry(txId: '7E5', rxId: '7ED', label: 'OBD compliance'),
  EcuRegistryEntry(txId: '7F1', rxId: '7F9', label: 'Gateway #2'),
];

class DecodedValue {
  final double? numeric;
  final String? text;
  final String unit;
  final List<int>? rawBytes;

  DecodedValue({this.numeric, this.text, this.unit = '', this.rawBytes});

  String get display {
    if (text != null) return text!;
    if (numeric == null) return '—';
    if (numeric! == numeric!.truncateToDouble()) return '${numeric!.toInt()}$unit';
    return '${numeric!.toStringAsFixed(2)}$unit';
  }
}

DecodedValue? decodeDid(DidSpec spec, List<int>? payload) {
  if (payload == null || payload.isEmpty) return null;

  if (spec.category == DidCategory.identity && payload.length > 4) {
    final printable = payload.where((b) => b >= 0x20 && b < 0x7F).length;
    if (printable >= payload.length * 0.5) {
      final text = String.fromCharCodes(payload.where((b) => b >= 0x20 && b < 0x7F)).trim();
      return DecodedValue(text: text, rawBytes: payload);
    }
  }

  // v0.1.2: thermal "no data" sentinel — BMS пишет 0xFF когда не отдаёт значение
  // (например M6 temperatures). Возвращаем DecodedValue без numeric — UI сам решает
  // что делать (показать "not reported").
  if (spec.category == DidCategory.thermal && payload.length == 1 && payload[0] == 0xFF) {
    return DecodedValue(rawBytes: payload);
  }

  int? raw;
  if (payload.length == 1) raw = payload[0];
  else if (payload.length == 2) raw = (payload[0] << 8) | payload[1];
  else if (payload.length == 4) raw = (payload[0] << 24) | (payload[1] << 16) | (payload[2] << 8) | payload[3];
  else if (payload.length >= 2) raw = (payload[0] << 8) | payload[1];

  if (raw == null) return DecodedValue(rawBytes: payload);

  // v0.1.2: 0xFFFF sentinel для 2-byte значений (pack voltage realtime)
  if (spec.category == DidCategory.packVoltage && spec.did == '0015' && raw == 0xFFFF) {
    return DecodedValue(rawBytes: payload);
  }

  // v0.1.21: 790/0x1FFD precise SOC — payload is 4 bytes, real value
  // is high16 / 100 (verified 2026-05-19 against 4 paired snapshot+sweep
  // samples). Standard scale × raw is wrong here because raw u32 is in
  // hundreds-of-millions range. Override before applying scale.
  if (spec.category == DidCategory.soc && spec.did == '1FFD' && payload.length >= 2) {
    final high16 = (payload[0] << 8) | payload[1];
    if (high16 >= 0 && high16 <= 10000) {
      return DecodedValue(
        numeric: high16 / 100.0,
        unit: '%',
        rawBytes: payload,
      );
    }
    return DecodedValue(rawBytes: payload);
  }

  final phys = raw * spec.scale + spec.offset;
  return DecodedValue(numeric: phys, unit: spec.unit, rawBytes: payload);
}

/// Списки ECU для опроса в разных режимах
const pollEcusDriving = [bmsEcu, vcuEcu, packMonitorEcu];
const pollEcusCharging = [bmsEcu, packMonitorEcu, chargerEcu];
const pollEcusFull = [bmsEcu, vcuEcu, packMonitorEcu, chargerEcu, gatewayEcu];
