import 'package:flutter/material.dart';

import '../theme/conquera_theme.dart';

/// The app's single-line text input: centered text, pale fill, thin outline
/// that darkens when focused.
class ConqueraTextField extends StatelessWidget {
  final TextEditingController controller;
  final String hint;
  final bool enabled;
  final bool autofocus;
  final int? maxLength;
  final TextInputAction? textInputAction;
  final ValueChanged<String>? onChanged;
  final ValueChanged<String>? onSubmitted;

  const ConqueraTextField({
    super.key,
    required this.controller,
    required this.hint,
    this.enabled = true,
    this.autofocus = false,
    this.maxLength,
    this.textInputAction,
    this.onChanged,
    this.onSubmitted,
  });

  OutlineInputBorder _border(Color color, double width) => OutlineInputBorder(
        borderRadius: BorderRadius.circular(6),
        borderSide: BorderSide(color: color, width: width),
      );

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: controller,
      enabled: enabled,
      autofocus: autofocus,
      maxLength: maxLength,
      textAlign: TextAlign.center,
      textInputAction: textInputAction,
      onChanged: onChanged,
      onSubmitted: onSubmitted,
      cursorColor: ConqueraColors.ink,
      style: ConqueraText.value.copyWith(fontSize: 16),
      decoration: InputDecoration(
        hintText: hint,
        hintStyle: ConqueraText.value.copyWith(
          fontSize: 16,
          color: ConqueraColors.muted,
        ),
        counterText: '',
        filled: true,
        fillColor: ConqueraColors.surface,
        contentPadding: const EdgeInsets.symmetric(
          horizontal: ConqueraSpace.md,
          vertical: 14,
        ),
        enabledBorder: _border(ConqueraColors.divider, 1),
        disabledBorder: _border(ConqueraColors.divider, 1),
        focusedBorder: _border(ConqueraColors.ink, 1.5),
      ),
    );
  }
}