import 'package:flutter/widgets.dart';

/// v0.1.4: Layout breakpoints for the app.
///
/// We have two distinct form factors:
///   - PHONE: ~360-411 dp wide (BottomNavigationBar at the bottom)
///   - HEAD UNIT: 2175 × 1224 dp (15.6" 16:9 2.5K Toyota BZ5 launcher),
///     way past Material's "expanded" breakpoint of 1200 dp.
///
/// We pick a single threshold of 840 dp:
///   - < 840 dp → phone layout (everything as it was before v0.1.4)
///   - ≥ 840 dp → head unit / tablet layout (NavigationRail + multi-pane)
///
/// 840 dp matches Material's "compact-to-medium" boundary and conveniently
/// falls between any reasonable phone (≤500 dp landscape) and the head unit.
class LayoutBreakpoints {
  static const double headUnit = 840.0;

  static bool isWide(BuildContext context) =>
      MediaQuery.of(context).size.width >= headUnit;

  /// True when the device is wide enough that we should hide elements meant
  /// only for narrow screens (e.g., phone-style BottomNav).
  static bool useHeadUnitLayout(BuildContext context) => isWide(context);
}
