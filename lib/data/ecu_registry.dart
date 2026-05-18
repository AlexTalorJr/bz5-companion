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

  const DidSpec({
    required this.did,
    required this.name,
    this.unit = '',
    this.scale = 1.0,
    this.offset = 0.0,
    this.category = DidCategory.unknown,
    this.expectedBytes,
    this.notes,
  });
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
    DidSpec(did: '0005', name: 'SOC', unit: '%', category: DidCategory.battery),
    DidSpec(did: '0029', name: 'SOH', unit: '%', category: DidCategory.battery),
    DidSpec(did: '002F', name: 'Battery temp', unit: '°C', offset: -40, category: DidCategory.thermal),
    DidSpec(did: '002B', name: 'Cell V min', unit: 'mV', expectedBytes: 2, category: DidCategory.cells),
    DidSpec(did: '002D', name: 'Cell V max', unit: 'mV', expectedBytes: 2, category: DidCategory.cells),
    // v0.1.2: pack voltage realtime — DEPRECATED INTERPRETATION
    // v0.1.8 update: this DID is actually HV bus voltage (downstream of
    // main contactor), NOT pack voltage. Pack V comes from 740/0x0022.
    // Scale corrected 0.02 → 0.025 based on Ready-state measurement
    // 2026-05-15 (raw 0x42FE × 0.025 = 428.75V matches predicted bus V).
    // Category 'packVoltage' kept for backward compat with poll filter logic.
    DidSpec(did: '0015', name: 'HV bus voltage', unit: 'V', scale: 0.025, expectedBytes: 2, category: DidCategory.packVoltage),
    DidSpec(did: '0009', name: 'Energy counter', category: DidCategory.counter),
    DidSpec(did: '000A', name: 'Counter A', category: DidCategory.counter),
    DidSpec(did: '0B00', name: 'Total energy 1', category: DidCategory.counter),
    DidSpec(did: '0B01', name: 'Total energy 2', category: DidCategory.counter),
    DidSpec(did: '0B02', name: 'Cycle count', category: DidCategory.counter),
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
    DidSpec(did: '0008', name: 'Sub-pack V #1', unit: 'V', scale: 0.1, expectedBytes: 2, category: DidCategory.packVoltage, notes: '~97V — to verify in driving'),
    DidSpec(did: '0009', name: 'Sub-pack V #2', unit: 'V', scale: 0.1, expectedBytes: 2, category: DidCategory.packVoltage, notes: '~99V — to verify in driving'),
    // v0.1.20: now flagged as platform constant. Scale kept ×0.025 so the
    // value displayed in raw-data views remains numerically meaningful
    // (~450V) for users who want to see what the firmware reports, but
    // it's no longer treated as live pack telemetry.
    DidSpec(did: '0014', name: 'Pack V nominal (const)', unit: 'V', scale: 0.025, expectedBytes: 2, category: DidCategory.unknown, notes: 'Platform constant ~450V — not live; use HV bus (790/0x0015) for live V'),
    DidSpec(did: '0016', name: 'Pack V nominal alt (const)', unit: 'V', scale: 0.025, expectedBytes: 2, category: DidCategory.unknown, notes: 'Platform constant — not live'),
    DidSpec(did: '0022', name: 'Pack V nominal filtered (const)', unit: 'V', scale: 0.025, expectedBytes: 2, category: DidCategory.unknown, notes: 'Platform constant ~450V — not live; was primary pack V source up to v0.1.19, replaced by HV bus in v0.1.20'),
    DidSpec(did: '0023', name: 'V flag/duplicate (const)', expectedBytes: 2, category: DidCategory.unknown, notes: 'Always 0x0022 OR 0x8000 — not current/live'),
    DidSpec(did: '0007', name: 'Status', category: DidCategory.status),
    // v0.1.20: 0x0010 and 0x0011 ARE LIVE component temperatures, not
    // contactor flags. Offset -40 °C. Yesterday after driving: 58°C/50°C.
    // Today after cooldown: 39°C/32°C. Likely PDU/junction heatsink sensors.
    DidSpec(did: '0010', name: 'PDU temp 1', unit: '°C', offset: -40, category: DidCategory.thermal),
    DidSpec(did: '0011', name: 'PDU temp 2', unit: '°C', offset: -40, category: DidCategory.thermal),
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

  final phys = raw * spec.scale + spec.offset;
  return DecodedValue(numeric: phys, unit: spec.unit, rawBytes: payload);
}

/// Списки ECU для опроса в разных режимах
const pollEcusDriving = [bmsEcu, vcuEcu, packMonitorEcu];
const pollEcusCharging = [bmsEcu, packMonitorEcu, chargerEcu];
const pollEcusFull = [bmsEcu, vcuEcu, packMonitorEcu, chargerEcu, gatewayEcu];
