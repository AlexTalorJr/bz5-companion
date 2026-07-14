import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../l10n/strings.dart';
import '../services/cloud_sync_service.dart';
import '../services/locale_service.dart';
import '../widgets/vehicle_descriptor_picker.dart';

/// v0.1.29+127 (C3): device-side pairing screen (CLIENT_API §1.2).
///
/// Shows the short user_code BIG (head-unit legibility from the driver
/// seat), a countdown for the 5-minute window, and live status while
/// polling. The device_code never reaches this widget — the service
/// keeps it private by design.
///
/// Scenario (b) — fresh device: once the claim lands, the minted token
/// is persisted service-side and a restore auto-starts; this screen
/// switches to the restore progress so the whole "reinstall → history
/// back" path is one flow with zero token typing.
class PairingScreen extends StatefulWidget {
  const PairingScreen({super.key});

  @override
  State<PairingScreen> createState() => _PairingScreenState();
}

class _PairingScreenState extends State<PairingScreen> {
  Timer? _ticker;
  String _kind = 'headunit';

  @override
  void initState() {
    super.initState();
    // 1 Hz repaint for the expiry countdown.
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _ticker?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    context.watch<LocaleService>();
    final cs = context.watch<CloudSyncService>();
    final List<Widget> body;
    switch (cs.pairingStatus) {
      case CloudPairingStatus.idle:
      case CloudPairingStatus.starting:
        body = _idle(cs);
      case CloudPairingStatus.waitingForClaim:
        body = _waiting(cs);
      case CloudPairingStatus.paired:
        body = _paired(cs);
      case CloudPairingStatus.expired:
        body = _terminal(cs, S.of('pairing.expired'), retry: true);
      case CloudPairingStatus.error:
        body = _terminal(
            cs, '${S.of('pairing.error')}: ${cs.pairError ?? '—'}',
            retry: true);
    }
    return Scaffold(
      appBar: AppBar(title: Text(S.of('pairing.title'))),
      body: ListView(padding: const EdgeInsets.all(16), children: body),
    );
  }

  List<Widget> _idle(CloudSyncService cs) {
    final busy = cs.pairingStatus == CloudPairingStatus.starting;
    // v0.1.35+134: pair/start must carry a vehicle descriptor for
    // fresh accounts (server provisions the vehicle at claim; without
    // it → 400 no_vehicle and the account can never sync). Already-
    // provisioned accounts get the block ignored, so requiring it here
    // costs one tap and keeps onboarding unbreakable for everyone.
    final vehicleReady = cs.hasVehicleDescriptor;
    return [
      Text(
        cs.isRegistered
            ? S.of('pairing.intro_live')
            : S.of('pairing.intro_fresh'),
        style: const TextStyle(color: Colors.grey, fontSize: 13),
      ),
      const SizedBox(height: 12),
      // Kind chips — mirrors the register-device kinds. Default matches
      // the primary use case (head unit after a reinstall).
      Wrap(
        spacing: 8,
        children: [
          ChoiceChip(
            label: Text(S.of('pairing.kind_headunit')),
            selected: _kind == 'headunit',
            onSelected: (_) => setState(() => _kind = 'headunit'),
          ),
          ChoiceChip(
            label: Text(S.of('pairing.kind_phone')),
            selected: _kind == 'phone',
            onSelected: (_) => setState(() => _kind = 'phone'),
          ),
        ],
      ),
      const SizedBox(height: 16),
      Text(S.of('vehicle.section_title'),
          style: const TextStyle(fontWeight: FontWeight.w600)),
      const SizedBox(height: 4),
      Text(S.of('vehicle.pairing_hint'),
          style: const TextStyle(color: Colors.grey, fontSize: 12)),
      const SizedBox(height: 8),
      const VehicleDescriptorPicker(),
      const SizedBox(height: 16),
      FilledButton.icon(
        icon: busy
            ? const SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(strokeWidth: 2))
            : const Icon(Icons.qr_code_2),
        label: Text(S.of('pairing.get_code')),
        onPressed: busy || !vehicleReady
            ? null
            : () => context
                .read<CloudSyncService>()
                .startPairing(kind: _kind),
      ),
      if (!vehicleReady) ...[
        const SizedBox(height: 6),
        Text(S.of('pairing.vehicle_required'),
            style: const TextStyle(color: Colors.orangeAccent, fontSize: 12)),
      ],
    ];
  }

  List<Widget> _waiting(CloudSyncService cs) {
    return [
      Text(S.of('pairing.enter_on_phone'),
          style: const TextStyle(color: Colors.grey, fontSize: 13)),
      const SizedBox(height: 16),
      Center(
        child: SelectableText(
          cs.pairUserCode ?? '—',
          style: const TextStyle(
            fontFamily: 'monospace',
            fontSize: 44,
            fontWeight: FontWeight.bold,
            letterSpacing: 6,
          ),
        ),
      ),
      const SizedBox(height: 12),
      Center(
        child: Text(
          '${S.of('pairing.expires_in')} ${cs.pairSecondsLeft}s',
          style: const TextStyle(color: Colors.grey),
        ),
      ),
      const SizedBox(height: 8),
      const Center(
        child: SizedBox(
          width: 18,
          height: 18,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
      ),
      const SizedBox(height: 16),
      OutlinedButton(
        onPressed: () => context.read<CloudSyncService>().cancelPairing(),
        child: Text(S.of('common.cancel')),
      ),
    ];
  }

  List<Widget> _paired(CloudSyncService cs) {
    final fresh = cs.pairMintedFresh;
    final rs = cs.restoreStatus;
    final rp = cs.restoreProgress;
    return [
      ListTile(
        contentPadding: EdgeInsets.zero,
        leading:
            const Icon(Icons.check_circle, color: Colors.lightGreenAccent),
        title: Text(fresh
            ? S.of('pairing.paired_fresh')
            : S.of('pairing.paired_live')),
        // v0.1.42+141: "linked to a***@… · status" right on the pairing
        // screen — the field complaint was "entered the code — and
        // silence". fetchDeviceMe fires in both paired branches of the
        // poll; until it lands the subtitle shows the '—' placeholder
        // and fills in via the service's notifyListeners.
        subtitle: Text(_pairedIdentityLine(cs),
            style: const TextStyle(fontSize: 13, color: Colors.grey)),
      ),
      if (fresh) ...[
        const SizedBox(height: 8),
        Text(
          '${S.of('pairing.restore_status')}: ${rs.name}\n'
          'trips ${rp.tripsInserted}/${rp.tripsFetched} · '
          'snapshots ${rp.snapshotsInserted}/${rp.snapshotsFetched}',
          style: const TextStyle(fontFamily: 'monospace', fontSize: 13),
        ),
        if (cs.restoreError != null)
          Text(cs.restoreError!,
              style: const TextStyle(color: Colors.orangeAccent)),
      ],
      const SizedBox(height: 16),
      FilledButton(
        onPressed: () {
          context.read<CloudSyncService>().cancelPairing();
          Navigator.of(context).pop();
        },
        child: Text(S.of('common.done')),
      ),
    ];
  }

  List<Widget> _terminal(CloudSyncService cs, String msg,
      {required bool retry}) {
    return [
      Text(msg, style: const TextStyle(color: Colors.orangeAccent)),
      const SizedBox(height: 16),
      if (retry)
        FilledButton(
          onPressed: () => context.read<CloudSyncService>().cancelPairing(),
          child: Text(S.of('pairing.retry')),
        ),
    ];
  }
}

/// v0.1.42+141: private copy of settings.dart:_deviceMeLine (file-
/// private there; the small duplicate beats a new cross-file public
/// symbol — the +139 _relTime precedent). Same keys, same dictionary.
String _pairedIdentityLine(CloudSyncService cs) {
  if (cs.deviceMeFetchedAt == null) return S.of('cloud.device_me.unknown');
  if (cs.deviceMeLinked == false) return S.of('cloud.device_me.not_linked');
  final email = cs.deviceMeEmail ?? '?';
  final String st;
  switch (cs.deviceMeStatus) {
    case 'pending':
      st = S.of('cloud.status.pending_approval');
    case 'approved':
      st = S.of('cloud.device_me.approved');
    case 'rejected':
    case 'blocked':
      st = S.of('cloud.status.access_denied');
    default:
      st = cs.deviceMeStatus ?? '—';
  }
  return '${S.of('cloud.device_me.linked').replaceFirst('{email}', email)}'
      ' · $st';
}
