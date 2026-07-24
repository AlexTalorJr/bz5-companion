// v0.1.62+161 «Атлас» patch 3 — the shareable 1080×1350 PNG
// (SPEC.md v1.1 §6.12, mockups [5g] / [5h]).
//
// HOW THE CAPTURE WORKS (owner decision, 25.07 — «Поделиться только для
// телефона, делай как предлагаешь»): the artwork is rendered on a VISIBLE
// preview route and captured from that live RepaintBoundary. The
// alternative — an off-screen render — is a trap: `Offstage` subtrees are
// never painted, so `toImage` on a boundary inside one throws, and the
// manual PipelineOwner/RenderView dance is ~60 lines of version-sensitive
// plumbing for zero user benefit. A preview also means the owner sees
// exactly what leaves the phone before it leaves.
//
// The boundary is laid out at exactly 1080×1350 logical px, so
// `toImage(pixelRatio: 1.0)` is a 1080×1350 PNG regardless of the screen
// it was previewed on. The outer FittedBox only scales the PAINTED
// result down to the viewport; the boundary keeps its own size.
//
// Deviation on the cell size (documented): the contract says «клетка
// 15×15 px», which is the CSS pixel of the 360-wide mockup. On the
// 1080-wide canvas the same fixed cell is 45 dp (≈40 after the
// fit-to-canvas factor). The invariant that matters — a FIXED cell so
// the whole 11×12 matrix is always present, never a screenshot of the
// visible part — is preserved, and the bigger cell is what makes
// checklist п.14 (open cells distinguishable in a compressed PNG on a
// white feed) actually pass.

import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:path_provider/path_provider.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:share_plus/share_plus.dart';

import '../data/atlas_projection.dart';
import '../l10n/strings.dart';
import '../theme/atlas_tokens.dart';
import 'atlas_grid.dart' show atlasDaysWord, atlasMonthNames;

/// Install page the QR points at (§6.12 п.6).
const String kAtlasShareUrl =
    'https://apkpure.com/p/com.bz5companion.bz5_companion';

/// Below this many open cells the hero line speaks in the «начато»
/// register instead of the «собрано» one (mockup [5h] vs [5g]).
const int kAtlasHeroMatureCells = 3;

/// Preview + share route. Phone only — the head unit is a viewer
/// («просмотр — детали на телефоне», §7.2) and has no share sheet worth
/// the name.
class AtlasExportScreen extends StatefulWidget {
  final AtlasGridData data;
  const AtlasExportScreen({super.key, required this.data});

  @override
  State<AtlasExportScreen> createState() => _AtlasExportScreenState();
}

class _AtlasExportScreenState extends State<AtlasExportScreen> {
  final GlobalKey _boundaryKey = GlobalKey();
  bool _busy = false;

  Future<void> _share() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final ctx = _boundaryKey.currentContext;
      final obj = ctx?.findRenderObject();
      if (obj is! RenderRepaintBoundary) {
        throw StateError('export boundary not mounted');
      }
      // pixelRatio 1.0 — the boundary IS 1080×1350 logical px.
      final image = await obj.toImage(pixelRatio: 1.0);
      final png = await image.toByteData(format: ui.ImageByteFormat.png);
      image.dispose();
      if (png == null) throw StateError('png encode returned null');
      final dir = await getTemporaryDirectory();
      final stamp = DateTime.now()
          .toIso8601String()
          .replaceAll(RegExp(r'[^0-9]'), '')
          .substring(0, 14);
      final name = 'bz5_atlas_$stamp.png';
      final file = File('${dir.path}/$name');
      await file.writeAsBytes(png.buffer.asUint8List(), flush: true);
      // ignore: deprecated_member_use
      await Share.shareXFiles(
        [XFile(file.path, mimeType: 'image/png', name: name)],
        subject: S.of('export.share_subject'),
        text: S.of('export.share_text'),
      );
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('${S.of('export.failed')} $e'),
        ));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AtlasTokens.bg,
      appBar: AppBar(title: Text(S.of('export.title'))),
      body: Column(
        children: [
          Expanded(
            child: Center(
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: FittedBox(
                  fit: BoxFit.contain,
                  child: RepaintBoundary(
                    key: _boundaryKey,
                    child: AtlasExportArtwork(data: widget.data),
                  ),
                ),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 20),
            child: Column(
              children: [
                Text(S.of('export.caption'),
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                        fontSize: 11, color: AtlasTokens.t45)),
                const SizedBox(height: 10),
                FilledButton.icon(
                  style: FilledButton.styleFrom(
                    backgroundColor: AtlasTokens.progress,
                    foregroundColor: AtlasTokens.onProgress,
                    shape: const StadiumBorder(),
                    padding: const EdgeInsets.symmetric(
                        vertical: 12, horizontal: 28),
                  ),
                  onPressed: _busy ? null : _share,
                  icon: _busy
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.ios_share, size: 20),
                  label: Text(S.of('export.share')),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// The artwork itself: exactly 1080×1350 logical px.
class AtlasExportArtwork extends StatelessWidget {
  final AtlasGridData data;
  const AtlasExportArtwork({super.key, required this.data});

  static const double kWidth = 1080;
  static const double kHeight = 1350;

  /// Fill class of one matrix cell (§6.12 table).
  static Color _fill(AtlasGridData d, int band, int? window) {
    final c = d.byKey[atlasCellKey(band, window)];
    if (c == null) return AtlasTokens.expAhead;
    if (d.best != null && d.best!.key == c.key) return AtlasTokens.expBest;
    return c.sessions >= 2 ? AtlasTokens.expMulti : AtlasTokens.expOpen;
  }

  String _hero() {
    final months = atlasMonthNames();
    final best = data.best;
    final first = data.firstCell;
    final days = data.daysCollected();
    if (data.cellCount >= kAtlasHeroMatureCells && best != null) {
      return S
          .of('export.hero_mature')
          .replaceFirst('{n}', '$days')
          .replaceFirst('{days}', atlasDaysWord(days))
          .replaceFirst('{v}', '${best.band}')
          .replaceFirst('{w}', _windowWord(best.window))
          .replaceFirst('{x}', best.median.toStringAsFixed(1));
    }
    if (first != null) {
      return S
          .of('export.hero_early')
          .replaceFirst('{n}', '$days')
          .replaceFirst('{days}', atlasDaysWord(days))
          .replaceFirst('{v}', '${first.band}')
          .replaceFirst('{w}', _windowWord(first.window))
          .replaceFirst('{x}', first.median.toStringAsFixed(1));
    }
    // Empty atlas — honest, still shareable («карта впереди»).
    return S.of('export.hero_none').replaceFirst(
        '{month}', months[DateTime.now().month - 1]);
  }

  static String _windowWord(int? w) =>
      w == null ? S.of('atlas.window_unknown') : '${atlasWindowLabel(w)}°';

  @override
  Widget build(BuildContext context) {
    final months = atlasMonthNames();
    final now = DateTime.now();
    final bands = atlasAllBands();
    final windows = atlasAllWindows();

    return SizedBox(
      width: kWidth,
      height: kHeight,
      child: ColoredBox(
        color: AtlasTokens.bg,
        child: Center(
          // Fit-to-canvas: the column is laid out at its intrinsic
          // height and scaled to the canvas. Overflow stripes in a
          // shared PNG are unacceptable, and BoxFit.contain makes them
          // structurally impossible.
          child: FittedBox(
            fit: BoxFit.contain,
            child: SizedBox(
              width: kWidth,
              child: Padding(
                padding: const EdgeInsets.all(60),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // 1. Name + month.
                    Row(
                      children: [
                        const Icon(Icons.speed,
                            size: 54, color: AtlasTokens.progress),
                        const SizedBox(width: 24),
                        const Text('BZ5 Companion',
                            style: TextStyle(
                                fontSize: 39,
                                fontWeight: FontWeight.w500,
                                letterSpacing: 0.9,
                                color: AtlasTokens.t100)),
                        const Spacer(),
                        Text(
                          S
                              .of('export.month_line')
                              .replaceFirst('{month}', months[now.month - 1])
                              .replaceFirst('{year}', '${now.year}'),
                          style: const TextStyle(
                              fontSize: 33, color: AtlasTokens.t40),
                        ),
                      ],
                    ),
                    const SizedBox(height: 42),
                    // 2. Hero line for a recipient who has never seen
                    // the grid.
                    Text(_hero(),
                        style: const TextStyle(
                            fontSize: 45,
                            height: 1.4,
                            color: AtlasTokens.t85)),
                    const SizedBox(height: 42),
                    // 3–4. The WHOLE matrix + axis captions.
                    _ExportMatrix(data: data, bands: bands, windows: windows),
                    const SizedBox(height: 42),
                    // 5–6. Legend + QR.
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        const Expanded(child: _ExportLegend()),
                        const SizedBox(width: 36),
                        Container(
                          padding: const EdgeInsets.all(12),
                          decoration: BoxDecoration(
                            color: Colors.white,
                            borderRadius: BorderRadius.circular(18),
                          ),
                          child: QrImageView(
                            data: kAtlasShareUrl,
                            version: QrVersions.auto,
                            size: 168,
                            backgroundColor: Colors.white,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 30),
                    Text(S.of('export.footer'),
                        style: const TextStyle(
                            fontSize: 27,
                            height: 1.5,
                            color: AtlasTokens.t35)),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _ExportMatrix extends StatelessWidget {
  final AtlasGridData data;
  final List<int> bands;
  final List<int?> windows;
  const _ExportMatrix({
    required this.data,
    required this.bands,
    required this.windows,
  });

  static const double _cell = 45;
  static const double _gap = 6;
  static const double _labelW = 66;

  /// Bands that carry at least one OPEN cell — the label is brighter for
  /// them. Ghosts do not exist in the export (§6.12: the whole map is
  /// drawn, unopened cells are a thin slab, never a dashed outline).
  Set<int> get _liveBands => {for (final c in data.cells) c.band};

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: AtlasTokens.exportPanel,
        border: Border.all(color: AtlasTokens.line, width: 1.5),
        borderRadius: BorderRadius.circular(36),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 30, vertical: 36),
      child: Column(
        children: [
          // Window class strip (§6.9 tints, .14 / .12 in the export).
          Row(
            children: [
              const SizedBox(width: _labelW),
              for (final w in windows) ...[
                const SizedBox(width: _gap),
                Expanded(
                  child: Container(
                    height: 27,
                    decoration: BoxDecoration(
                      color: atlasWindowIsRare(w)
                          ? AtlasTokens.expRareTint
                          : (atlasWindowIsHot(w)
                              ? AtlasTokens.expHotTint
                              : null),
                      borderRadius: BorderRadius.circular(6),
                    ),
                  ),
                ),
              ],
            ],
          ),
          for (final b in bands) ...[
            const SizedBox(height: _gap),
            Row(
              children: [
                SizedBox(
                  width: _labelW,
                  child: Text(
                    '$b',
                    style: TextStyle(
                      fontSize: 24,
                      fontWeight: _liveBands.contains(b)
                          ? FontWeight.w500
                          : FontWeight.w400,
                      color: _liveBands.contains(b)
                          ? AtlasTokens.t55
                          : AtlasTokens.t35,
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                  ),
                ),
                for (final w in windows) ...[
                  const SizedBox(width: _gap),
                  Expanded(
                    child: _ExportCell(
                      fill: AtlasExportArtwork._fill(data, b, w),
                      best: data.best != null &&
                          data.best!.band == b &&
                          data.best!.window == w,
                    ),
                  ),
                ],
              ],
            ),
          ],
          const SizedBox(height: 15),
          // Edge window captions (§6.12 п.4).
          Padding(
            padding: const EdgeInsets.only(left: _labelW + _gap),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                for (final s in const ['≤ −20°', '0–5°', '20–25°', '+40°'])
                  Text(s,
                      style: const TextStyle(
                          fontSize: 24, color: AtlasTokens.t35)),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _ExportCell extends StatelessWidget {
  final Color fill;
  final bool best;
  const _ExportCell({required this.fill, required this.best});

  @override
  Widget build(BuildContext context) {
    return Container(
      height: _ExportMatrix._cell,
      decoration: BoxDecoration(
        color: fill,
        borderRadius: BorderRadius.circular(6),
        border: best
            ? Border.all(color: AtlasTokens.expBestBorder, width: 4.5)
            : null,
      ),
    );
  }
}

class _ExportLegend extends StatelessWidget {
  const _ExportLegend();

  @override
  Widget build(BuildContext context) {
    Widget row(Color fill, Color border, double width, String label) => Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: Row(
            children: [
              Container(
                width: 42,
                height: 42,
                decoration: BoxDecoration(
                  color: fill,
                  borderRadius: BorderRadius.circular(9),
                  border: Border.all(color: border, width: width),
                ),
              ),
              const SizedBox(width: 21),
              Text(label,
                  style: const TextStyle(
                      fontSize: 30, color: AtlasTokens.t55)),
            ],
          ),
        );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        row(AtlasTokens.expOpen, AtlasTokens.expSwatchBorder, 3,
            S.of('export.legend_open')),
        row(AtlasTokens.expMulti, AtlasTokens.expSwatchBorder, 3,
            S.of('export.legend_multi')),
        row(AtlasTokens.expBest, AtlasTokens.expBestBorder, 4.5,
            S.of('export.legend_best')),
        row(AtlasTokens.expRareTint, AtlasTokens.rareOutline, 3,
            S.of('export.legend_rare')),
        row(AtlasTokens.expAhead, AtlasTokens.expSwatchBorder, 3,
            S.of('export.legend_ahead')),
      ],
    );
  }
}
