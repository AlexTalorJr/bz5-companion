import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../data/database.dart';
import '../services/connection.dart';

class HistoryScreen extends StatelessWidget {
  const HistoryScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final svc = context.watch<ConnectionService>();
    return Scaffold(
      appBar: AppBar(title: const Text('Trip history')),
      body: FutureBuilder<List<Trip>>(
        future: svc.db.getRecentTrips(),
        builder: (context, snapshot) {
          if (!snapshot.hasData) {
            return const Center(child: CircularProgressIndicator());
          }
          final trips = snapshot.data!;
          if (trips.isEmpty) {
            return const Center(child: Text('Поездок пока нет'));
          }
          return ListView.builder(
            itemCount: trips.length,
            itemBuilder: (context, i) {
              final t = trips[i];
              final duration = (t.endedAt ?? DateTime.now()).difference(t.startedAt);
              final dateStr = DateFormat('d MMM HH:mm').format(t.startedAt);
              final distanceKm = (t.endOdometer != null && t.startOdometer != null)
                  ? (t.endOdometer! - t.startOdometer!).abs()
                  : null;
              final socUsed = (t.endSoc != null && t.startSoc != null)
                  ? (t.startSoc! - t.endSoc!)
                  : null;
              return Card(
                margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                child: ListTile(
                  leading: CircleAvatar(
                    backgroundColor: t.endedAt == null ? Colors.green : Colors.blueGrey,
                    child: Icon(t.endedAt == null ? Icons.fiber_manual_record : Icons.history,
                        color: Colors.white),
                  ),
                  title: Text(dateStr),
                  subtitle: Text(
                    '${_fmtDuration(duration)}'
                    '${distanceKm != null ? ' · ${distanceKm.toStringAsFixed(1)} km' : ''}'
                    '${socUsed != null ? ' · -${socUsed.toStringAsFixed(0)}% SOC' : ''}'
                    ' · ${t.sampleCount} samples',
                  ),
                  trailing: Text('#${t.id}', style: const TextStyle(color: Colors.grey)),
                ),
              );
            },
          );
        },
      ),
    );
  }

  String _fmtDuration(Duration d) {
    if (d.inHours > 0) return '${d.inHours}h ${d.inMinutes % 60}m';
    return '${d.inMinutes}m ${d.inSeconds % 60}s';
  }
}
