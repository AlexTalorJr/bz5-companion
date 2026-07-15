import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../data/dilink_vehicles.dart'; // makeFromVin (VIN → make prefill)
import '../l10n/strings.dart';
import '../services/cloud_sync_service.dart';
import '../services/native_car_channel.dart';
import '../services/vehicle_catalog_service.dart';

/// v0.1.35+134: reusable make/model picker for the pair/start vehicle
/// descriptor. Used inline on the pairing screen and inside the
/// "My vehicle" dialog on the account screen.
///
/// UX contract:
///   * Preset chips per make (Toyota bZ family / BYD DiLink / Denza) —
///     one-tap for the common cases, consistent nomenclature for the
///     owner's approval bot.
///   * "Other" opens free-form make + model fields — the catalog is a
///     convenience, never a gate (multi-make server rule).
///   * Best-effort VIN prefill of the MAKE only (WMI map, head unit
///     only), and only when nothing was saved before. The user always
///     sees and confirms — nothing is sent silently.
///   * Every complete selection is persisted immediately via
///     [CloudSyncService.setVehicleDescriptor]; partial states are not.
class VehicleDescriptorPicker extends StatefulWidget {
  const VehicleDescriptorPicker({super.key});

  @override
  State<VehicleDescriptorPicker> createState() =>
      _VehicleDescriptorPickerState();
}

class _VehicleDescriptorPickerState extends State<VehicleDescriptorPicker> {
  static const _kOther = '__other__';

  String? _make; // preset make or _kOther
  String? _model; // preset model or _kOther
  late final TextEditingController _customMake;
  late final TextEditingController _customModel;
  late final TextEditingController _name;
  // v0.1.43+142 §6: optional model year (the approval bot shows
  // "Make Model (year)"). NO VIN prefill by design — the 10th VIN char
  // is unreliable on the CN market.
  late final TextEditingController _year;
  Timer? _debounce;

  @override
  void initState() {
    super.initState();
    _customMake = TextEditingController();
    _customModel = TextEditingController();
    _name = TextEditingController();
    _year = TextEditingController();
    final cs = context.read<CloudSyncService>();
    // v0.1.36+135: seed against the CURRENT catalog (server cache or
    // built-in), then kick a fire-and-forget staleness check. This one
    // call site covers both hosts of the picker — the pairing screen
    // and the "My vehicle" dialog (Q1: both, same widget).
    final vc = context.read<VehicleCatalogService>();
    _seedFromSaved(cs, vc);
    if (_make == null) _tryVinPrefill();
    unawaited(vc.refreshIfStale());
  }

  void _seedFromSaved(CloudSyncService cs, VehicleCatalogService vc) {
    final make = cs.vehDescMake;
    final model = cs.vehDescModel;
    _name.text = cs.vehDescName ?? '';
    _year.text = cs.vehDescGeneration?.toString() ?? '';
    if (make == null || make.isEmpty) return;
    if (vc.makes.contains(make)) {
      _make = make;
      final models = vc.modelsFor(make);
      if (model != null && models.contains(model)) {
        _model = model;
      } else if (model != null && model.isNotEmpty) {
        _model = _kOther;
        _customModel.text = model;
      }
    } else {
      _make = _kOther;
      _customMake.text = make;
      _customModel.text = model ?? '';
    }
  }

  /// Head-unit only, best-effort, MAKE only. Any failure or timeout
  /// degrades to "no prefill" — never blocks the UI.
  Future<void> _tryVinPrefill() async {
    String? vin;
    try {
      vin = await NativeCarChannel.instance
          .detectVin(fresh: false)
          .timeout(const Duration(seconds: 2));
    } catch (_) {
      vin = null;
    }
    final make = makeFromVin(vin);
    if (!mounted || make == null || _make != null) return;
    setState(() => _make = make);
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _customMake.dispose();
    _customModel.dispose();
    _name.dispose();
    _year.dispose();
    super.dispose();
  }

  String? get _effectiveMake =>
      _make == _kOther ? _customMake.text.trim() : _make;

  String? get _effectiveModel =>
      _model == _kOther || _make == _kOther ? _customModel.text.trim() : _model;

  /// Persist when the pair (make, model) is complete; debounced so the
  /// free-text path doesn't hammer prefs on every keystroke.
  void _commit() {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 400), () {
      if (!mounted) return;
      final make = _effectiveMake;
      final model = _effectiveModel;
      if (make == null || make.isEmpty || model == null || model.isEmpty) {
        return;
      }
      context.read<CloudSyncService>().setVehicleDescriptor(
            make: make,
            model: model,
            name: _name.text,
            // v0.1.43+142 §6: unparsable/partial input → null (the
            // service re-validates the 1990..2099 band anyway).
            generation: int.tryParse(_year.text.trim()),
          );
    });
  }

  @override
  Widget build(BuildContext context) {
    // v0.1.36+135: chips come from the catalog service (server cache or
    // built-in seed — the picker never learns which). watch() rebuilds
    // the chip set if a newer catalog lands mid-session; the saved
    // "model vanished from the new catalog" case is already covered by
    // the existing Other-chip fallback in _seedFromSaved.
    final vc = context.watch<VehicleCatalogService>();
    final isOtherMake = _make == _kOther;
    final models = isOtherMake || _make == null
        ? const <String>[]
        : vc.modelsFor(_make!);
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(S.of('vehicle.make'),
          style: const TextStyle(fontSize: 12, color: Colors.grey)),
      const SizedBox(height: 4),
      Wrap(spacing: 8, runSpacing: 4, children: [
        for (final m in vc.makes)
          ChoiceChip(
            label: Text(m),
            selected: _make == m,
            onSelected: (_) => setState(() {
              if (_make != m) _model = null;
              _make = m;
              _commit();
            }),
          ),
        ChoiceChip(
          label: Text(S.of('vehicle.other')),
          selected: isOtherMake,
          onSelected: (_) => setState(() {
            if (!isOtherMake) _model = null;
            _make = _kOther;
          }),
        ),
      ]),
      if (isOtherMake) ...[
        const SizedBox(height: 8),
        TextField(
          controller: _customMake,
          decoration: InputDecoration(
            isDense: true,
            border: const OutlineInputBorder(),
            labelText: S.of('vehicle.make'),
          ),
          onChanged: (_) => _commit(),
        ),
        const SizedBox(height: 8),
        TextField(
          controller: _customModel,
          decoration: InputDecoration(
            isDense: true,
            border: const OutlineInputBorder(),
            labelText: S.of('vehicle.model'),
          ),
          onChanged: (_) => _commit(),
        ),
      ] else if (_make != null) ...[
        const SizedBox(height: 8),
        Text(S.of('vehicle.model'),
            style: const TextStyle(fontSize: 12, color: Colors.grey)),
        const SizedBox(height: 4),
        Wrap(spacing: 8, runSpacing: 4, children: [
          for (final m in models)
            ChoiceChip(
              label: Text(m),
              selected: _model == m,
              onSelected: (_) => setState(() {
                _model = m;
                _commit();
              }),
            ),
          ChoiceChip(
            label: Text(S.of('vehicle.other')),
            selected: _model == _kOther,
            onSelected: (_) => setState(() => _model = _kOther),
          ),
        ]),
        if (_model == _kOther) ...[
          const SizedBox(height: 8),
          TextField(
            controller: _customModel,
            decoration: InputDecoration(
              isDense: true,
              border: const OutlineInputBorder(),
              labelText: S.of('vehicle.model'),
            ),
            onChanged: (_) => _commit(),
          ),
        ],
      ],
      if (_make != null) ...[
        const SizedBox(height: 8),
        TextField(
          controller: _name,
          decoration: InputDecoration(
            isDense: true,
            border: const OutlineInputBorder(),
            labelText: S.of('vehicle.name_label'),
            hintText: (_effectiveMake?.isNotEmpty ?? false) &&
                    (_effectiveModel?.isNotEmpty ?? false)
                ? '${_effectiveMake!} ${_effectiveModel!}'
                : null,
          ),
          onChanged: (_) => _commit(),
        ),
        // v0.1.43+142 §6: optional model year — numeric, 4 digits, same
        // debounced persist as the name field. Shared widget → shows up
        // in BOTH hosts automatically (pairing screen + "My vehicle").
        const SizedBox(height: 8),
        TextField(
          controller: _year,
          keyboardType: TextInputType.number,
          maxLength: 4,
          decoration: InputDecoration(
            isDense: true,
            counterText: '',
            border: const OutlineInputBorder(),
            labelText: S.of('vehicle.year'),
          ),
          onChanged: (_) => _commit(),
        ),
      ],
    ]);
  }
}
