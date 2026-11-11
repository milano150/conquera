import 'package:flutter/material.dart';

/// Screen transition for moving through the menus, the same slide as the
/// home screen's Play button: the new screen slides in from the right while
/// the old one slides out to the left, as one piece. Popping plays it
/// backwards.
class SlideRoute<T> extends PageRouteBuilder<T> {
  SlideRoute({required WidgetBuilder builder, super.settings})
      : super(
          pageBuilder: (context, animation, secondaryAnimation) =>
              builder(context),
          transitionDuration: const Duration(milliseconds: 380),
          reverseTransitionDuration: const Duration(milliseconds: 380),
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
      curve: Curves.easeInOutCubic,
    );
    final leave = CurvedAnimation(
      parent: secondaryAnimation,
      curve: Curves.easeInOutCubic,
    );
    return SlideTransition(
      // When another screen is pushed on top, this one slides fully left.
      position: Tween<Offset>(
        begin: Offset.zero,
        end: const Offset(-1, 0),
      ).animate(leave),
      child: SlideTransition(
        position: Tween<Offset>(
          begin: const Offset(1, 0),
          end: Offset.zero,
        ).animate(enter),
        child: child,
      ),
    );
  }
}