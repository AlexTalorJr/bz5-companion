import 'package:flutter/widgets.dart';

/// Layout breakpoints for the app.
///
/// We have three distinct form factors:
///   - PHONE (portrait or landscape): ~360-960 dp on either axis.
///     Uses BottomNavigationBar.
///   - HEAD UNIT LANDSCAPE (e.g. BZ5): 2175 × 1224 dp, 15.6" 16:9 2.5K.
///     Uses NavigationRail + multi-pane wide layouts.
///   - HEAD UNIT PORTRAIT (e.g. BZ3): 12.8" central screen mounted vertically,
///     typically ~720 × 1280 dp in portrait. Visually too tall for the
///     three-column landscape layout — falls back to phone layout in v0.1.10.
///
/// Detection rule:
///   width ≥ 840 dp AND width > height  →  head unit (landscape) layout
///   anything else                       →  phone layout
///
/// Why both conditions: a head unit with 1280×720 dp in landscape qualifies
/// (1280 ≥ 840 and 1280 > 720). Same unit physically rotated to portrait
/// becomes 720×1280 — 720 < 840 so phone layout. A BZ3 unit at, say,
/// 1080×1920 in portrait: 1080 ≥ 840 but 1080 < 1920 → still phone layout
/// (no three-column landscape compression on tall screens).
class LayoutBreakpoints {
  static const double headUnit = 840.0;

  /// True when the viewport is wide enough by absolute dp.
  /// Doesn't consider orientation — use [useHeadUnitLayout] for layout decisions.
  static bool isWide(BuildContext context) =>
      MediaQuery.of(context).size.width >= headUnit;

  /// True when the device should use the dedicated wide head-unit layout
  /// (NavigationRail, three-column dashboard, split-pane history, etc.).
  ///
  /// Requires BOTH minimum width AND landscape orientation. A vertically-
  /// mounted head unit (BZ3) auto-falls-back to phone layout — proven adequate
  /// for tall narrow screens and avoids cramming three columns into a tall
  /// viewport.
  static bool useHeadUnitLayout(BuildContext context) {
    final size = MediaQuery.of(context).size;
    return size.width >= headUnit && size.width > size.height;
  }
}
