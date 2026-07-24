// v0.1.62+161 «Атлас» patch 3 — design tokens of the UI contract
// (SPEC.md v1.1 §2) in one place. First file of lib/theme/ — the
// directory did not exist before this patch.
//
// Every colour is written as an explicit const ARGB literal rather than
// `Colors.x.withValues(alpha: …)`: const values can live inside const
// constructors (the const_l10n gate's sibling hazard is the opposite
// direction, but const-ness still buys us free widget canonicalisation),
// and the alpha byte is then auditable against the contract table.
//
// Alpha reference: .04→0x0A · .06→0x0F · .07→0x12 · .08→0x14 · .12→0x1F
// .14→0x24 · .18→0x2E · .20→0x33 · .25→0x40 · .35→0x59 · .40→0x66
// .45→0x73 · .46→0x75 · .50→0x80 · .55→0x8C · .60→0x99 · .66→0xA8
// .85→0xD9
//
// NOTE (owner decision, 25.07): the 1.1 draft renamed «Атлас» to
// «Альманах» and replaced the metal star with a chevron rosette. Both
// were REVERTED by the owner for this patch — the coverage mark stays a
// star with bronze / silver / gold tints, and every UI string keeps
// saying «Атлас». The token names below are the contract's
// (`markOne/Five/Fifteen`) because they are colour names, not word
// choices; the words live in l10n.
import 'package:flutter/material.dart';

class AtlasTokens {
  AtlasTokens._();

  // ── surfaces ──
  static const Color bg = Color(0xFF07090D);
  static const Color card = Color(0xFF141A24);
  static const Color cardMuted = Color(0xFF101520);
  static const Color cardActive = Color(0xFF18222E);
  static const Color exportPanel = Color(0xFF0B0E13);

  // ── reveal / plate ──
  static const Color revealBg = Color(0xFF141F1A);
  static const Color revealBorder = Color(0x405CE85C);

  // ── progress family ──
  static const Color progress = Color(0xFF1DE9B6);
  static const Color progressTrack = Color(0x14FFFFFF);
  static const Color progressGhost = Color(0x801DE9B6);
  static const Color onProgress = Color(0xFF00251C);

  // ── semantics ──
  static const Color info = Color(0xFF81D4FA);
  static const Color success = Color(0xFF5CE85C);
  static const Color gearP = Color(0xFF4FC3F7);

  // ── coverage mark (star levels 1 / 5 / 15) ──
  static const Color markOne = Color(0xFFC0895E);
  static const Color markFive = Color(0xFFB9C4CE);
  static const Color markFifteen = Color(0xFFE9C46A);

  // ── temperature-window classes (§6.9) ──
  static const Color rareWindow = Color(0xFF81D4FA);
  static const Color rareTint = Color(0x1281D4FA);
  static const Color rareOutline = Color(0x2E81D4FA);
  static const Color hotWindow = Color(0xFFFFB4A9);
  static const Color hotTint = Color(0x0FFFB4A9);

  // ── frontier ghost (§7.2) ──
  static const Color ghostFrontier = Color(0x24FFFFFF);

  // ── new-cell outline (§6.5) ──
  static const Color newCellOutline = Color(0x661DE9B6);

  // ── text ladder (§2) ──
  static const Color t100 = Color(0xFFFFFFFF);
  static const Color t85 = Color(0xD9FFFFFF);
  static const Color t60 = Color(0x99FFFFFF);
  static const Color t55 = Color(0x8CFFFFFF);
  static const Color t50 = Color(0x80FFFFFF);
  static const Color t45 = Color(0x73FFFFFF);
  static const Color t40 = Color(0x66FFFFFF);
  static const Color t35 = Color(0x59FFFFFF);
  static const Color t22 = Color(0x38FFFFFF);
  static const Color line = Color(0x14FFFFFF);

  // ── export scale (§6.12) — DELIBERATELY not the screen tokens: on a
  // white social-media background and after PNG compression the screen
  // `card` / `cardActive` differ by under 2 % luminance and the map
  // reads as empty. ──
  static const Color expAhead = Color(0x0AFFFFFF);
  static const Color expOpen = Color(0x331DE9B6);
  static const Color expMulti = Color(0x751DE9B6);
  static const Color expBest = Color(0xA81DE9B6);
  static const Color expBestBorder = Color(0xFFE9C46A);
  static const Color expRareTint = Color(0x2481D4FA);
  static const Color expHotTint = Color(0x1FFFB4A9);
  static const Color expSwatchBorder = Color(0x1FFFFFFF);

  /// Coverage-mark tint for a cell with [sessions] independent logical
  /// sessions. Levels are 1 / 5 / 15 (§6.4 thresholds kept from the
  /// reward engine — `star_up` fires at 5 and 15).
  static Color markColor(int sessions) {
    if (sessions >= 15) return markFifteen;
    if (sessions >= 5) return markFive;
    return markOne;
  }
}

/// The navigation badge of «Замеры» (§5): green dot `success`, **14 dp on
/// every device**, 2 dp outline in the colour of the surface underneath.
///
/// Material's own [Badge] has no border parameter, and the contract is
/// explicit about the outline (a borderless 8 dp dot was physically
/// invisible in the field — that is the whole reason the sticky plate
/// §6.11 exists), so the dot is drawn by hand.
class MeasureBadge extends StatelessWidget {
  final Widget child;
  final bool visible;

  /// Colour of the surface behind the badge — the outline paints in it
  /// so the dot reads as a hole punched in the icon.
  final Color surface;

  const MeasureBadge({
    super.key,
    required this.child,
    required this.visible,
    this.surface = AtlasTokens.bg,
  });

  @override
  Widget build(BuildContext context) {
    if (!visible) return child;
    return Stack(
      clipBehavior: Clip.none,
      children: [
        child,
        Positioned(
          top: -3,
          right: -6,
          child: Container(
            width: 14,
            height: 14,
            decoration: BoxDecoration(
              color: AtlasTokens.success,
              shape: BoxShape.circle,
              border: Border.all(color: surface, width: 2),
            ),
          ),
        ),
      ],
    );
  }
}
