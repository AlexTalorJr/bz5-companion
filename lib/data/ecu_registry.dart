/// v2: добавлены 740 (Pack Voltage), 782 (Charger), 757 (GPS), 702 (Gateway)

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
    DidSpec(did: '0009', name: 'Energy counter', category: DidCategory.counter),
    DidSpec(did: '000A', name: 'Counter A', category: DidCategory.counter),
    DidSpec(did: '0B00', name: 'Total energy 1', category: DidCategory.counter),
    DidSpec(did: '0B01', name: 'Total energy 2', category: DidCategory.counter),
    DidSpec(did: '0006', name: 'Power rated', unit: '×0.1 kW', scale: 0.1, category: DidCategory.battery),
    DidSpec(did: '0008', name: 'Current limit', unit: '×0.1 A', scale: 0.1, category: DidCategory.battery),
    DidSpec(did: '016D', name: 'Module 1 cell min', unit: 'mV', category: DidCategory.cells),
    DidSpec(did: '016F', name: 'Module 1 cell max', unit: 'mV', category: DidCategory.cells),
    DidSpec(did: '0175', name: 'Module 2 cell min', unit: 'mV', category: DidCategory.cells),
    DidSpec(did: '0177', name: 'Module 2 cell max', unit: 'mV', category: DidCategory.cells),
    DidSpec(did: '017D', name: 'Module 3 cell min', unit: 'mV', category: DidCategory.cells),
    DidSpec(did: '017F', name: 'Module 3 cell max', unit: 'mV', category: DidCategory.cells),
    DidSpec(did: '0185', name: 'Module 4 cell min', unit: 'mV', category: DidCategory.cells),
    DidSpec(did: '0187', name: 'Module 4 cell max', unit: 'mV', category: DidCategory.cells),
    DidSpec(did: '018D', name: 'Module 5 cell min', unit: 'mV', category: DidCategory.cells),
    DidSpec(did: '018F', name: 'Module 5 cell max', unit: 'mV', category: DidCategory.cells),
    DidSpec(did: '0195', name: 'Module 6 cell min', unit: 'mV', category: DidCategory.cells),
    DidSpec(did: '0197', name: 'Module 6 cell max', unit: 'mV', category: DidCategory.cells),
    DidSpec(did: '019D', name: 'Module 7 cell min', unit: 'mV', category: DidCategory.cells),
    DidSpec(did: '019F', name: 'Module 7 cell max', unit: 'mV', category: DidCategory.cells),
    DidSpec(did: '01A5', name: 'Module 8 cell min', unit: 'mV', category: DidCategory.cells),
    DidSpec(did: '01A7', name: 'Module 8 cell max', unit: 'mV', category: DidCategory.cells),
    DidSpec(did: '01AD', name: 'Module 9 cell min', unit: 'mV', category: DidCategory.cells),
    DidSpec(did: '01AF', name: 'Module 9 cell max', unit: 'mV', category: DidCategory.cells),
    DidSpec(did: '01B5', name: 'Module 10 cell min', unit: 'mV', category: DidCategory.cells),
    DidSpec(did: '01B7', name: 'Module 10 cell max', unit: 'mV', category: DidCategory.cells),
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
    DidSpec(did: '0009', name: 'Gear', category: DidCategory.status),
    DidSpec(did: '0016', name: 'Mode', category: DidCategory.status),
    DidSpec(did: '004A', name: 'BigCounter A', expectedBytes: 4, category: DidCategory.counter),
    DidSpec(did: '004B', name: 'BigCounter B', expectedBytes: 4, category: DidCategory.counter),
    DidSpec(did: '0043', name: 'Temp value', unit: '°C', scale: 0.25, category: DidCategory.thermal),
  ],
);

const packMonitorEcu = EcuSpec(
  txId: '740', rxId: '748', name: 'Pack Monitor',
  description: 'Battery contactor + pack voltage',
  dids: [
    DidSpec(did: '0105', name: 'Part number', category: DidCategory.identity),
    DidSpec(did: '0008', name: 'Sub-pack V #1', unit: 'V', scale: 0.1, expectedBytes: 2, category: DidCategory.packVoltage, notes: '~97V'),
    DidSpec(did: '0009', name: 'Sub-pack V #2', unit: 'V', scale: 0.1, expectedBytes: 2, category: DidCategory.packVoltage, notes: '~99V'),
    DidSpec(did: '0014', name: 'Pack half V #1', unit: 'V', scale: 0.01, expectedBytes: 2, category: DidCategory.packVoltage, notes: '~180V'),
    DidSpec(did: '0016', name: 'Pack half V #2', unit: 'V', scale: 0.01, expectedBytes: 2, category: DidCategory.packVoltage),
    DidSpec(did: '0022', name: 'Pack V (alt)', unit: 'V', scale: 0.01, expectedBytes: 2, category: DidCategory.packVoltage),
    DidSpec(did: '0023', name: 'Pack V (alt)2', unit: 'V', scale: 0.01, expectedBytes: 2, category: DidCategory.packVoltage),
    DidSpec(did: '0007', name: 'Status', category: DidCategory.status),
    DidSpec(did: '0010', name: 'Contactor 1', category: DidCategory.status),
    DidSpec(did: '0011', name: 'Contactor 2', category: DidCategory.status),
  ],
);

const chargerEcu = EcuSpec(
  txId: '782', rxId: '78A', name: 'OBC',
  description: 'On-Board Charger',
  dids: [
    DidSpec(did: '0105', name: 'Part number', category: DidCategory.identity),
    DidSpec(did: '0006', name: 'Current limit', unit: '×0.1 A', scale: 0.1, expectedBytes: 2, category: DidCategory.charging),
    DidSpec(did: '0009', name: 'Charging status', expectedBytes: 2, category: DidCategory.charging),
    DidSpec(did: '000A', name: 'Power rating', unit: 'W', expectedBytes: 2, category: DidCategory.charging),
    DidSpec(did: '000B', name: 'Voltage limit?', expectedBytes: 2, category: DidCategory.charging),
    DidSpec(did: '000C', name: 'Max current', expectedBytes: 2, category: DidCategory.charging),
    DidSpec(did: '000F', name: 'Status A', category: DidCategory.charging),
    DidSpec(did: '0010', name: 'Status B', category: DidCategory.charging),
    DidSpec(did: '0057', name: 'Connection state', category: DidCategory.charging),
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
  EcuRegistryEntry(txId: '740', rxId: '748', label: 'Pack Monitor', detailed: packMonitorEcu),
  EcuRegistryEntry(txId: '744', rxId: '74C', label: 'Pack Monitor 2'),
  EcuRegistryEntry(txId: '745', rxId: '74D', label: 'Pack Monitor 3'),
  EcuRegistryEntry(txId: '746', rxId: '74E', label: 'Pack Monitor 4'),
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

  int? raw;
  if (payload.length == 1) raw = payload[0];
  else if (payload.length == 2) raw = (payload[0] << 8) | payload[1];
  else if (payload.length == 4) raw = (payload[0] << 24) | (payload[1] << 16) | (payload[2] << 8) | payload[3];
  else if (payload.length >= 2) raw = (payload[0] << 8) | payload[1];

  if (raw == null) return DecodedValue(rawBytes: payload);
  final phys = raw * spec.scale + spec.offset;
  return DecodedValue(numeric: phys, unit: spec.unit, rawBytes: payload);
}

/// Списки ECU для опроса в разных режимах
const pollEcusDriving = [bmsEcu, vcuEcu, packMonitorEcu];
const pollEcusCharging = [bmsEcu, packMonitorEcu, chargerEcu];
const pollEcusFull = [bmsEcu, vcuEcu, packMonitorEcu, chargerEcu, gatewayEcu];
