import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:provider/provider.dart';

import '../services/connection.dart';
import 'about.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  List<ScanResult> _devices = [];
  bool _scanning = false;

  @override
  Widget build(BuildContext context) {
    final svc = context.watch<ConnectionService>();
    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: ListView(
        children: [
          _StatusTile(svc: svc),
          const Divider(),
          ListTile(
            title: const Text('ELM327 BLE adapter'),
            subtitle: Text(svc.adapterAddress ?? 'Не подключен'),
          ),
          if (svc.status != ConnectionStatus.connected) ...[
            Padding(
              padding: const EdgeInsets.all(16),
              child: ElevatedButton.icon(
                icon: _scanning
                    ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                    : const Icon(Icons.bluetooth_searching),
                label: Text(_scanning ? 'Поиск...' : 'Найти адаптер'),
                onPressed: _scanning ? null : () => _scan(svc),
              ),
            ),
            ..._devices.map((d) => _DeviceTile(result: d, onTap: () => _connect(svc, d))),
          ] else ...[
            ListTile(
              leading: const Icon(Icons.link_off, color: Colors.red),
              title: const Text('Disconnect'),
              onTap: () => svc.disconnect(),
            ),
          ],
          const Divider(),
          ListTile(
            leading: const Icon(Icons.info_outline,
                color: Colors.lightBlueAccent),
            title: const Text('About / Pack specification'),
            subtitle: const Text(
                'BZ5 battery pack details, DID sources, experiments'),
            trailing: const Icon(Icons.chevron_right, color: Colors.grey),
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute(
                builder: (_) => const AboutScreen(),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _scan(ConnectionService svc) async {
    setState(() {
      _scanning = true;
      _devices = [];
    });
    final found = await svc.scanForAdapters();
    setState(() {
      _devices = found;
      _scanning = false;
    });
  }

  Future<void> _connect(ConnectionService svc, ScanResult r) async {
    final ok = await svc.connect(r.device);
    if (ok && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Подключено! Перейдите на Dashboard')),
      );
    }
  }
}

class _StatusTile extends StatelessWidget {
  final ConnectionService svc;
  const _StatusTile({required this.svc});

  @override
  Widget build(BuildContext context) {
    final color = switch (svc.status) {
      ConnectionStatus.connected => Colors.green,
      ConnectionStatus.connecting || ConnectionStatus.scanning => Colors.orange,
      ConnectionStatus.error => Colors.red,
      _ => Colors.grey,
    };
    final icon = switch (svc.status) {
      ConnectionStatus.connected => Icons.check_circle,
      ConnectionStatus.connecting || ConnectionStatus.scanning => Icons.sync,
      ConnectionStatus.error => Icons.error,
      _ => Icons.circle_outlined,
    };

    return ListTile(
      leading: Icon(icon, color: color, size: 28),
      title: Text(svc.status.name.toUpperCase(),
          style: TextStyle(color: color, fontWeight: FontWeight.w500)),
      subtitle: Text(svc.statusMessage ?? '—'),
    );
  }
}

class _DeviceTile extends StatelessWidget {
  final ScanResult result;
  final VoidCallback onTap;

  const _DeviceTile({required this.result, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final name = result.advertisementData.advName.isEmpty
        ? '<unknown>'
        : result.advertisementData.advName;
    return ListTile(
      leading: const Icon(Icons.bluetooth, color: Colors.blue),
      title: Text(name),
      subtitle: Text('${result.device.remoteId.str}\nRSSI: ${result.rssi}'),
      isThreeLine: true,
      onTap: onTap,
    );
  }
}
