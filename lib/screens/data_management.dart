import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../data/database.dart';
import '../l10n/strings.dart';
import '../services/connection.dart';
import '../services/locale_service.dart';
import '../services/apk_install_channel.dart';
import '../services/autostart_arm.dart';
import '../services/export_service.dart';
import '../services/hal_telemetry_service.dart';
import '../services/import_service.dart';

/// v0.1.11: Data management screen — export all data to share sheet,
/// or clear specific tables when storage starts filling up.
///
/// v0.1.13: added "Save to Downloads" path for Toyota head unit where the
/// system share sheet has no registered handlers (no Telegram/Drive/etc.
/// available). Direct write to /storage/emulated/0/Download/ works there.
///
/// Sections:
///   STORAGE — live counts of trips / snapshots / samples / hal_samples /
///             sweep_runs / live_log_sessions
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
  bool _includeLiveLogs = true;

  bool _exporting = false;
  String _stage = '';
  String? _lastResult;

  // Counts shown in UI — fetched on init & after any clear.
  Map<String, int>? _counts;
  bool _loadingCounts = true;

  // v0.1.81+180 — восстановление из архива.
  bool _busy = false;
  bool _pending = false;
  bool _importSettings = true;
  ImportPreview? _preview;
  String? _importResult;

  // v0.1.83+182 — отчёт о восстановлении. Живёт до снятия владельцем.
  ImportReport? _report;

  // v0.1.88+187 — что именно нашлось и почему не открылось. Список, а
  // не первый подходящий: «файла нет» и «не пускают» требуют от
  // владельца РАЗНЫХ действий, а прежний экран сводил их в одну строку.
  List<ArchiveCandidate> _candidates = const [];

  // Итог трёх проб хранилища одной строкой. Пусто, пока не спрашивали.
  String? _probeLine;

  // v0.1.97+196 — СТРОКИ ЖУРНАЛА ПРО ПРИЁМ И ВОССТАНОВЛЕНИЕ, ПРЯМО ЗДЕСЬ.
  //
  // Журнал лежит в файле и уезжает внутри архива экспорта, но вынуть
  // файл из машины владельцу дорого: три визита подряд разбор шёл
  // вслепую именно потому, что свежего журнала не было. Те же строки
  // читаются каналом и показываются на экране — их можно прочитать
  // прямо в машине или сфотографировать.
  List<String> _traceLines = const [];
  bool _traceOpen = false;

  // v0.2.4+203 — ДВА СВЁРНУТЫХ БЛОКА.
  //
  // `_pickOpen` — «Что включить»: пять переключателей состава экспорта.
  // Все пять включены (экспорт 11.08 подтверждает: в `metadata.json`
  // все пять `includes` истинны), а места они занимают пол-экрана над
  // кнопкой, которая нужна каждый раз.
  //
  // `_helpOpen` — «Не получилось?»: ручной поиск, проба хранилища,
  // список кандидатов с приговорами. Всё это нужно ровно тогда, когда
  // обычный путь отказал, то есть редко.
  bool _pickOpen = false;
  bool _helpOpen = false;

  // Принятая, но ещё не восстановленная копия. Спрашивается при открытии
  // экрана и гаснет сама: после успешного импорта файл удаляется.
  ArchiveCandidate? _staged;

  @override
  void initState() {
    super.initState();
    _refreshCounts();
    _refreshPending();
    _refreshReport();
    _refreshTrace();
    _refreshStaged();
    // v0.2.4+203 — ОСМОТР ПРИНЯТОГО АРХИВА ПРИ ОТКРЫТИИ ЭКРАНА.
    //
    // Рабочий путь на этой машине один: проводник → «Поделиться» → BZ5
    // Companion. После этого файл уже лежит в нашем каталоге, и всё, что
    // отделяло владельца от кнопки «Восстановить», — нажатие «Найти
    // архив». Теперь осмотр идёт сам.
    //
    // РАЗРЕШЕНИЕ ЗДЕСЬ НЕ СПРАШИВАЕТСЯ. Принятая копия лежит в НАШЕМ
    // каталоге и читается без прав; запрос прав остаётся на ручном
    // поиске, за явным нажатием. Спрашивать права при открытии экрана
    // значило бы показать системное окно тому, кто зашёл посмотреть
    // счётчики.
    //
    // Через postFrame, а не прямо здесь: нужна схема базы, а она
    // достаётся из Provider, и в `initState` его читать нельзя.
    WidgetsBinding.instance.addPostFrameCallback((_) => _autoSeeStaged());
  }

  /// Осмотреть принятую копию, если она есть. Ни поиска по хранилищу, ни
  /// запроса прав — только тот файл, который нам уже отдали.
  Future<void> _autoSeeStaged() async {
    if (!mounted) return;
    final c = await ImportService.stagedCopy();
    if (c == null || !mounted) return;
    final schema = context.read<ConnectionService>().db.schemaVersion;
    try {
      final pv = await ImportService.inspect(File(c.path),
          appSchemaVersion: schema);
      if (!mounted) return;
      setState(() => _preview = pv);
    } catch (_) {
      // Молча: полоса «Принят архив» уже стоит, и ручной поиск рядом.
      // Показать ошибку разбора при входе на экран значило бы напугать
      // того, кто пришёл за счётчиками.
    }
  }

  /// Только наши строки, и только хвост. Журнал автозапуска пишет ещё и
  /// пробуждения — их здесь десятки на одну интересную, и они утопили бы
  /// то, ради чего экран открыли.
  /// Принятая копия, спрошенная при ОТКРЫТИИ экрана.
  ///
  /// Не из списка кандидатов: тот наполняется только после нажатия «найти
  /// архив», и полоса появлялась бы ровно тогда, когда список уже виден,
  /// то есть никогда вовремя. Находка собственной ревизии.
  Future<void> _refreshStaged() async {
    final c = await ImportService.stagedCopy();
    if (!mounted) return;
    setState(() => _staged = c);
  }

  String _stagedSize() {
    final c = _staged;
    if (c == null) return '—';
    final b = c.sizeBytes;
    if (b >= 1024 * 1024) {
      return '${(b / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    return '${(b / 1024).toStringAsFixed(0)} KB';
  }

  Future<void> _refreshTrace() async {
    const marks = [
      'stage-open:',
      'stage-pick:',
      'stage-peek:',
      'stage-share:',
      'stage-archive:',
      'import-see:',
      'import-read:',
      'import-queue:',
      'import-apply:',
      'import-report:',
    ];
    final whole = await AutostartArm.marker();
    final picked = <String>[];
    for (final line in const LineSplitter().convert(whole)) {
      for (final m in marks) {
        if (line.contains(m)) {
          picked.add(line);
          break;
        }
      }
    }
    final tail = picked.length > 40
        ? picked.sublist(picked.length - 40)
        : picked;
    if (!mounted) return;
    setState(() => _traceLines = tail);
  }

  Future<void> _refreshReport() async {
    final r = await ImportService.readReport();
    if (!mounted) return;
    setState(() => _report = r);
  }

  Future<void> _dismissReport() async {
    await ImportService.clearReport();
    if (!mounted) return;
    setState(() => _report = null);
  }

  Future<void> _refreshPending() async {
    final v = await ImportService.isPending();
    if (!mounted) return;
    setState(() => _pending = v);
  }

  Future<void> _refreshCounts() async {
    setState(() => _loadingCounts = true);
    final db = context.read<ConnectionService>().db;
    final counts = {
      'trips': (await db.getAllTrips()).length,
      'snapshots': await db.countAllSnapshots(),
      'samples': await db.countAllSamples(),
      // v0.1.83+182: долг наблюдаемости, найденный полем 31.07. Метод
      // `countAllHalSamples()` существовал в базе с +92 и не вызывался
      // НИОТКУДА — а это те самые двадцать тысяч строк, ради которых
      // импорт из архива и затевался: облако их не несёт, они умирают с
      // очисткой. Сверить главное число импорта было буквально нечем.
      'hal_samples': await db.countAllHalSamples(),
      'sweep_runs': await db.countAllSweepRuns(),
      'live_log_sessions': await db.countAllLiveLogSessions(),
    };
    if (!mounted) return;
    setState(() {
      _counts = counts;
      _loadingCounts = false;
    });
  }

  /// Сколько частей включено в экспорт. Показывается в заголовке
  /// свёрнутого блока, чтобы разворачивать его было незачем.
  int get _includedCount => [
        _includeTrips,
        _includeSnapshots,
        _includeSamples,
        _includeSweeps,
        _includeLiveLogs,
      ].where((e) => e).length;

  @override
  Widget build(BuildContext context) {
    final svc = context.watch<ConnectionService>();
    // v0.1.29+60: re-render on language switch (per-screen subscription).
    context.watch<LocaleService>();
    // ── ОДИН ПРИЗНАК УСТРОЙСТВА НА ВЕСЬ ЭКРАН. v0.2.4+203 ──
    //
    // Три кнопки этого экрана ведут себя по-разному на машине и на
    // телефоне: «Поделиться» работает только на телефоне, «Выбрать файл
    // самому» — тоже, инструкция под экспортом нужна только на машине.
    // Признак вычисляется ОДИН раз и здесь.
    //
    // Пара `platformProbed && canUseHal`, а не один `canUseHal`. Опрос
    // платформы завершается уже после первой отрисовки, и до него
    // `canUseHal` ложен И на телефоне, И на ещё не проснувшейся машине.
    // На одном признаке машина рисовала бы первый кадр как телефон —
    // то есть пряталa бы единственный работающий там путь и показывала
    // два неработающих. С парой первый кадр всегда «как на машине», и
    // подмена возможна только на телефоне, где оба пути живые и цена
    // ошибки — лишняя кнопка на долю секунды. Та же дисциплина стоит в
    // `settings.dart` и в `soc_resolver.dart`.
    final hal = context.watch<HalTelemetryService>();
    final bool isPhone = hal.platformProbed && !hal.canUseHal;
    return Scaffold(
      appBar: AppBar(title: Text(S.of('settings.data.title'))),
      body: ListView(
        padding: const EdgeInsets.symmetric(vertical: 8),
        children: [
          _section(S.of('dataexp.sec_storage')),
          if (_loadingCounts)
            ListTile(
              leading: const SizedBox(
                width: 18, height: 18,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
              title: Text(S.of('dataexp.counting')),
            )
          else if (_counts != null) ...[
            ListTile(
              dense: true,
              leading: const Icon(Icons.route, size: 20),
              title: Text(S.of('datamgmt.cat.trips')),
              trailing: Text('${_counts!['trips']}',
                  style: const TextStyle(
                      fontFeatures: [FontFeature.tabularFigures()])),
            ),
            ListTile(
              dense: true,
              leading: const Icon(Icons.timeline, size: 20),
              title: Text(S.of('datamgmt.cat.snapshots')),
              trailing: Text('${_counts!['snapshots']}',
                  style: const TextStyle(
                      fontFeatures: [FontFeature.tabularFigures()])),
            ),
            ListTile(
              dense: true,
              leading: const Icon(Icons.dns, size: 20),
              title: Text(S.of('datamgmt.cat.raw_samples')),
              trailing: Text('${_counts!['samples']}',
                  style: const TextStyle(
                      fontFeatures: [FontFeature.tabularFigures()])),
            ),
            ListTile(
              dense: true,
              leading: const Icon(Icons.sensors, size: 20),
              title: Text(S.of('datamgmt.cat.hal_samples')),
              trailing: Text('${_counts!['hal_samples']}',
                  style: const TextStyle(
                      fontFeatures: [FontFeature.tabularFigures()])),
            ),
            ListTile(
              dense: true,
              leading: const Icon(Icons.search, size: 20),
              title: Text(S.of('datamgmt.cat.sweep_runs')),
              trailing: Text('${_counts!['sweep_runs']}',
                  style: const TextStyle(
                      fontFeatures: [FontFeature.tabularFigures()])),
            ),
            ListTile(
              dense: true,
              leading: const Icon(Icons.timeline, size: 20),
              title: Text(S.of('datamgmt.cat.livelog_sessions')),
              trailing: Text('${_counts!['live_log_sessions']}',
                  style: const TextStyle(
                      fontFeatures: [FontFeature.tabularFigures()])),
            ),
          ],

          const Divider(),
          _section(S.of('dataexp.sec_export')),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
            child: Text(
              S.of('dataexp.export_intro'),
              style: const TextStyle(fontSize: 12, color: Colors.grey),
            ),
          ),
          // ── ПЯТЬ ПЕРЕКЛЮЧАТЕЛЕЙ СОСТАВА — В СВЁРНУТЫЙ БЛОК. +203 ──
          //
          // Все пять включены и такими остаются. Они занимали пол-экрана
          // над кнопкой, которая нужна каждый раз, а нужны раз в никогда.
          // Сколько их включено, видно в заголовке блока, не разворачивая.
          ListTile(
            dense: true,
            leading: const Icon(Icons.checklist, size: 20),
            title: Text(
              S
                  .of('dataexp.pick_title')
                  .replaceFirst('{n}', '$_includedCount'),
              style: const TextStyle(fontSize: 13),
            ),
            trailing: Icon(_pickOpen ? Icons.expand_less : Icons.expand_more,
                size: 20),
            onTap: () => setState(() => _pickOpen = !_pickOpen),
          ),
          if (_pickOpen) ...[
          SwitchListTile(
            value: _includeTrips,
            onChanged: _exporting ? null : (v) => setState(() => _includeTrips = v),
            secondary: const Icon(Icons.route),
            title: Text(S.of('datamgmt.cat.trips')),
            subtitle: Text(S.of('dataexp.trips_sub')),
            dense: true,
          ),
          SwitchListTile(
            value: _includeSnapshots,
            onChanged: _exporting
                ? null
                : (v) => setState(() => _includeSnapshots = v),
            secondary: const Icon(Icons.timeline),
            title: Text(S.of('datamgmt.cat.snapshots')),
            subtitle: Text(S.of('dataexp.snapshots_sub')),
            dense: true,
          ),
          SwitchListTile(
            value: _includeSamples,
            onChanged: _exporting
                ? null
                : (v) => setState(() => _includeSamples = v),
            secondary: const Icon(Icons.dns),
            title: Text(S.of('datamgmt.cat.raw_samples')),
            subtitle: Text(S.of('dataexp.samples_sub')),
            dense: true,
          ),
          SwitchListTile(
            value: _includeSweeps,
            onChanged: _exporting ? null : (v) => setState(() => _includeSweeps = v),
            secondary: const Icon(Icons.search),
            title: Text(S.of('datamgmt.cat.sweep_results')),
            subtitle: const Text('sweep_runs.csv + sweep_results.csv'),
            dense: true,
          ),
          SwitchListTile(
            value: _includeLiveLogs,
            onChanged: _exporting ? null : (v) => setState(() => _includeLiveLogs = v),
            secondary: const Icon(Icons.timeline),
            title: Text(S.of('datamgmt.cat.livelog_sessions')),
            subtitle: Text(S.of('dataexp.livelogs_sub')),
            dense: true,
          ),
          ],
          // ── «ПОДЕЛИТЬСЯ» — ТОЛЬКО ТЕЛЕФОН. +203 ──
          //
          // Поле 11.08, ответ владельца: наш исходящий вызов системного
          // «Поделиться» на этой машине не работает. Кнопка нажимается и
          // не делает ничего. На телефоне она главный путь, поэтому не
          // удаляется, а прячется по признаку устройства.
          //
          // Признак — `isPhone`, и он ОДИН на все три кнопки этого
          // экрана. Три отдельные проверки разошлись бы: гейт CG8 держит
          // это условие.
          if (isPhone)
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
                  ? S.of('dataexp.exporting').replaceFirst('{stage}', _stage)
                  : S.of('dataexp.share_btn')),
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
                  ? S.of('dataexp.exporting').replaceFirst('{stage}', _stage)
                  : S.of('dataexp.save_btn')),
              style: OutlinedButton.styleFrom(
                minimumSize: const Size.fromHeight(48),
              ),
              onPressed: _exporting ? null : () => _doExport(svc, toDownloads: true),
            ),
          ),
          // Прямая инструкция, а не объяснение выбора: выбора на машине
          // больше нет, кнопка одна. +203.
          if (!isPhone)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: Text(
                S.of('dataexp.hu_note'),
                style: const TextStyle(fontSize: 11, color: Colors.grey),
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
          _section(S.of('dataimp.sec_restore')),
          // ── ПРИНЯТЫЙ АРХИВ ВИДНО СРАЗУ. v0.1.97+196 ──
          //
          // Поле, три попытки подряд: владелец отдаёт файл приложению,
          // открывает его и видит прежние данные. Приём и восстановление
          // — два РАЗНЫХ действия, и о первом приложение не говорило
          // ничего: файл молча ложился в каталог, а узнать об этом можно
          // было, только досмотрев список кандидатов ниже до строки со
          // словом «принят».
          //
          // Полоса стоит ДО вводного текста и до списка: пропустить её,
          // открыв раздел, нельзя.
          if (_staged != null)
            Container(
              margin: const EdgeInsets.fromLTRB(16, 4, 16, 4),
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Colors.amberAccent.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Row(
                children: [
                  const Icon(Icons.inbox, color: Colors.amberAccent),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      S
                          .of('dataimp.staged_here')
                          .replaceFirst('{size}', _stagedSize()),
                      style: const TextStyle(fontSize: 13),
                    ),
                  ),
                ],
              ),
            ),
          // ── ТРИ ШАГА ВОССТАНОВЛЕНИЯ, ПО НОМЕРАМ. v0.2.4+203 ──
          //
          // Прежний вводный текст объяснял устройство и предлагал выбор
          // из путей, которых на этой машине нет. Поле 11.08 показало,
          // что работает ровно один путь, и он записан здесь по шагам.
          //
          // Третий шаг не косметика: обмен базы происходит при следующем
          // рождении процесса, и без закрытия приложения владелец видит
          // прежние данные и считает, что восстановление не сработало.
          // Так было три визита подряд.
          //
          // ШАГИ ПОКАЗЫВАЮТСЯ ТОЛЬКО НА МАШИНЕ. Первый шаг называет
          // проводник машины и «Поделиться» — на телефоне этого пути
          // нет, там работает выбор файла. Показать шаги везде значило
          // бы дать владельцу телефона инструкцию, которую он выполнить
          // не может. Найдено собственной ревизией до выдачи.
          if (isPhone)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
              child: Text(
                S.of('dataimp.phone_note'),
                style: const TextStyle(fontSize: 12, color: Colors.grey),
              ),
            ),
          if (!isPhone)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (final k in const [
                  'dataimp.step1',
                  'dataimp.step2',
                  'dataimp.step3',
                ])
                  Padding(
                    padding: const EdgeInsets.only(bottom: 4),
                    child: Text(
                      S.of(k),
                      style: const TextStyle(fontSize: 12, color: Colors.grey),
                    ),
                  ),
              ],
            ),
          ),
          if (_pending) ...[
            ListTile(
              leading: const Icon(Icons.restart_alt, color: Colors.amberAccent),
              title: Text(S.of('dataimp.pending_title')),
              subtitle: Text(S.of('dataimp.pending_sub')),
              trailing: TextButton(
                onPressed: _busy ? null : _cancelPending,
                child: Text(S.of('dataimp.cancel')),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
              child: FilledButton.icon(
                icon: const Icon(Icons.power_settings_new),
                label: Text(S.of('dataimp.close_btn')),
                style: FilledButton.styleFrom(
                  minimumSize: const Size.fromHeight(48),
                ),
                onPressed: _busy ? null : _closeApp,
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: Text(
                S.of('dataimp.close_note'),
                style: const TextStyle(fontSize: 11, color: Colors.grey),
              ),
            ),
          ] else ...[
            // ── СВЁРНУТЫЙ БЛОК «НЕ ПОЛУЧИЛОСЬ?». v0.2.4+203 ──
            //
            // Внутри всё, что нужно ровно при отказе: ручной поиск, выбор
            // файла (только телефон), список кандидатов с приговорами,
            // проба хранилища, подсказка про смену идентификатора.
            //
            // «Найти архив» УДАЛЯТЬ НЕЛЬЗЯ, и это записано здесь, чтобы
            // следующая переделка не приняла её за мёртвую. Кнопка
            // выглядит бесполезной, потому что первая ступень поиска
            // почти всегда находит принятую копию сама, — но именно эта
            // ступень и есть способ подхватить принятый файл, если
            // осмотр при открытии экрана почему-то не прошёл.
            ListTile(
              dense: true,
              leading: const Icon(Icons.help_outline, size: 20),
              title: Text(S.of('dataimp.help_title'),
                  style: const TextStyle(fontSize: 13)),
              trailing: Icon(
                  _helpOpen ? Icons.expand_less : Icons.expand_more, size: 20),
              onTap: () => setState(() => _helpOpen = !_helpOpen),
            ),
            if (_helpOpen) ...[
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
              child: OutlinedButton.icon(
                icon: const Icon(Icons.folder_open),
                label: Text(_busy
                    ? S.of('dataimp.looking')
                    : S.of('dataimp.find_btn')),
                style: OutlinedButton.styleFrom(
                  minimumSize: const Size.fromHeight(48),
                ),
                onPressed: _busy ? null : _findArchive,
              ),
            ),
            // v0.1.88+187 — второй путь. Файл, показанный владельцем,
            // приходит с грантом, а грант не зависит от того, какой uid
            // был у прежней установки.
            //
            // v0.2.4+203 — ТОЛЬКО ТЕЛЕФОН. Замечание +187 «на этой
            // прошивке она главная» было предположением и оказалось
            // неверным: поле 11.08, ответ владельца — системный выбор
            // файла не срабатывал на этой машине ни разу. На телефоне
            // это единственный путь импорта, поэтому кнопка остаётся, но
            // по тому же признаку устройства, что и «Поделиться».
            if (isPhone)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
              child: OutlinedButton.icon(
                icon: const Icon(Icons.attach_file),
                label: Text(S.of('dataimp.pick_btn')),
                style: OutlinedButton.styleFrom(
                  minimumSize: const Size.fromHeight(48),
                ),
                onPressed: _busy ? null : _pickArchive,
              ),
            ),
            // Список кандидатов с приговором по каждому. Показывается
            // всегда, когда поиск отработал: при удаче он объясняет
            // ВЫБОР, при неудаче — ОТКАЗ, и это одинаково важно.
            if (_candidates.isNotEmpty)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    for (final c in _candidates)
                      Text(
                        _candidateLine(c),
                        style: TextStyle(
                          fontSize: 11,
                          color: c.readable
                              ? Colors.greenAccent
                              : Colors.orangeAccent,
                        ),
                      ),
                    if (!_candidates.any((c) => c.readable))
                      Padding(
                        padding: const EdgeInsets.only(top: 4),
                        child: Text(
                          S.of('dataimp.denied_hint'),
                          style: const TextStyle(
                              fontSize: 11, color: Colors.grey),
                        ),
                      ),
                  ],
                ),
              ),
            // Проба хранилища и подсказка про смену идентификатора —
            // внутри того же блока: обе нужны в тот же момент, что и
            // ручной поиск. +203 (прежде проба стояла в общем выводе).
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
              child: TextButton(
                onPressed: _busy ? null : _runStorageProbe,
                child: Text(S.of('dataimp.probe_btn')),
              ),
            ),
            if (_probeLine != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
                child: Text(
                  _probeLine!,
                  style: const TextStyle(fontSize: 10, color: Colors.grey),
                ),
              ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: Text(
                S.of('dataimp.uid_hint'),
                style: const TextStyle(fontSize: 11, color: Colors.grey),
              ),
            ),
            ],
            if (_preview != null && _preview!.ok) ...[
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
                child: Text(
                  S
                      .of('dataimp.found_fmt')
                      .replaceFirst('{size}', _preview!.humanSize)
                      .replaceFirst('{at}', _preview!.exportedAt)
                      .replaceFirst('{schema}', '${_preview!.schemaVersion}')
                      .replaceFirst('{summary}', _preview!.countsSummary),
                  style: const TextStyle(fontSize: 12),
                ),
              ),
              CheckboxListTile(
                dense: true,
                value: _importSettings && _preview!.hasSettings,
                onChanged: _preview!.hasSettings && !_busy
                    ? (v) => setState(() => _importSettings = v ?? true)
                    : null,
                title: Text(_preview!.hasSettings
                    ? S
                        .of('dataimp.with_settings_fmt')
                        .replaceFirst('{n}', '${_preview!.prefsCount}')
                    : S.of('dataimp.no_settings')),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
                child: FilledButton.icon(
                  icon: const Icon(Icons.restore),
                  label: Text(S.of('dataimp.restore_btn')),
                  style: FilledButton.styleFrom(
                    minimumSize: const Size.fromHeight(48),
                  ),
                  onPressed: _busy ? null : _confirmAndStage,
                ),
              ),
            ],
            if (_preview != null && !_preview!.ok)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
                child: Text(
                  _reasonLine(_preview!),
                  style: const TextStyle(
                      fontSize: 12, color: Colors.orangeAccent),
                ),
              ),
          ],
          if (_importResult != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
              child: Text(_importResult!,
                  style: const TextStyle(
                      fontSize: 12, color: Colors.greenAccent)),
            ),

          // ── ЖУРНАЛ ПРИЁМА И ВОССТАНОВЛЕНИЯ, ВИДИМЫЙ БЕЗ ФАЙЛОВ ──
          //
          // v0.1.97+196. Строки лежат в файле и уезжают внутри архива
          // экспорта, но вынуть файл из машины дорого, и три разбора
          // подряд шли вслепую ровно поэтому. Здесь тот же самый файл,
          // прочитанный тем же каналом, только отфильтрованный до наших
          // строк.
          //
          // Свёрнуто по умолчанию: раздел нужен, когда что-то не вышло, а
          // не каждый раз. Читать десять строк служебной латиницы поверх
          // обычной работы владелец не подписывался.
          ListTile(
            dense: true,
            leading: const Icon(Icons.receipt_long, size: 20),
            title: Text(
              S
                  .of('dataimp.trace_title')
                  .replaceFirst('{n}', '${_traceLines.length}'),
              style: const TextStyle(fontSize: 13),
            ),
            trailing: Icon(
                _traceOpen ? Icons.expand_less : Icons.expand_more,
                size: 20),
            onTap: () async {
              await _refreshTrace();
              if (!mounted) return;
              setState(() => _traceOpen = !_traceOpen);
            },
          ),
          if (_traceOpen)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
              child: SelectableText(
                _traceLines.isEmpty
                    ? S.of('dataimp.trace_empty')
                    : _traceLines.join('\n'),
                style: const TextStyle(
                    fontSize: 10,
                    color: Colors.grey,
                    fontFamily: 'monospace'),
              ),
            ),

          const Divider(),
          _section(S.of('dataexp.sec_cleanup')),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
            child: Text(
              S.of('dataexp.cleanup_warn'),
              style: const TextStyle(fontSize: 12, color: Colors.orangeAccent),
            ),
          ),
          ListTile(
            leading: const Icon(Icons.delete_outline, color: Colors.orangeAccent),
            title: Text(S.of('dataexp.clear_samples')),
            subtitle: Text(S.of('dataexp.clear_samples_sub')),
            onTap: () => _confirmAndClear(
              title: S.of('dataexp.clear_samples_q'),
              description: S.of('dataexp.clear_samples_desc'),
              action: () async {
                final n = await svc.db.clearAllSamples();
                return S
                    .of('dataexp.n_samples_deleted')
                    .replaceFirst('{n}', '$n');
              },
            ),
          ),
          ListTile(
            leading: const Icon(Icons.delete_outline, color: Colors.orangeAccent),
            title: Text(S.of('dataexp.clear_snapshots')),
            subtitle: Text(S.of('dataexp.clear_snapshots_sub')),
            onTap: () => _confirmAndClear(
              title: S.of('dataexp.clear_snapshots_q'),
              description: S.of('dataexp.clear_snapshots_desc'),
              action: () async {
                final n = await svc.db.clearAllSnapshots();
                return S
                    .of('dataexp.n_snapshots_deleted')
                    .replaceFirst('{n}', '$n');
              },
            ),
          ),
          ListTile(
            leading: const Icon(Icons.delete_forever, color: Colors.redAccent),
            title: Text(S.of('dataexp.clear_trips')),
            subtitle: Text(S.of('dataexp.clear_trips_sub')),
            onTap: () => _confirmAndClear(
              title: S.of('dataexp.clear_trips_q'),
              description: S.of('dataexp.clear_trips_desc'),
              action: () async {
                final (trips, samples) = await svc.db.clearAllTrips();
                return S
                    .of('dataexp.trips_samples_deleted')
                    .replaceFirst('{t}', '$trips')
                    .replaceFirst('{s}', '$samples');
              },
            ),
          ),
          ListTile(
            leading: const Icon(Icons.delete_outline, color: Colors.orangeAccent),
            title: Text(S.of('dataexp.clear_sweeps')),
            subtitle: Text(S.of('dataexp.clear_sweeps_sub')),
            onTap: () => _confirmAndClear(
              title: S.of('dataexp.clear_sweeps_q'),
              description: S.of('dataexp.clear_sweeps_desc'),
              action: () async {
                final (runs, results) = await svc.db.clearAllSweeps();
                return S
                    .of('dataexp.runs_results_deleted')
                    .replaceFirst('{r}', '$runs')
                    .replaceFirst('{s}', '$results');
              },
            ),
          ),
          ListTile(
            leading: const Icon(Icons.delete_outline, color: Colors.orangeAccent),
            title: Text(S.of('dataexp.clear_livelogs')),
            subtitle: Text(S.of('dataexp.clear_livelogs_sub')),
            onTap: () => _confirmAndClear(
              title: S.of('dataexp.clear_livelogs_q'),
              description: S.of('dataexp.clear_livelogs_desc'),
              action: () async {
                final (sessions, entries) = await svc.db.clearAllLiveLogs();
                return S
                    .of('dataexp.sessions_entries_deleted')
                    .replaceFirst('{a}', '$sessions')
                    .replaceFirst('{b}', '$entries');
              },
            ),
          ),
        ],
      ),
    );
  }

  /// Карточка отчёта: обещание манифеста против факта, по таблице.
  ///
  /// Три состояния, и все три названы своими словами. Совпало — «полностью».
  /// Разошлось — показывается пара чисел, и владелец видит, где именно.
  /// Обещания нет (манифест не прочитался) — «обещание неизвестно», а НЕ
  /// ноль: смешение «неизвестно» с «нулём» уже стоило окну №10 двух
  /// сообщений и неверного разбора.
  Widget _reportCard(ImportReport r) {
    final rows = <Widget>[];
    for (final t in ImportService.reportTables) {
      final got = r.restored(t);
      final want = r.promised(t);
      final ok = want == null || got >= want;
      rows.add(Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 2),
        child: Row(
          children: [
            Icon(
              want == null
                  ? Icons.help_outline
                  : (ok ? Icons.check : Icons.priority_high),
              size: 16,
              color: want == null
                  ? Theme.of(context).disabledColor
                  : (ok ? Colors.green : Theme.of(context).colorScheme.error),
            ),
            const SizedBox(width: 8),
            Expanded(child: Text(t)),
            Text(
              want == null
                  ? '$got / ${S.of('dataimp.rep_unknown')}'
                  : '$got / $want',
              style: const TextStyle(
                  fontFeatures: [FontFeature.tabularFigures()]),
            ),
          ],
        ),
      ));
    }
    return Card(
      margin: const EdgeInsets.fromLTRB(12, 8, 12, 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ListTile(
            leading: Icon(
              r.twoSided && r.complete ? Icons.task_alt : Icons.info_outline,
            ),
            title: Text(S.of('dataimp.rep_title')),
            subtitle: Text(
              r.twoSided
                  ? (r.complete
                      ? S.of('dataimp.rep_full')
                      : S.of('dataimp.rep_short'))
                  : S.of('dataimp.rep_onesided'),
            ),
          ),
          ...rows,
          Align(
            alignment: Alignment.centerRight,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(8, 4, 8, 4),
              child: TextButton(
                onPressed: _dismissReport,
                child: Text(S.of('dataimp.rep_dismiss')),
              ),
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

  /// Найти архив и ОСМОТРЕТЬ его. Ни одной правки на этом шаге —
  /// владелец должен увидеть числа до того, как что-то произойдёт.
  Future<void> _findArchive() async {
    setState(() {
      _busy = true;
      _preview = null;
      _importResult = null;
      _candidates = const [];
    });
    final schema = context.read<ConnectionService>().db.schemaVersion;
    try {
      // v0.1.93+192 — СПРОСИТЬ РАЗРЕШЕНИЕ, А НЕ РАССУЖДАТЬ О НЁМ.
      //
      // Обещано было ещё в +187 и не сделано: тогда появился только показ
      // состояния. Поле 03.08 отдало `read_perm=false`, и версия владельца
      // «дело в правах» осталась строго непроверенной. Запрос стоит здесь,
      // на явном действии владельца, а не в пробе: проба обязана мерить и
      // ничего не менять.
      await ApkInstallChannel.requestStoragePermission();
      // v0.1.88+187: и список, и выбор делает СЕРВИС. Экран только
      // показывает. Своя логика выбора здесь была бы вторым местом,
      // где решается один вопрос, и первая редакция патча ровно на
      // этом и попалась — гейт остался сторожить неиспользуемую
      // функцию в сервисе, пока выбирал виджет.
      final found = await ImportService.searchArchive();
      if (mounted) setState(() => _candidates = found.candidates);
      final chosen = found.chosen;
      if (chosen == null) {
        if (!mounted) return;
        setState(() {
          _preview = ImportPreview.bad(
              '', found.isEmpty ? 'not-found' : 'unreadable', '');
        });
        return;
      }
      final pv = await ImportService.inspect(File(chosen.path),
          appSchemaVersion: schema);
      if (!mounted) return;
      setState(() => _preview = pv);
    } catch (e) {
      if (!mounted) return;
      setState(() => _preview = ImportPreview.bad('', 'error', '$e'));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// v0.1.88+187 — ВЗЯТЬ ФАЙЛ ПО ГРАНТУ.
  ///
  /// Единственный путь, который не зависит от uid прежней установки:
  /// владелец показывает файл сам, система выдаёт временный доступ, мы
  /// немедленно копируем байты к себе. Дальше архив лежит в нашем
  /// каталоге и читается всегда.
  ///
  /// Копия делается СРАЗУ, а не в момент «Восстановить»: грант живёт до
  /// закрытия выбора, и отложенное чтение по тому же uri провалилось бы
  /// тем же `Permission denied`, от которого мы здесь и уходим.
  Future<void> _pickArchive() async {
    setState(() {
      _busy = true;
      _preview = null;
      _importResult = null;
      _candidates = const [];
    });
    final schema = context.read<ConnectionService>().db.schemaVersion;
    try {
      // ДВЕ СТУПЕНИ, а не одна. Рядом уже лежит второй путь — SAF
      // (`pick`, ACTION_OPEN_DOCUMENT), и экран установки использует
      // оба подряд с +176. Ограничься восстановление одним — оно
      // оказалось бы менее живучим, чем установка, без единой причины,
      // а визит у нас один. На этой прошивке оба действия ведут себя
      // непредсказуемо: GET_CONTENT и OPEN_DOCUMENT резолвятся в
      // РАЗНЫЕ активити, и какая из них покажет zip — неизвестно.
      //
      // ТАЙМАУТ обязателен. Ответ приходит из `onActivityResult`, а
      // слот ожидания живёт в активити: умри она, пока открыт выбор,
      // Future не завершится никогда и раздел останется заблокирован
      // до перезапуска приложения.
      var picked = await _pickWithTimeout(ApkInstallChannel.pickContent);
      var uri = picked['uri'];
      if (picked['ok'] != true || uri is! String) {
        picked = await _pickWithTimeout(ApkInstallChannel.pick);
        uri = picked['uri'];
      }
      if (picked['ok'] != true || uri is! String) {
        if (!mounted) return;
        setState(() => _preview = ImportPreview.bad(
            '', 'pick-cancelled', '${picked['error'] ?? ''}'));
        return;
      }
      final staged = await ApkInstallChannel.stageArchive(uri);
      final path = staged['path'];
      if (staged['ok'] != true || path is! String) {
        if (!mounted) return;
        setState(() => _preview = ImportPreview.bad(
            '', 'stage-failed', '${staged['error'] ?? ''}'));
        return;
      }
      final pv =
          await ImportService.inspect(File(path), appSchemaVersion: schema);
      if (!mounted) return;
      setState(() => _preview = pv);
    } catch (e) {
      if (!mounted) return;
      setState(() => _preview = ImportPreview.bad('', 'error', '$e'));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// v0.1.88+187 — выбор файла с потолком ожидания.
  ///
  /// Пять минут — не UX-число, а страховка от потерянного ответа.
  /// Владелец может искать файл долго, поэтому потолок высокий; смысл
  /// не в том, чтобы поторопить, а в том, чтобы экран не остался
  /// заблокированным навсегда, если ответа не будет вообще.
  Future<Map<String, dynamic>> _pickWithTimeout(
    Future<Map<String, dynamic>> Function() call,
  ) async {
    try {
      return await call().timeout(const Duration(minutes: 5));
    } catch (e) {
      return <String, dynamic>{'ok': false, 'error': 'timeout: $e'};
    }
  }

  /// v0.1.93+192 — человеческая причина вместо кода и исключения.
  ///
  /// Поле 03.08 показало на экране `FormatException: Could not find End of
  /// Central Directory Record`. Формально верно и практически бесполезно:
  /// владельцу нужно знать, что делать, а делать надо разное — взять файл
  /// заново, выбрать другой, или указать его вручную.
  String _reasonLine(ImportPreview pv) {
    switch (pv.errorCode) {
      case 'truncated':
        return S.of('dataimp.bad_truncated');
      case 'unreadable':
        return S.of('dataimp.bad_denied');
      case 'not-found':
        return S.of('dataimp.bad_notfound');
      case 'pick-cancelled':
        return S.of('dataimp.bad_cancelled');
      case 'stage-failed':
        return S.of('dataimp.bad_stage');
      default:
        return S
            .of('dataimp.bad_fmt')
            .replaceFirst('{code}', '${pv.errorCode}')
            .replaceFirst('{detail}', '${pv.errorDetail}');
    }
  }

  /// v0.1.88+187 — строка одного кандидата.
  ///
  /// Ключи локали здесь ЛИТЕРАЛЫ и стоят в разных ветках сознательно.
  /// Первая редакция собирала ключ выражением
  /// `'dataimp.cand_${… ? 'denied' : 'bad'}'` — красиво и ровно на один
  /// класс проверок слепо: харнесс ищет ключи по литералам, собранный
  /// ключ он не видит, и опечатка доехала бы до экрана владельца.
  String _candidateLine(ArchiveCandidate c) {
    final mark = c.readable ? '✓' : '✗';
    final String tail;
    if (c.readable) {
      tail = c.humanSize;
    } else if (c.reason == 'denied') {
      tail = S.of('dataimp.cand_denied');
    } else {
      tail = S.of('dataimp.cand_bad');
    }
    return '$mark ${c.fileName} · ${c.origin} · $tail';
  }

  /// v0.1.88+187 — три пробы одной строкой. Ничего не меняет.
  Future<void> _runStorageProbe() async {
    setState(() => _busy = true);
    try {
      final p = await ApkInstallChannel.storageProbe();
      final line = 'listing=${p['listing_total'] ?? '?'}'
          '/${p['listing_zips'] ?? '?'}'
          ' · mediastore=${p['mediastore_rows'] ?? '?'}'
          ' (readable ${p['mediastore_readable'] ?? 0})'
          ' · get_content=${(p['get_content_zip'] as List?)?.length ?? 0}'
          '/${(p['get_content_any'] as List?)?.length ?? 0}'
          ' · send_zip=${(p['send_zip_receivers'] as List?)?.length ?? 0}'
          ' · read_perm=${p['read_storage_granted'] ?? '?'}'
          ' · manage=${p['manage_storage_granted'] ?? '?'}'
          ' · staged=${p['staged_archive_bytes'] ?? 0}';
      debugPrint('StorageProbe: $line');
      if (!mounted) return;
      setState(() => _probeLine = line);
    } catch (e) {
      if (!mounted) return;
      setState(() => _probeLine = 'probe failed: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Подтверждение и постановка в очередь. Замена целиком, поэтому текст
  /// диалога называет обе стороны сделки: что приедет и что исчезнет.
  Future<void> _confirmAndStage() async {
    final pv = _preview;
    if (pv == null || !pv.ok) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(S.of('dataimp.confirm_q')),
        content: Text(S
            .of('dataimp.confirm_desc')
            .replaceFirst('{summary}', pv.countsSummary)),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text(S.of('common.cancel')),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text(S.of('dataimp.restore_btn')),
          ),
        ],
      ),
    );
    if (ok != true) return;
    setState(() => _busy = true);
    final res = await ImportService.stage(
      File(pv.path),
      withSettings: _importSettings && pv.hasSettings,
    );
    if (!mounted) return;
    setState(() {
      _busy = false;
      _pending = res.ok;
      // Список кандидатов относился к прошлому поиску; после
      // постановки в очередь он вводит в заблуждение.
      if (res.ok) _candidates = const [];
      _importResult = res.ok
          ? S.of('dataimp.staged')
          : S.of('dataimp.stage_failed_fmt').replaceFirst('{e}', '${res.error}');
    });
  }

  /// Снять процесс, чтобы обмен состоялся. НЕ удобство.
  ///
  /// Обмен файла базы стоит в `main()`, а на Android повторное открытие
  /// приложения с ЖИВЫМ процессом поднимает прежнюю активити — `main()`
  /// второй раз НЕ выполняется. На этом ГУ процесс живёт часами (поле
  /// 31.07: pid=4746 пережил два с половиной часа сна блока), поэтому
  /// просьба «закройте и откройте» не сработала бы, и импорт молча не
  /// применялся бы никогда. `exit(0)` снимает процесс детерминированно.
  ///
  /// Потеря отложенных записей Drift здесь безобидна по построению: база
  /// всё равно заменяется целиком на следующем старте.
  void _closeApp() {
    exit(0);
  }

  Future<void> _cancelPending() async {
    setState(() => _busy = true);
    await ImportService.cancelPending();
    if (!mounted) return;
    setState(() {
      _busy = false;
      _pending = false;
      _importResult = null;
      _preview = null;
    });
  }

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
              includeLiveLogs: _includeLiveLogs,
              onProgress: (stage) {
                if (mounted) setState(() => _stage = stage);
              },
            )
          : await exporter.exportAll(
              includeTrips: _includeTrips,
              includeSnapshots: _includeSnapshots,
              includeSamples: _includeSamples,
              includeSweeps: _includeSweeps,
              includeLiveLogs: _includeLiveLogs,
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
          _lastResult = S
              .of('dataexp.saved_fmt')
              .replaceFirst('{size}', result.humanSize)
              .replaceFirst('{summary}', summary)
              .replaceFirst('{path}', result.zipPath);
          // v0.1.93+192 — жалоба самопроверки дописывается к той же
          // строке, а не заводит второе место показа: владелец смотрит
          // сюда после экспорта, и негодный файл обязан быть виден
          // ЗДЕСЬ, пока машина под рукой.
          final warn = result.writeWarning;
          if (warn != null) {
            _lastResult = '$_lastResult\n'
                '${S.of('dataexp.write_warn_fmt').replaceFirst('{detail}', warn)}';
          }
        } else {
          _lastResult = result.sharedSuccessfully
              ? S
                  .of('dataexp.shared_fmt')
                  .replaceFirst('{size}', result.humanSize)
                  .replaceFirst('{summary}', summary)
              : S
                  .of('dataexp.share_cancelled_fmt')
                  .replaceFirst('{size}', result.humanSize)
                  .replaceFirst('{summary}', summary);
        }
      });
    } catch (e) {
      if (!mounted) return;
      setState(() =>
          _lastResult = S.of('dataexp.error_fmt').replaceFirst('{e}', '$e'));
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
            content: Text(S
                .of('dataexp.export_failed_fmt')
                .replaceFirst('{e}', '$e'))),
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
            child: Text(S.of('common.cancel')),
          ),
          TextButton(
            style: TextButton.styleFrom(foregroundColor: Colors.redAccent),
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(S.of('common.delete')),
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
        SnackBar(
            content:
                Text(S.of('dataexp.error_fmt').replaceFirst('{e}', '$e'))),
      );
    }
  }
}
