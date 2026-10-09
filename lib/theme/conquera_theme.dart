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

  final buttonShape = RoundedRectangleBorder(
    borderRadius: BorderRadius.circular(6),
  );

  return base.copyWith(
    textTheme: GoogleFonts.barlowTextTheme(base.textTheme).apply(
      bodyColor: ConqueraColors.ink,
      displayColor: ConqueraColors.ink,
    ),
    progressIndicatorTheme: const ProgressIndicatorThemeData(
      color: ConqueraColors.accent,
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: ConqueraColors.ink,
        foregroundColor: Colors.white,
        disabledBackgroundColor: ConqueraColors.divider.withAlpha(90),
        disabledForegroundColor: ConqueraColors.muted,
        minimumSize: const Size(0, 40),
        padding: const EdgeInsets.symmetric(horizontal: 18),
        shape: buttonShape,
        textStyle: GoogleFonts.barlow(
          fontSize: 15,
          fontWeight: FontWeight.w600,
        ),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        foregroundColor: ConqueraColors.ink,
        disabledForegroundColor: ConqueraColors.muted,
        side: const BorderSide(color: ConqueraColors.ink),
        minimumSize: const Size(0, 36),
        padding: const EdgeInsets.symmetric(horizontal: 14),
        shape: buttonShape,
        textStyle: GoogleFonts.barlow(
          fontSize: 14,
          fontWeight: FontWeight.w600,
        ),
      ),
    ),
  );
}