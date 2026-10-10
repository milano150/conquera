import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';

import '../theme/conquera_theme.dart';

/// Screen transition: the old screen blurs out and fades into the sea color,
/// then the new screen blurs in. Both halves belong to this route, so it
/// works over any screen underneath. Popping plays the same thing backwards.
class BlurRoute<T> extends PageRouteBuilder<T> {
  BlurRoute({required WidgetBuilder builder})
      : super(
          pageBuilder: (context, animation, secondaryAnimation) =>
              builder(context),
          transitionDuration: const Duration(milliseconds: 800),
          reverseTransitionDuration: const Duration(milliseconds: 600),
          transitionsBuilder: _transition,
        );

  static const double _maxBlur = 14;

  static Widget _transition(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    return AnimatedBuilder(
      animation: animation,
      child: child,
      builder: (context, page) {
        final p = animation.value;

        // First half: the old screen (under this route) blurs out.
        // Second half: this route's page blurs in.
        // `amount` is 0 = sharp, 1 = fully blurred; it peaks at p = 0.5.
        final blurringOut = p < 0.5;
        final amount = Curves.easeInOut.transform(
          1 - (2 * p - 1).abs(),
        );

        return Stack(
          fit: StackFit.expand,
          children: [
            // The page stays invisible (and untouchable) until the old
            // screen is gone, then fades in.
            IgnorePointer(
              ignoring: p < 1,
              child: Opacity(
                opacity: blurringOut ? 0.0 : (2 * p - 1).clamp(0.0, 1.0).toDouble(),
                child: page,
              ),
            ),
            if (p > 0 && p < 1)
              IgnorePointer(
                child: BackdropFilter(
                  filter: ImageFilter.blur(
                    sigmaX: _maxBlur * amount,
                    sigmaY: _maxBlur * amount,
                  ),
                  child: ColoredBox(
                    color: ConqueraColors.sea.withAlpha((255 * amount).round()),
                  ),
                ),
              ),
          ],
        );
      },
    );
  }
}