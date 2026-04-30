import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../data/ecu_registry.dart';
import '../services/connection.dart';

class EcuExplorerScreen extends StatelessWidget {
  const EcuExplorerScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('All ECUs (30)')),
      body: ListView.builder(
        itemCount: allBz5Ecus.length,
        itemBuilder: (context, i) {
          final entry = allBz5Ecus[i];
          return Card(
            margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
            child: ListTile(
              leading: CircleAvatar(
                backgroundColor: entry.detailed != null ? Colors.blue : Colors.grey.shade800,
                child: Text(entry.txId.substring(1, 3),
                    style: const TextStyle(fontSize: 12)),
              ),
              title: Text('${entry.txId} → ${entry.rxId}'),
              subtitle: Text(entry.label),
              trailing: entry.detailed != null
                  ? const Icon(Icons.chevron_right)
                  : const Icon(Icons.help_outline, color: Colors.grey),
              onTap: entry.detailed == null ? null : () {
                Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) => _EcuDetailScreen(spec: entry.detailed!),
                  ),
                );
              },
            ),
          );
        },
      ),
    );
  }
}

class _EcuDetailScreen extends StatelessWidget {
  final EcuSpec spec;
  const _EcuDetailScreen({required this.spec});

  @override
  Widget build(BuildContext context) {
    final svc = context.watch<ConnectionService>();
    final values = svc.latestValues[spec.txId] ?? {};

    return Scaffold(
      appBar: AppBar(
        title: Text('${spec.name} ${spec.txId}→${spec.rxId}'),
      ),
      body: ListView.builder(
        itemCount: spec.dids.length,
        itemBuilder: (context, i) {
          final d = spec.dids[i];
          final val = values[d.did];
          return ListTile(
            dense: true,
            leading: SizedBox(
              width: 48,
              child: Text(d.did,
                  style: const TextStyle(fontFamily: 'monospace', color: Colors.lightBlueAccent)),
            ),
            title: Text(d.name),
            subtitle: d.notes != null
                ? Text(d.notes!, style: const TextStyle(fontSize: 11, color: Colors.grey))
                : null,
            trailing: val == null
                ? const Text('—', style: TextStyle(color: Colors.grey))
                : Text(val.display,
                    style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w500)),
          );
        },
      ),
    );
  }
}
