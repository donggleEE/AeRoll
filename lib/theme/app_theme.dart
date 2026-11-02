import 'package:flutter/material.dart';

abstract final class AppTheme {
  static const paper = Color(0xFFF5F0E6);
  static const ink = Color(0xFF252B29);
  static const muted = Color(0xFF68716B);
  static const accent = Color(0xFFBD4C32);
  static const line = Color(0xFFDCD8CB);

  static ThemeData get light => ThemeData(
    useMaterial3: true,
    scaffoldBackgroundColor: paper,
    colorScheme: ColorScheme.fromSeed(
      seedColor: accent,
      primary: accent,
      surface: paper,
      onSurface: ink,
    ),
    appBarTheme: const AppBarTheme(
      backgroundColor: paper,
      foregroundColor: ink,
      elevation: 0,
      centerTitle: false,
    ),
    dividerColor: line,
    snackBarTheme: const SnackBarThemeData(
      backgroundColor: ink,
      contentTextStyle: TextStyle(color: paper),
      behavior: SnackBarBehavior.floating,
    ),
    sliderTheme: const SliderThemeData(
      activeTrackColor: accent,
      thumbColor: accent,
    ),
  );
}
