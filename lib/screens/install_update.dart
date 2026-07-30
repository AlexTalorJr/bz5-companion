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
/// ── v0.1.77+176: ЭКРАН СТАЛ ОБОЗРЕВАТЕЛЕМ ───────────────────────────
///
/// Поле 29.07 (пять прогонов, одинаковый ответ) показало, что стен две и
/// обе стоят ДО установщика: `staged_bytes: 0` во всех пяти, то есть
/// установщик не пробовался ни разу.
///
///   1. ФАЙЛА НЕТ — системный выбор файла перехвачен галереей BYD,
///      которая перечисляет только изображения и видео.
///   2. РАЗРЕШЕНИЯ НЕТ — экрана «неизвестные источники» на прошивке не
///      существует вовсе (`ActivityNotFoundException`).
///
/// Разрешение главнее файла: скачивание без него даёт файл, который
/// некому поставить. Поэтому порядок блоков на экране — сначала
/// разрешение и файл со флешки, и только потом сеть.
///
/// Ни один путь к файлу не объявлен обязательным. «Указать флешку»
/// (SAF-дерево) идёт первым, потому что это ДРУГОЕ действие, чем
/// перехваченное галереей, и единственное, которое на API 30+ для
/// съёмных томов задумано работать; File-API остаётся ниже и включается
/// сам, если хоть одно разрешение на хранилище выдано.
///
/// Dev-поверхность: технические строки (имена резолверов, шаги, заметки
/// обхода) не переводятся по правилу проекта, переводится только
/// обвязка.
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

  List<Map<String, dynamic>> _apks = const <Map<String, dynamic>>[];
  List<String> _scanNotes = const <String>[];

  UpdateLookupResult? _lookup;
  DownloadHandle? _dl;
  int _dlGot = 0;
  int _dlTotal = 0;

  @override
  void initState() {
    super.initState();
    _runProbe();
  }

  @override
  void dispose() {
    // Закачка живёт дольше кадра: без этого она продолжила бы писать в
    // файл после ухода с экрана, а отменить её стало бы нечем.
    _dl?.cancel();
    super.dispose();
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
      await _stage('${picked['uri']}');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Общий конец всех путей к файлу: и выбор, и обозреватель, и «поделиться»
  /// заканчиваются копией в наш кэш. Одна точка намеренно — три копии
  /// этой логики разошлись бы при первой правке.
  Future<void> _stage(String uri) async {
    final staged = await ApkInstallChannel.stage(uri);
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
  }

  Future<void> _askForVolume() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final r = await ApkInstallChannel.openTree();
      for (final s in (r['steps'] as List<dynamic>? ?? const <dynamic>[])) {
        _say('$s');
      }
      if (r['ok'] != true || r['uri'] == null) {
        _say('tree → ${r['error'] ?? 'cancelled'}');
        return;
      }
      final kept = await ApkInstallChannel.rememberTree('${r['uri']}');
      _say('tree → ${r['uri']} · persisted=${kept['ok']}');
      await _browse();
      await _runProbe();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _browse() async {
    final r = await ApkInstallChannel.listApks();
    if (!mounted) return;
    setState(() {
      _apks = ((r['apks'] as List<dynamic>?) ?? const <dynamic>[])
          .whereType<Map<dynamic, dynamic>>()
          .map((e) => e.cast<String, dynamic>())
          .toList();
      _scanNotes = ((r['notes'] as List<dynamic>?) ?? const <dynamic>[])
          .map((e) => '$e')
          .toList();
    });
  }

  Future<void> _launch() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final res = await ApkInstallChannel.launch();
      for (final s in (res['steps'] as List<dynamic>? ?? const <dynamic>[])) {
        _say('$s');
      }
      _say('appop at attempt: ${res['can_request_installs_at_attempt']}');
      if (res['exception'] != null) _say('exception: ${res['exception']}');
      _say(res['ok'] == true
          ? 'installer opened via ${res['action']} — resultCode пойдёт в журнал автозапуска'
          : 'installer did not open');
      // Проба перечитывается: разрешение могли выдать между попытками,
      // и показывать устаревшее «нет» после успешной выдачи — врать.
      await _runProbe();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _openDoor(String door) async {
    final r = await ApkInstallChannel.openDoor(door);
    _say('door $door → ${r['ok'] == true ? 'открыт' : r['error']}');
    if (r['ok'] == true) await _runProbe();
  }

  // ── §B: сеть ───────────────────────────────────────────────────────

  Future<void> _check() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _lookup = null;
    });
    try {
      final r = await ApkUpdate.lookupLatest();
      if (!mounted) return;
      setState(() => _lookup = r);
      final rel = r.release;
      _say(rel == null
          ? 'latest → ${r.state.name}: ${r.detail}'
          : 'latest → ${rel.tag} · ${rel.assetName} · ${rel.bytes} B');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _download(UpdateRelease rel) async {
    final installed = (_probe?['version_code'] as num?)?.toInt() ?? -1;
    if (!ApkUpdate.isUpgrade(installed, rel.buildNumber)) {
      _say('отказ: установлено $installed, предложено ${rel.buildNumber}');
      return;
    }
    final where = await ApkInstallChannel.stagedPath();
    final path = '${where['path'] ?? ''}';
    if (path.isEmpty) {
      _say('stagedPath → пусто');
      return;
    }
    final handle = DownloadHandle();
    setState(() {
      _dl = handle;
      _dlGot = 0;
      _dlTotal = rel.bytes;
    });
    final r = await ApkUpdate.download(
      release: rel,
      path: path,
      handle: handle,
      onProgress: (got, total) {
        if (!mounted) return;
        setState(() {
          _dlGot = got;
          _dlTotal = total;
        });
      },
    );
    if (!mounted) return;
    setState(() => _dl = null);
    if (r['ok'] == true) {
      setState(() {
        _stagedName = rel.assetName;
        _stagedBytes = (r['bytes'] as num?)?.toInt() ?? 0;
      });
      _say('download → ${rel.assetName}, $_stagedBytes B');
    } else {
      _say('download → ${r['error']}');
    }
    await _runProbe();
  }

  Future<void> _export() async {
    final body = const JsonEncoder.withIndent('  ').convert(<String, dynamic>{
      'probe': _probe ?? <String, dynamic>{},
      'scan_notes': _scanNotes,
      'apks': _apks,
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
    final treePickers =
        (p?['tree_doc_resolvers'] as List<dynamic>? ?? <dynamic>[]);
    final trees = (p?['persisted_trees'] as List<dynamic>? ?? <dynamic>[]);
    final doors = (p?['doors'] as Map<dynamic, dynamic>? ?? <dynamic, dynamic>{});
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
                  _row('ACTION_OPEN_DOCUMENT_TREE resolvers',
                      '${treePickers.length}', bad: treePickers.isEmpty),
                  _row('installer packages',
                      '${(p?['installer_packages'] as List<dynamic>? ?? const []).length}'),
                  _row('sdk', '${p?['sdk'] ?? '?'}'),
                  // targetSdk из поля, а не из моего чтения gradle: при
                  // 30+ READ_EXTERNAL_STORAGE открывает только медиа, и
                  // путь A1c имеет структурный потолок.
                  _row('targetSdk', '${p?['target_sdk'] ?? '?'}'),
                  _row('versionCode', '${p?['version_code'] ?? '?'}'),
                  _row('MANAGE_EXTERNAL_STORAGE',
                      '${p?['has_manage_all_files'] ?? '?'}'),
                  _row('READ_EXTERNAL_STORAGE',
                      '${p?['read_storage_granted'] ?? '?'}'),
                  _row('persisted trees', '${trees.length}',
                      bad: trees.isEmpty),
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
          // ── двери. Каждая показана вместе с числом резолверов: пустая
          // дверь — это ответ прошивки, а не наша ошибка.
          if (doors.isNotEmpty)
            Card(
              child: Padding(
                padding: const EdgeInsets.all(14),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(S.of('install.doors.title'),
                        style: const TextStyle(
                            fontSize: 16, fontWeight: FontWeight.w600)),
                    Text(S.of('install.doors.sub'),
                        style: const TextStyle(
                            fontSize: 12, color: Colors.grey)),
                    const SizedBox(height: 4),
                    for (final e in doors.entries)
                      _DoorRow(
                        name: '${e.key}',
                        resolvers:
                            (e.value as List<dynamic>? ?? const <dynamic>[])
                                .length,
                        onTap: () => _openDoor('${e.key}'),
                      ),
                  ],
                ),
              ),
            ),
          const SizedBox(height: 12),
          // ── файл: флешка, обозреватель, системный выбор ──────────
          Card(
            child: Column(
              children: [
                ListTile(
                  leading: const Icon(Icons.usb),
                  title: Text(S.of('install.tree.title')),
                  subtitle: Text(trees.isEmpty
                      ? S.of('install.tree.sub')
                      : '${trees.length}: ${trees.first}'),
                  onTap: _busy ? null : _askForVolume,
                ),
                ListTile(
                  leading: const Icon(Icons.travel_explore),
                  title: Text(S.of('install.browse.title')),
                  subtitle: Text(S.of('install.browse.sub')),
                  onTap: _busy ? null : _browse,
                ),
                if (_scanNotes.isNotEmpty)
                  Padding(
                    padding:
                        const EdgeInsets.fromLTRB(16, 0, 16, 8),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        for (final n in _scanNotes)
                          Text('· $n',
                              style: const TextStyle(
                                  fontSize: 11, color: Colors.grey)),
                      ],
                    ),
                  ),
                if (_apks.isEmpty)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                    child: Text(S.of('install.browse.empty'),
                        style: const TextStyle(color: Colors.grey)),
                  ),
                for (final a in _apks)
                  ListTile(
                    dense: true,
                    leading: const Icon(Icons.android, size: 20),
                    title: Text('${a['name']}',
                        style: const TextStyle(fontSize: 13)),
                    subtitle: Text('${a['bytes']} B · ${a['src']}',
                        style: const TextStyle(fontSize: 11)),
                    onTap: _busy ? null : () => _stage('${a['uri']}'),
                  ),
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
          // ── §B: сеть. Ниже файла намеренно — разрешение и файл
          // главнее, скачивание без них даёт файл, который некому
          // поставить.
          Card(
            child: Column(
              children: [
                ListTile(
                  leading: const Icon(Icons.cloud_download),
                  title: Text(S.of('install.update.title')),
                  subtitle: Text(_updateSubtitle()),
                  onTap: (_busy || _dl != null) ? null : _check,
                ),
                if (_dl != null) ...[
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    child: LinearProgressIndicator(
                      value: _dlTotal > 0 ? _dlGot / _dlTotal : null,
                    ),
                  ),
                  ListTile(
                    dense: true,
                    title: Text('$_dlGot / $_dlTotal B',
                        style: const TextStyle(fontSize: 12)),
                    trailing: TextButton(
                      onPressed: () => _dl?.cancel(),
                      child: Text(S.of('install.update.cancel')),
                    ),
                  ),
                ],
                if (_dl == null && _lookup?.state == UpdateLookup.ok)
                  _upgradeTile(_lookup!.release!),
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

  /// Подпись блока обновления. Каждое состояние поиска имеет СВОЙ текст:
  /// показать «обновлений нет» на исчерпанный лимит запросов значило бы
  /// соврать ровно тем прибором, который делается ради честности.
  String _updateSubtitle() {
    final l = _lookup;
    if (l == null) return S.of('install.update.check');
    switch (l.state) {
      case UpdateLookup.ok:
        final rel = l.release!;
        return '${rel.tag} · ${rel.assetName}';
      case UpdateLookup.rateLimited:
        return S.of('install.update.rate');
      case UpdateLookup.notFound:
        return '${S.of('install.update.none')} · ${l.detail}';
      case UpdateLookup.offline:
        return '${S.of('install.update.offline')} · ${l.detail}';
      case UpdateLookup.malformed:
        return '${S.of('install.update.bad')} · ${l.detail}';
    }
  }

  Widget _upgradeTile(UpdateRelease rel) {
    final installed = (_probe?['version_code'] as num?)?.toInt() ?? -1;
    final up = ApkUpdate.isUpgrade(installed, rel.buildNumber);
    // «Версию установленной сборки не прочитали» и «предложенная не
    // новее» — РАЗНЫЕ отказы, и оба ведут к одному действию, но не к
    // одному объяснению. Показать первое как второе значит соврать
    // владельцу о причине: он пойдёт искать более новый релиз, которого
    // нет, вместо того чтобы понять, что отказал PackageManager.
    final unknown = installed <= 0;
    return ListTile(
      dense: true,
      leading: Icon(up ? Icons.download : Icons.block,
          color: up ? null : Colors.orangeAccent),
      title: Text(up
          ? '${S.of('install.update.download')} ${rel.buildNumber}'
          : unknown
              ? S.of('install.update.unknown')
              : S.of('install.update.notnewer')),
      subtitle: Text('installed $installed → ${rel.buildNumber}',
          style: const TextStyle(fontSize: 11)),
      onTap: up ? () => _download(rel) : null,
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

/// Строка двери: имя, сколько её приняло, и попытка открыть. Пустая
/// дверь не скрывается — «на этой прошивке её нет» такой же результат,
/// как открывшийся экран, и увидеть его надо один раз, а не гадать.
class _DoorRow extends StatelessWidget {
  const _DoorRow({
    required this.name,
    required this.resolvers,
    required this.onTap,
  });

  final String name;
  final int resolvers;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final short = name.replaceFirst('android.settings.', '')
        .replaceFirst('android.intent.action.', '');
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 5),
        child: Row(
          children: [
            Expanded(
              child: Text(short, style: const TextStyle(fontSize: 12)),
            ),
            Text('$resolvers',
                style: TextStyle(
                  fontSize: 13,
                  color: resolvers == 0 ? Colors.orangeAccent : null,
                )),
            const SizedBox(width: 6),
            const Icon(Icons.open_in_new, size: 14, color: Colors.grey),
          ],
        ),
      ),
    );
  }
}
