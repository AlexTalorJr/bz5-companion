import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../l10n/strings.dart';
import '../services/apk_install_channel.dart';
import '../services/diag_dump_file.dart';
import '../services/locale_service.dart';
import 'dashboard.dart' show kAppVersion;

/// v0.1.73+172 — «Путь установки».
///
/// ЗАЧЕМ ЭКРАН СУЩЕСТВУЕТ. Обновиться на ГУ нечем. Штатный проводник
/// APK не запускает, ADB нет, а SilentInstaller на уже установленный
/// пакет отвечает `系统已安装` и засчитывает это себе в УСПЕХ — то есть
/// до установки дело не доходит вовсе. На телефоне тот же APK с той же
/// подписью и тем же versionCode встаёт поверх без вопросов, значит
/// причина не в пакете. Остаётся ставить самим.
///
/// Цена вопроса не в удобстве: пока обновление идёт через удаление,
/// КАЖДЫЙ патч стирает prefs и Drift. Из облака возвращаются поездки,
/// снимки, откровения и trip_series, но НЕ возвращаются
/// samples/hal_samples и недобранные полосы атласа.
///
/// ДВА БЛОКА, И ОБА НУЖНЫ В ОДНОЙ СБОРКЕ. Проба (только чтение)
/// отвечает, есть ли на прошивке системный установщик вообще: если его
/// вырезали, никакая кнопка не поможет, и знать это надо ДО того, как
/// строить скачивание из GitHub Releases. Попытка отвечает, работает
/// ли он на самом деле. Проба без попытки объяснит отказ, но не
/// докажет успех; попытка без пробы в случае отказа не скажет почему.
/// Один цикл установки должен закрыть вопрос целиком — а цикл здесь
/// стоит полного стирания данных.
///
/// Dev-поверхность: технические строки (имена резолверов, шаги) не
/// переводятся по правилу проекта, переводится только обвязка.
///
/// Живёт в Настройки → Расширенные (решение владельца 29.07).
class InstallUpdateScreen extends StatefulWidget {
  const InstallUpdateScreen({super.key});

  @override
  State<InstallUpdateScreen> createState() => _InstallUpdateScreenState();
}

class _InstallUpdateScreenState extends State<InstallUpdateScreen> {
  Map<String, dynamic>? _probe;
  bool _busy = false;
  String? _stagedName;
  int _stagedBytes = 0;
  final List<String> _log = <String>[];

  @override
  void initState() {
    super.initState();
    _runProbe();
  }

  void _say(String line) {
    if (!mounted) return;
    setState(() => _log.insert(0, line));
  }

  Future<void> _runProbe() async {
    setState(() => _busy = true);
    final p = await ApkInstallChannel.probe();
    if (!mounted) return;
    setState(() {
      _probe = p;
      _busy = false;
    });
  }

  Future<void> _pickAndStage() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final picked = await ApkInstallChannel.pick();
      if (picked['ok'] != true) {
        _say('pick → ${picked['error'] ?? 'no file'}');
        return;
      }
      _say('pick → ${picked['uri']}');
      final staged = await ApkInstallChannel.stage('${picked['uri']}');
      if (staged['ok'] != true) {
        _say('stage → ${staged['error']}');
        return;
      }
      if (!mounted) return;
      setState(() {
        _stagedName = '${staged['source_name'] ?? '?'}';
        _stagedBytes = (staged['bytes'] as num?)?.toInt() ?? 0;
      });
      _say('stage → $_stagedName, $_stagedBytes B');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _launch() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final res = await ApkInstallChannel.launch();
      for (final s in (res['steps'] as List<dynamic>? ?? <dynamic>[])) {
        _say('$s');
      }
      _say(res['ok'] == true
          ? 'installer opened via ${res['action']}'
          : 'installer did not open');
      // Проба перечитывается: разрешение могли выдать между попытками,
      // и показывать устаревшее «нет» после успешной выдачи — врать.
      await _runProbe();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _export() async {
    final body = const JsonEncoder.withIndent('  ').convert(<String, dynamic>{
      'probe': _probe ?? <String, dynamic>{},
      'log': _log.reversed.toList(),
    });
    final res = await DiagDumpFile.instance.append(
      title: 'Install path probe — $kAppVersion',
      body: '```json\n$body\n```',
    );
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('${S.of('install.exported')} ${res.path}')),
    );
  }

  @override
  Widget build(BuildContext context) {
    // Перерисовка при смене языка (правило проекта X4 — каждый экран
    // с S.of подписан на LocaleService, чтобы строки менялись без
    // повторного захода).
    context.watch<LocaleService>();
    final p = _probe;
    final canInstall = p?['can_request_installs'] == true;
    final viewers = (p?['view_resolvers'] as List<dynamic>? ?? <dynamic>[]);
    final installers =
        (p?['install_resolvers'] as List<dynamic>? ?? <dynamic>[]);
    final pickers =
        (p?['open_document_resolvers'] as List<dynamic>? ?? <dynamic>[]);
    // Единственный вывод, который экран делает сам, и он намеренно
    // осторожный: путь ЕСТЬ, если хоть одно действие кем-то принято.
    // Утверждать по этому, что установка пройдёт, нельзя — это скажет
    // только сама попытка.
    final anyRoute = viewers.isNotEmpty || installers.isNotEmpty;

    return Scaffold(
      appBar: AppBar(title: Text(S.of('install.title'))),
      body: ListView(
        padding: const EdgeInsets.all(14),
        children: [
          Card(
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(S.of('install.probe.title'),
                      style: const TextStyle(
                          fontSize: 16, fontWeight: FontWeight.w600)),
                  const SizedBox(height: 8),
                  _row('can_request_installs', '$canInstall',
                      bad: !canInstall),
                  _row('ACTION_VIEW resolvers', '${viewers.length}',
                      bad: viewers.isEmpty),
                  _row('ACTION_INSTALL_PACKAGE resolvers',
                      '${installers.length}'),
                  _row('ACTION_OPEN_DOCUMENT resolvers', '${pickers.length}',
                      bad: pickers.isEmpty),
                  _row('installer packages',
                      '${(p?['installer_packages'] as List<dynamic>? ?? const []).length}'),
                  _row('sdk', '${p?['sdk'] ?? '?'}'),
                  const SizedBox(height: 8),
                  Text(
                    anyRoute
                        ? S.of('install.verdict.route')
                        : S.of('install.verdict.noroute'),
                    style: TextStyle(
                      color: anyRoute
                          ? Colors.lightGreenAccent
                          : Colors.orangeAccent,
                    ),
                  ),
                  if (viewers.isNotEmpty) ...[
                    const SizedBox(height: 8),
                    for (final v in viewers)
                      Text('· $v',
                          style: const TextStyle(
                              fontSize: 11, color: Colors.grey)),
                  ],
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),
          if (!canInstall)
            Card(
              child: ListTile(
                leading:
                    const Icon(Icons.lock_open, color: Colors.orangeAccent),
                title: Text(S.of('install.grant.title')),
                subtitle: Text(S.of('install.grant.sub')),
                onTap: () async {
                  final r = await ApkInstallChannel.unknownSources();
                  if (r['ok'] != true) _say('unknownSources → ${r['error']}');
                },
              ),
            ),
          Card(
            child: Column(
              children: [
                ListTile(
                  leading: const Icon(Icons.folder_open),
                  title: Text(S.of('install.pick.title')),
                  subtitle: Text(_stagedName == null
                      ? S.of('install.pick.sub')
                      : '$_stagedName — $_stagedBytes B'),
                  onTap: _busy ? null : _pickAndStage,
                ),
                ListTile(
                  leading: Icon(Icons.system_update,
                      color: _stagedName == null ? Colors.grey : null),
                  title: Text(S.of('install.run.title')),
                  subtitle: Text(S.of('install.run.sub')),
                  onTap: (_busy || _stagedName == null) ? null : _launch,
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(S.of('install.log.title'),
                            style: const TextStyle(
                                fontSize: 16, fontWeight: FontWeight.w600)),
                      ),
                      TextButton.icon(
                        icon: const Icon(Icons.save_alt, size: 18),
                        label: Text(S.of('install.export')),
                        onPressed: _export,
                      ),
                    ],
                  ),
                  if (_log.isEmpty)
                    Text(S.of('install.log.empty'),
                        style: const TextStyle(color: Colors.grey)),
                  for (final l in _log)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 2),
                      child: Text(l, style: const TextStyle(fontSize: 12)),
                    ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _row(String k, String v, {bool bad = false}) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: Row(
          children: [
            Expanded(
              child: Text(k,
                  style: const TextStyle(fontSize: 12, color: Colors.grey)),
            ),
            Text(v,
                style: TextStyle(
                  fontSize: 13,
                  color: bad ? Colors.orangeAccent : null,
                )),
          ],
        ),
      );
}
