import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../data/database.dart';
import '../services/connection.dart';
import '../services/export_service.dart';

/// v0.1.11: Data management screen — export all data to share sheet,
/// or clear specific tables when storage starts filling up.
///
/// v0.1.13: added "Save to Downloads" path for Toyota head unit where the
/// system share sheet has no registered handlers (no Telegram/Drive/etc.
/// available). Direct write to /storage/emulated/0/Download/ works there.
///
/// Sections:
///   STORAGE — live counts of trips / snapshots / samples / sweep_runs
///   EXPORT  — toggles + two buttons:
///             "Поделиться" → system share sheet (phone-friendly)
///             "Сохранить в Downloads" → straight to public Downloads folder
///   CLEANUP — four destructive actions with confirmation dialogs
class DataManagementScreen extends StatefulWidget {
  const DataManagementScreen({super.key});

  @override
  State<DataManagementScreen> createState() => _DataManagementScreenState();
}

class _DataManagementScreenState extends State<DataManagementScreen> {
  bool _includeTrips = true;
  bool _includeSnapshots = true;
  bool _includeSamples = true;
  bool _includeSweeps = true;

  bool _exporting = false;
  String _stage = '';
  String? _lastResult;

  // Counts shown in UI — fetched on init & after any clear.
  Map<String, int>? _counts;
  bool _loadingCounts = true;

  @override
  void initState() {
    super.initState();
    _refreshCounts();
  }

  Future<void> _refreshCounts() async {
    setState(() => _loadingCounts = true);
    final db = context.read<ConnectionService>().db;
    final counts = {
      'trips': (await db.getAllTrips()).length,
      'snapshots': await db.countAllSnapshots(),
      'samples': await db.countAllSamples(),
      'sweep_runs': await db.countAllSweepRuns(),
    };
    if (!mounted) return;
    setState(() {
      _counts = counts;
      _loadingCounts = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final svc = context.watch<ConnectionService>();
    return Scaffold(
      appBar: AppBar(title: const Text('Data & Export')),
      body: ListView(
        padding: const EdgeInsets.symmetric(vertical: 8),
        children: [
          _section('STORAGE'),
          if (_loadingCounts)
            const ListTile(
              leading: SizedBox(
                width: 18, height: 18,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
              title: Text('Подсчёт...'),
            )
          else if (_counts != null) ...[
            ListTile(
              dense: true,
              leading: const Icon(Icons.route, size: 20),
              title: const Text('Trips'),
              trailing: Text('${_counts!['trips']}',
                  style: const TextStyle(
                      fontFeatures: [FontFeature.tabularFigures()])),
            ),
            ListTile(
              dense: true,
              leading: const Icon(Icons.timeline, size: 20),
              title: const Text('Snapshots'),
              trailing: Text('${_counts!['snapshots']}',
                  style: const TextStyle(
                      fontFeatures: [FontFeature.tabularFigures()])),
            ),
            ListTile(
              dense: true,
              leading: const Icon(Icons.dns, size: 20),
              title: const Text('Raw samples'),
              trailing: Text('${_counts!['samples']}',
                  style: const TextStyle(
                      fontFeatures: [FontFeature.tabularFigures()])),
            ),
            ListTile(
              dense: true,
              leading: const Icon(Icons.search, size: 20),
              title: const Text('Sweep runs'),
              trailing: Text('${_counts!['sweep_runs']}',
                  style: const TextStyle(
                      fontFeatures: [FontFeature.tabularFigures()])),
            ),
          ],

          const Divider(),
          _section('EXPORT'),
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 4, 16, 8),
            child: Text(
              'Создаёт zip-архив со всеми выбранными данными и открывает '
              'системное меню "Поделиться". Можно сохранить файл через '
              '"Проводник" на флешку, отправить в облако или мессенджер.',
              style: TextStyle(fontSize: 12, color: Colors.grey),
            ),
          ),
          SwitchListTile(
            value: _includeTrips,
            onChanged: _exporting ? null : (v) => setState(() => _includeTrips = v),
            secondary: const Icon(Icons.route),
            title: const Text('Trips'),
            subtitle: const Text('trips.csv — открывается в Excel/Numbers'),
            dense: true,
          ),
          SwitchListTile(
            value: _includeSnapshots,
            onChanged: _exporting
                ? null
                : (v) => setState(() => _includeSnapshots = v),
            secondary: const Icon(Icons.timeline),
            title: const Text('Snapshots'),
            subtitle:
                const Text('snapshots.csv — данные для долговременных графиков'),
            dense: true,
          ),
          SwitchListTile(
            value: _includeSamples,
            onChanged: _exporting
                ? null
                : (v) => setState(() => _includeSamples = v),
            secondary: const Icon(Icons.dns),
            title: const Text('Raw samples'),
            subtitle: const Text(
                'samples.sqlite — бинарный дамп БД (компактно), '
                'открывается в DB Browser'),
            dense: true,
          ),
          SwitchListTile(
            value: _includeSweeps,
            onChanged: _exporting ? null : (v) => setState(() => _includeSweeps = v),
            secondary: const Icon(Icons.search),
            title: const Text('Sweep results'),
            subtitle: const Text('sweep_runs.csv + sweep_results.csv'),
            dense: true,
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
            child: ElevatedButton.icon(
              icon: _exporting
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.ios_share),
              label: Text(_exporting
                  ? 'Экспорт: $_stage...'
                  : 'Поделиться (Share)'),
              style: ElevatedButton.styleFrom(
                minimumSize: const Size.fromHeight(48),
              ),
              onPressed: _exporting ? null : () => _doExport(svc, toDownloads: false),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
            child: OutlinedButton.icon(
              icon: const Icon(Icons.download),
              label: Text(_exporting
                  ? 'Экспорт: $_stage...'
                  : 'Сохранить в Downloads'),
              style: OutlinedButton.styleFrom(
                minimumSize: const Size.fromHeight(48),
              ),
              onPressed: _exporting ? null : () => _doExport(svc, toDownloads: true),
            ),
          ),
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: Text(
              'На головном устройстве выбирайте «Сохранить в Downloads» — '
              'файл появится в системной папке Downloads, откуда его можно '
              'открыть через «Проводник» и скопировать на флешку. На телефоне '
              'удобнее «Поделиться».',
              style: TextStyle(fontSize: 11, color: Colors.grey),
            ),
          ),
          if (_lastResult != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
              child: Text(_lastResult!,
                  style: const TextStyle(
                      fontSize: 12, color: Colors.greenAccent)),
            ),

          const Divider(),
          _section('CLEANUP'),
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 4, 16, 8),
            child: Text(
              'Удаление данных безвозвратно. Перед очисткой рекомендуем '
              'сделать экспорт.',
              style: TextStyle(fontSize: 12, color: Colors.orangeAccent),
            ),
          ),
          ListTile(
            leading: const Icon(Icons.delete_outline, color: Colors.orangeAccent),
            title: const Text('Очистить raw samples'),
            subtitle:
                const Text('Удалить все детальные measurements (история DID)'),
            onTap: () => _confirmAndClear(
              title: 'Удалить все raw samples?',
              description:
                  'Trips и Snapshots сохранятся, но детальные measurements '
                  'будут утеряны. Это самая объёмная таблица.',
              action: () async {
                final n = await svc.db.clearAllSamples();
                return '$n samples удалено';
              },
            ),
          ),
          ListTile(
            leading: const Icon(Icons.delete_outline, color: Colors.orangeAccent),
            title: const Text('Очистить snapshots'),
            subtitle: const Text('Очистит долговременные графики (Trends)'),
            onTap: () => _confirmAndClear(
              title: 'Удалить все snapshots?',
              description:
                  'Trends графики (24h / 7d / 30d / 1y / all) будут пустыми. '
                  'Данные начнут накапливаться заново через 2-10 минут.',
              action: () async {
                final n = await svc.db.clearAllSnapshots();
                return '$n snapshots удалено';
              },
            ),
          ),
          ListTile(
            leading: const Icon(Icons.delete_forever, color: Colors.redAccent),
            title: const Text('Очистить все trips'),
            subtitle: const Text('Удаляет trips + связанные samples (cascade)'),
            onTap: () => _confirmAndClear(
              title: 'Удалить все trips и samples?',
              description:
                  'История поездок и все measurements в них будут утеряны. '
                  'Snapshots останутся.',
              action: () async {
                final (trips, samples) = await svc.db.clearAllTrips();
                return '$trips trips и $samples samples удалено';
              },
            ),
          ),
          ListTile(
            leading: const Icon(Icons.delete_outline, color: Colors.orangeAccent),
            title: const Text('Очистить sweep results'),
            subtitle: const Text('Удалит логи всех DID-сканирований'),
            onTap: () => _confirmAndClear(
              title: 'Удалить все sweep results?',
              description:
                  'История in-car DID сканирований будет утеряна. Может быть '
                  'полезно если sweep results занимают много места.',
              action: () async {
                final (runs, results) = await svc.db.clearAllSweeps();
                return '$runs runs и $results results удалено';
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _section(String title) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
        child: Text(title,
            style: const TextStyle(
                fontSize: 11,
                letterSpacing: 1.5,
                color: Colors.grey,
                fontWeight: FontWeight.w500)),
      );

  Future<void> _doExport(ConnectionService svc, {required bool toDownloads}) async {
    setState(() {
      _exporting = true;
      _stage = 'init';
      _lastResult = null;
    });

    try {
      final exporter = ExportService(svc.db);
      final result = toDownloads
          ? await exporter.exportToDownloads(
              includeTrips: _includeTrips,
              includeSnapshots: _includeSnapshots,
              includeSamples: _includeSamples,
              includeSweeps: _includeSweeps,
              onProgress: (stage) {
                if (mounted) setState(() => _stage = stage);
              },
            )
          : await exporter.exportAll(
              includeTrips: _includeTrips,
              includeSnapshots: _includeSnapshots,
              includeSamples: _includeSamples,
              includeSweeps: _includeSweeps,
              onProgress: (stage) {
                if (mounted) setState(() => _stage = stage);
              },
            );
      if (!mounted) return;
      final summary = result.counts.entries
          .where((e) => e.value > 0)
          .map((e) => '${e.key}=${e.value}')
          .join(', ');
      setState(() {
        if (result.destinationKind == ExportDestinationKind.downloads) {
          _lastResult = 'Сохранено (${result.humanSize}): $summary\n'
              'Путь: ${result.zipPath}';
        } else {
          _lastResult = result.sharedSuccessfully
              ? 'Поделено (${result.humanSize}): $summary'
              : 'Архив создан (${result.humanSize}): $summary. Поделиться отменено.';
        }
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _lastResult = 'Ошибка: $e');
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Export failed: $e')),
      );
    } finally {
      if (mounted) {
        setState(() {
          _exporting = false;
          _stage = '';
        });
      }
    }
  }

  Future<void> _confirmAndClear({
    required String title,
    required String description,
    required Future<String> Function() action,
  }) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: Text(title),
        content: Text(description),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Отмена'),
          ),
          TextButton(
            style: TextButton.styleFrom(foregroundColor: Colors.redAccent),
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Удалить'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    try {
      final result = await action();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(result)),
      );
      await _refreshCounts();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Ошибка: $e')),
      );
    }
  }
}
