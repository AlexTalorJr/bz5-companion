import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../l10n/strings.dart';
import '../services/cloud_sync_service.dart';
import '../services/locale_service.dart';

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
      FilledButton.icon(
        icon: busy
            ? const SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(strokeWidth: 2))
            : const Icon(Icons.qr_code_2),
        label: Text(S.of('pairing.get_code')),
        onPressed: busy
            ? null
            : () => context
                .read<CloudSyncService>()
                .startPairing(kind: _kind),
      ),
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
