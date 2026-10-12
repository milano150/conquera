import 'package:flutter/material.dart';

/// Screen transition: the old screen fades out to white, then the new screen
/// fades in from white. No blur and no colors, so white screens stay white all
/// the way through. Both halves belong to this route, so it works over any
/// screen underneath, and popping plays it backwards.
class FadeRoute<T> extends PageRouteBuilder<T> {
  FadeRoute({required WidgetBuilder builder})
      : super(
          pageBuilder: (context, animation, secondaryAnimation) =>
              builder(context),
          transitionDuration: const Duration(milliseconds: 700),
          reverseTransitionDuration: const Duration(milliseconds: 500),
          transitionsBuilder: _transition,
        );

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

        // First half: white covers the old screen. Second half: the new
        // screen fades in over that white.
        final cover = Curves.easeInOut.transform((p * 2).clamp(0.0, 1.0));
        final reveal = Curves.easeInOut.transform((p * 2 - 1).clamp(0.0, 1.0));

        return Stack(
          fit: StackFit.expand,
          children: [
            if (p < 1)
              IgnorePointer(
                child: ColoredBox(
                  color: Colors.white.withAlpha((255 * cover).round()),
                ),
              ),
            IgnorePointer(
              ignoring: p < 1,
              child: Opacity(opacity: reveal, child: page),
            ),
          ],
        );
      },
    );
  }
}