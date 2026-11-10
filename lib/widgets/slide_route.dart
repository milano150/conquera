import 'package:flutter/material.dart';

/// Screen transition for moving through the menus: the new screen slides in
/// from the right while the old one drifts a little to the left; popping
/// plays it backwards (the screen slides out to the right).
class SlideRoute<T> extends PageRouteBuilder<T> {
  SlideRoute({required WidgetBuilder builder, super.settings})
      : super(
          pageBuilder: (context, animation, secondaryAnimation) =>
              builder(context),
          transitionDuration: const Duration(milliseconds: 380),
          reverseTransitionDuration: const Duration(milliseconds: 320),
          transitionsBuilder: _transition,
        );

  static Widget _transition(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    final enter = CurvedAnimation(
      parent: animation,
      curve: Curves.easeOutCubic,
      reverseCurve: Curves.easeInCubic,
    );
    final leave = CurvedAnimation(
      parent: secondaryAnimation,
      curve: Curves.easeOutCubic,
      reverseCurve: Curves.easeInCubic,
    );
    return SlideTransition(
      // When another screen is pushed on top, this one drifts left.
      position: Tween<Offset>(
        begin: Offset.zero,
        end: const Offset(-0.25, 0),
      ).animate(leave),
      child: SlideTransition(
        position: Tween<Offset>(
          begin: const Offset(1, 0),
          end: Offset.zero,
        ).animate(enter),
        child: DecoratedBox(
          decoration: const BoxDecoration(
            boxShadow: [
              BoxShadow(color: Color(0x1A000000), blurRadius: 18),
            ],
          ),
          child: child,
        ),
      ),
    );
  }
}