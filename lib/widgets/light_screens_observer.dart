import 'package:flutter/widgets.dart';

import '../theme/conquera_theme.dart';

/// Route name for screens that must always be drawn in light mode.
const String kLightRouteName = 'light';

bool _isLight(Route<dynamic>? r) =>
    r is PageRoute &&
    (r.settings.name == Navigator.defaultRouteName ||
        r.settings.name == kLightRouteName);

/// Keeps the home and join screens in light mode whatever the chosen mode
/// is, and switches back for everything else.
class LightScreensObserver extends NavigatorObserver {
  /// Delays line up with the white fade of FadeRoute, so the swap happens
  /// while the screen is covered.
  void _sync(Route<dynamic>? top, Duration delay) {
    if (top == null || top is! PageRoute) return;
    final want = _isLight(top) ? ConqueraMode.light : null;
    Future<void>.delayed(delay, () {
      if (ConqueraColors.override == want) return;
      ConqueraColors.override = want;
      WidgetsBinding.instance.reassembleApplication();
    });
  }

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) =>
      _sync(route, _isLight(route) ? Duration.zero : const Duration(milliseconds: 350));

  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) =>
      _sync(newRoute, _isLight(newRoute) ? Duration.zero : const Duration(milliseconds: 350));

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) =>
      _sync(previousRoute, const Duration(milliseconds: 250));
}
