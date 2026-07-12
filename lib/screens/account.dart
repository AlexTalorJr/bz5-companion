import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../l10n/strings.dart';
import '../services/account_auth_service.dart';
import '../services/cloud_sync_service.dart';
import '../services/locale_service.dart';
import '../widgets/vehicle_descriptor_picker.dart';

/// v0.1.29+124 (C2): Account screen — email-OTP sign-in (CLIENT_API §1.1)
/// and device management (§1.3).
///
/// UX rules encoded here (per the server operator's checklist):
///   * Anti-enumeration: after requesting a code the copy stays neutral
///     ("if the address is allowed — a code was sent") + spam-folder hint.
///     A 200 never confirms delivery.
///   * Resend cooldown (60 s) with a "new code voids the previous one"
///     note — only the freshest code is alive server-side.
///   * 429 → both buttons lock with a visible countdown.
///   * 403 not_allowed / 503 auth_not_configured → clear human wording.
///   * refresh_reused (session revoked server-side) surfaces as a
///     "please sign in again" banner, never a crash loop (C6).
class AccountScreen extends StatefulWidget {
  const AccountScreen({super.key});

  @override
  State<AccountScreen> createState() => _AccountScreenState();
}

class _AccountScreenState extends State<AccountScreen> {
  final _emailCtrl = TextEditingController();
  final _codeCtrl = TextEditingController();
  final _claimCtrl = TextEditingController(); // v0.1.29+127 (C3)
  bool _claiming = false;
  Timer? _ticker;
  bool _devicesRequested = false;

  // v0.1.29+127 (C3): approve a pairing request by user_code.
  Future<void> _claim() async {
    final code = _claimCtrl.text.trim();
    if (code.isEmpty) return;
    setState(() => _claiming = true);
    final err =
        await context.read<AccountAuthService>().claimPairing(code);
    if (!mounted) return;
    setState(() => _claiming = false);
    if (err == null) {
      _claimCtrl.clear();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(S.of('account.claim_ok'))),
      );
    } else {
      final msg = err == 'pairing_invalid'
          ? S.of('account.claim_invalid')
          : err == 'no_vehicle'
              ? S.of('account.claim_no_vehicle')
              : '${S.of('account.err_generic')} ($err)';
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(msg)),
      );
    }
  }

  @override
  void initState() {
    super.initState();
    final auth = context.read<AccountAuthService>();
    _emailCtrl.text = auth.email ?? '';
    // 1 Hz repaint drives the resend / rate-limit countdowns. Cheap and
    // dumb beats a pile of per-deadline timers.
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _ticker?.cancel();
    _emailCtrl.dispose();
    _codeCtrl.dispose();
    _claimCtrl.dispose(); // v0.1.29+127 (C3)
    super.dispose();
  }

  String _errorText(AccountAuthService auth) {
    final code = auth.lastErrorCode;
    if (code == null) return '';
    switch (code) {
      case 'invalid_code':
        return S.of('account.err_invalid_code');
      case 'not_allowed':
        return S.of('account.err_not_allowed');
      case 'rate_limited':
        return S.of('account.err_rate_limited');
      case 'auth_not_configured':
        return S.of('account.err_not_configured');
      case 'refresh_reused':
      case 'session':
        return S.of('account.err_session');
      case 'bad_email':
        return S.of('account.err_bad_email');
      case 'network':
        return S.of('account.err_network');
      default:
        return '${S.of('account.err_generic')} ($code)';
    }
  }

  @override
  Widget build(BuildContext context) {
    context.watch<LocaleService>();
    final auth = context.watch<AccountAuthService>();

    // Auto-load devices once per signed-in visit.
    if (auth.isSignedIn && !_devicesRequested && !auth.devicesLoading) {
      _devicesRequested = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) context.read<AccountAuthService>().fetchDevices();
      });
    }
    if (!auth.isSignedIn) _devicesRequested = false;

    final List<Widget> body;
    if (!auth.isInitialized) {
      body = [
        Text(S.of('common.loading'),
            style: const TextStyle(color: Colors.grey)),
      ];
    } else if (auth.status == AccountAuthStatus.codeSent) {
      body = _codeStep(auth);
    } else if (auth.status == AccountAuthStatus.signedIn) {
      body = _signedIn(auth);
    } else {
      // signedOut and authNotConfigured share the email step; the
      // latter shows its explanation through the error banner.
      body = _emailStep(auth);
    }

    return Scaffold(
      appBar: AppBar(title: Text(S.of('account.title'))),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: body,
      ),
    );
  }

  // ── step 1: email ──
  List<Widget> _emailStep(AccountAuthService auth) {
    final locked = auth.lockSecondsLeft > 0;
    final err = _errorText(auth);
    return [
      Text(S.of('account.intro'),
          style: const TextStyle(color: Colors.grey, fontSize: 13)),
      const SizedBox(height: 12),
      TextField(
        controller: _emailCtrl,
        keyboardType: TextInputType.emailAddress,
        autocorrect: false,
        decoration: InputDecoration(
          labelText: S.of('account.email_hint'),
          border: const OutlineInputBorder(),
        ),
      ),
      const SizedBox(height: 12),
      FilledButton(
        onPressed: auth.busy || locked
            ? null
            : () => context
                .read<AccountAuthService>()
                .requestOtp(_emailCtrl.text),
        child: Text(locked
            ? '${S.of('account.locked_for')} ${auth.lockSecondsLeft}s'
            : S.of('account.send_code')),
      ),
      if (err.isNotEmpty) ...[
        const SizedBox(height: 8),
        Text(err, style: const TextStyle(color: Colors.orangeAccent)),
      ],
    ];
  }

  // ── step 2: code ──
  List<Widget> _codeStep(AccountAuthService auth) {
    final resendLeft = auth.resendSecondsLeft;
    final locked = auth.lockSecondsLeft > 0;
    final err = _errorText(auth);
    return [
      // Neutral by design (anti-enumeration): never claims the mail
      // actually went out, always points at the spam folder.
      Text(
        S
            .of('account.code_sent_neutral')
            .replaceFirst('{email}', auth.email ?? ''),
        style: const TextStyle(color: Colors.grey, fontSize: 13),
      ),
      const SizedBox(height: 12),
      TextField(
        controller: _codeCtrl,
        keyboardType: TextInputType.number,
        maxLength: 6,
        decoration: InputDecoration(
          labelText: S.of('account.code_hint'),
          border: const OutlineInputBorder(),
          counterText: '',
        ),
      ),
      const SizedBox(height: 12),
      FilledButton(
        onPressed: auth.busy
            ? null
            : () =>
                context.read<AccountAuthService>().verifyOtp(_codeCtrl.text),
        child: Text(S.of('account.verify')),
      ),
      const SizedBox(height: 8),
      OutlinedButton(
        onPressed: auth.busy || locked || resendLeft > 0
            ? null
            : () => context
                .read<AccountAuthService>()
                .requestOtp(auth.email ?? _emailCtrl.text),
        child: Text(locked
            ? '${S.of('account.locked_for')} ${auth.lockSecondsLeft}s'
            : resendLeft > 0
                ? '${S.of('account.resend_in')} ${resendLeft}s'
                : S.of('account.resend')),
      ),
      const SizedBox(height: 4),
      Text(S.of('account.resend_note'),
          style: const TextStyle(color: Colors.grey, fontSize: 12)),
      TextButton(
        onPressed: auth.busy
            ? null
            : () => context.read<AccountAuthService>().restartEmailStep(),
        child: Text(S.of('account.change_email')),
      ),
      if (err.isNotEmpty)
        Text(err, style: const TextStyle(color: Colors.orangeAccent)),
    ];
  }

  // ── signed in ──
  // v0.1.35+134: vehicle descriptor editor. The picker persists every
  // complete selection itself — the dialog only needs a Close button.
  Future<void> _showVehicleDialog(BuildContext context) {
    return showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(S.of('account.my_vehicle')),
        content: const SingleChildScrollView(
          child: SizedBox(width: 420, child: VehicleDescriptorPicker()),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: Text(S.of('common.close')),
          ),
        ],
      ),
    );
  }

  List<Widget> _signedIn(AccountAuthService auth) {
    final err = _errorText(auth);
    return [
      ListTile(
        contentPadding: EdgeInsets.zero,
        leading: const Icon(Icons.account_circle_outlined,
            color: Colors.lightBlueAccent),
        title: Text(auth.email ?? '—'),
        subtitle: Text(S.of('account.signed_in_as')),
        trailing: OutlinedButton(
          onPressed: auth.busy
              ? null
              : () => context.read<AccountAuthService>().logout(),
          child: Text(S.of('account.logout')),
        ),
      ),
      if (err.isNotEmpty)
        Text(err, style: const TextStyle(color: Colors.orangeAccent)),
      // v0.1.35+134: user-declared vehicle (sent on pair/start as the
      // self-service provisioning descriptor). Editable here so a wrong
      // pick at pairing time is fixable without re-pairing.
      Builder(builder: (context) {
        final cs = context.watch<CloudSyncService>();
        final subtitle = cs.hasVehicleDescriptor
            ? '${cs.vehDescMake} ${cs.vehDescModel}'
                '${cs.vehDescName != null ? ' — ${cs.vehDescName}' : ''}'
            : S.of('vehicle.not_set');
        return ListTile(
          contentPadding: EdgeInsets.zero,
          leading: const Icon(Icons.directions_car_outlined,
              color: Colors.lightBlueAccent),
          title: Text(S.of('account.my_vehicle')),
          subtitle: Text(subtitle),
          trailing: const Icon(Icons.edit_outlined, size: 18),
          onTap: () => _showVehicleDialog(context),
        );
      }),
      const Divider(height: 24),
      // v0.1.29+127 (C3): approve a device's pairing request — type the
      // short code the device shows (§1.2). Success auto-refreshes the
      // devices list below.
      Text(S.of('account.claim_header'),
          style: Theme.of(context).textTheme.titleMedium),
      const SizedBox(height: 4),
      Text(S.of('account.claim_hint'),
          style: const TextStyle(color: Colors.grey, fontSize: 12)),
      const SizedBox(height: 8),
      Row(
        children: [
          Expanded(
            child: TextField(
              controller: _claimCtrl,
              maxLength: 8,
              textCapitalization: TextCapitalization.characters,
              decoration: InputDecoration(
                labelText: S.of('account.claim_code_hint'),
                border: const OutlineInputBorder(),
                counterText: '',
              ),
            ),
          ),
          const SizedBox(width: 8),
          FilledButton(
            onPressed: _claiming ? null : _claim,
            child: _claiming
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2))
                : Text(S.of('account.claim_button')),
          ),
        ],
      ),
      const Divider(height: 24),
      Row(
        children: [
          Expanded(
            child: Text(S.of('account.devices_header'),
                style: Theme.of(context).textTheme.titleMedium),
          ),
          IconButton(
            icon: auth.devicesLoading
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.refresh),
            onPressed: auth.devicesLoading
                ? null
                : () => context.read<AccountAuthService>().fetchDevices(),
          ),
        ],
      ),
      if (auth.devicesError != null)
        Text('${S.of('account.err_generic')} (${auth.devicesError})',
            style: const TextStyle(color: Colors.orangeAccent)),
      if (!auth.devicesLoading && auth.devices.isEmpty &&
          auth.devicesError == null)
        Text(S.of('account.devices_empty'),
            style: const TextStyle(color: Colors.grey)),
      for (final d in auth.devices) _deviceTile(d),
    ];
  }

  Widget _deviceTile(AccountDevice d) {
    final revoked = d.revokedAt != null;
    final hb = d.lastHeartbeatAt;
    final hbStr = hb == null ? '—' : hb.toString().substring(0, 16);
    return Card(
      child: ListTile(
        leading: Icon(
          d.kind == 'headunit' ? Icons.directions_car : Icons.smartphone,
          color: revoked ? Colors.grey : Colors.lightBlueAccent,
        ),
        title: Text(d.displayName ?? d.kind ?? d.id),
        subtitle: Text(
          '${d.kind ?? '?'} · ${d.lastClientVersion ?? '—'} · '
          '${S.of('account.last_heartbeat')}: $hbStr'
          '${revoked ? ' · ${S.of('account.revoked')}' : ''}',
          style: const TextStyle(fontSize: 12),
        ),
        trailing: revoked
            ? null
            : TextButton(
                onPressed: () => _confirmRevoke(d),
                child: Text(S.of('account.revoke'),
                    style: const TextStyle(color: Colors.redAccent)),
              ),
      ),
    );
  }

  Future<void> _confirmRevoke(AccountDevice d) async {
    final yes = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(S.of('account.revoke_confirm_title')),
        content: Text(S
            .of('account.revoke_confirm_body')
            .replaceFirst('{name}', d.displayName ?? d.id)),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text(S.of('common.cancel')),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text(S.of('account.revoke')),
          ),
        ],
      ),
    );
    if (yes == true && mounted) {
      await context.read<AccountAuthService>().revokeDevice(d.id);
    }
  }
}
