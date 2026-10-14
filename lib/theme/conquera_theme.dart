import 'dart:ui' show FontFeature;

import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

/// Every color in the app lives here. Blue does the work: a clear
/// light-blue sea, a header tinted to match, and a deep navy for text and
/// the selection outline. Land stays pale so players' own colors are the
/// only saturated hues on the map.
class ConqueraColors {
  const ConqueraColors._();

  // Map
  static const Color sea = Color(0xFFA7CBE3);
  static const Color land = Color(0xFFF1F6F3);
  static const Color border = Color(0xFF9BB6C6);

  // Interface
  static const Color surface = Color(0xFFE8F2FA); // header strip
  static const Color divider = Color(0xFF8DB4D2);
  static const Color ink = Color(0xFF12324A);
  static const Color muted = Color(0xFF4F6B82);
  static const Color accent = Color(0xFF2F6F9F);

  // Gold is the one resource color.
  static const Color brass = Color(0xFFB8892B);

  // Errors and "can't afford" hints.
  static const Color danger = Color(0xFF9B2C2C);
}

/// Spacing scale (logical pixels).
class ConqueraSpace {
  const ConqueraSpace._();

  static const double xs = 4;
  static const double sm = 8;
  static const double md = 16;
  static const double lg = 24;
  static const double xl = 40;
}

/// Type scale. One family (Barlow): the semi-condensed cut carries names
/// and numbers, regular Barlow carries labels and values.
class ConqueraText {
  const ConqueraText._();

  /// Country name in the info panel.
  static TextStyle get title => GoogleFonts.barlowSemiCondensed(
        fontSize: 24,
        fontWeight: FontWeight.w600,
        height: 1.1,
        color: ConqueraColors.ink,
      );

  /// Player names.
  static TextStyle get name => GoogleFonts.barlowSemiCondensed(
        fontSize: 18,
        fontWeight: FontWeight.w600,
        height: 1.2,
        color: ConqueraColors.ink,
      );

  /// Resource amounts. Tabular figures so digits don't jitter as gold ticks.
  static TextStyle get figure => GoogleFonts.barlowSemiCondensed(
        fontSize: 20,
        fontWeight: FontWeight.w600,
        height: 1.2,
        color: ConqueraColors.ink,
        fontFeatures: const [FontFeature.tabularFigures()],
      );

  /// Small captions: stat labels, income rate.
  static TextStyle get label => GoogleFonts.barlow(
        fontSize: 12.5,
        fontWeight: FontWeight.w400,
        height: 1.2,
        color: ConqueraColors.muted,
      );

  /// Same type as the buttons (used by the on-map pop-ups).
  static TextStyle get button => GoogleFonts.barlow(
        fontSize: 14,
        fontWeight: FontWeight.w500,
        height: 1.2,
        color: ConqueraColors.ink,
      );

  /// Stat values.
  static TextStyle get value => GoogleFonts.barlow(
        fontSize: 15,
        fontWeight: FontWeight.w500,
        height: 1.2,
        color: ConqueraColors.ink,
      );
}

ThemeData buildConqueraTheme() {
  final base = ThemeData(
    useMaterial3: true,
    brightness: Brightness.light,
    colorScheme: const ColorScheme.light(
      primary: ConqueraColors.ink,
      onPrimary: Colors.white,
      surface: ConqueraColors.surface,
      onSurface: ConqueraColors.ink,
    ),
    scaffoldBackgroundColor: ConqueraColors.sea,
  );

  // One button look for the whole game: hollow, thin outline, regular
  // weight. FilledButton, OutlinedButton and TextButton all share it, so any
  // button added later matches the "Manage" button without extra styling.
  // Only the outline color changes for special actions (Attack, Destroy...).
  final hollow = _hollowButtonStyle();

  return base.copyWith(
    textTheme: GoogleFonts.barlowTextTheme(base.textTheme).apply(
      bodyColor: ConqueraColors.ink,
      displayColor: ConqueraColors.ink,
    ),
    progressIndicatorTheme: const ProgressIndicatorThemeData(
      color: ConqueraColors.accent,
    ),
    filledButtonTheme: FilledButtonThemeData(style: hollow),
    outlinedButtonTheme: OutlinedButtonThemeData(style: hollow),
    textButtonTheme: TextButtonThemeData(
      style: hollow.copyWith(
        side: const MaterialStatePropertyAll(BorderSide.none),
      ),
    ),
  );
}

/// The shared hollow button: transparent, 1px ink outline, medium weight.
/// Disabled buttons go muted with a faint outline.
ButtonStyle _hollowButtonStyle() {
  bool disabled(Set<MaterialState> s) => s.contains(MaterialState.disabled);

  return ButtonStyle(
    backgroundColor: const MaterialStatePropertyAll(Colors.transparent),
    surfaceTintColor: const MaterialStatePropertyAll(Colors.transparent),
    elevation: const MaterialStatePropertyAll(0),
    foregroundColor: MaterialStateProperty.resolveWith(
      (s) => disabled(s) ? ConqueraColors.muted.withAlpha(150) : ConqueraColors.ink,
    ),
    side: MaterialStateProperty.resolveWith(
      (s) => BorderSide(
        color: disabled(s) ? ConqueraColors.divider : ConqueraColors.ink,
      ),
    ),
    overlayColor: MaterialStateProperty.resolveWith(
      (s) => s.contains(MaterialState.pressed)
          ? ConqueraColors.ink.withAlpha(20)
          : s.contains(MaterialState.hovered)
              ? ConqueraColors.ink.withAlpha(10)
              : null,
    ),
    minimumSize: const MaterialStatePropertyAll(Size(0, 36)),
    padding: const MaterialStatePropertyAll(
      EdgeInsets.symmetric(horizontal: 14),
    ),
    shape: MaterialStatePropertyAll(
      RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
    ),
    textStyle: MaterialStatePropertyAll(
      GoogleFonts.barlow(fontSize: 14, fontWeight: FontWeight.w500),
    ),
  );
}