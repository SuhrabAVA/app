import 'package:flutter/material.dart';

import 'analytics_colors.dart';

/// Изолированная светлая тема раздела аналитики.
///
/// Она не меняет глобальный [ThemeData] приложения и не затрагивает экраны
/// склада, заказов, персонала или рабочего пространства.
ThemeData buildAnalyticsTheme(ThemeData base) {
  const colorScheme = ColorScheme.light(
    primary: AnalyticsColors.blue,
    onPrimary: Colors.white,
    secondary: AnalyticsColors.purple,
    onSecondary: Colors.white,
    error: AnalyticsColors.red,
    onError: Colors.white,
    surface: AnalyticsColors.card,
    onSurface: AnalyticsColors.text,
    surfaceVariant: AnalyticsColors.bg2,
    onSurfaceVariant: AnalyticsColors.muted,
    outline: AnalyticsColors.line,
  );

  final textTheme = base.textTheme
      .apply(
        bodyColor: AnalyticsColors.text,
        displayColor: AnalyticsColors.text,
      )
      .copyWith(
        bodyLarge: base.textTheme.bodyLarge?.copyWith(
          color: AnalyticsColors.text,
          fontWeight: FontWeight.w400,
        ),
        bodyMedium: base.textTheme.bodyMedium?.copyWith(
          color: AnalyticsColors.text,
          fontWeight: FontWeight.w400,
        ),
        bodySmall: base.textTheme.bodySmall?.copyWith(
          color: AnalyticsColors.muted,
          fontWeight: FontWeight.w400,
        ),
        titleLarge: base.textTheme.titleLarge?.copyWith(
          color: AnalyticsColors.text,
          fontWeight: FontWeight.w600,
        ),
        titleMedium: base.textTheme.titleMedium?.copyWith(
          color: AnalyticsColors.text,
          fontWeight: FontWeight.w500,
        ),
        titleSmall: base.textTheme.titleSmall?.copyWith(
          color: AnalyticsColors.text,
          fontWeight: FontWeight.w500,
        ),
        labelLarge: base.textTheme.labelLarge?.copyWith(
          fontWeight: FontWeight.w500,
        ),
      );

  OutlineInputBorder inputBorder(Color color, {double width = 1}) =>
      OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: BorderSide(color: color, width: width),
      );

  return base.copyWith(
    brightness: Brightness.light,
    colorScheme: colorScheme,
    scaffoldBackgroundColor: AnalyticsColors.bg,
    canvasColor: AnalyticsColors.card,
    dividerColor: AnalyticsColors.line,
    textTheme: textTheme,
    iconTheme: const IconThemeData(
      color: AnalyticsColors.muted,
      size: 20,
    ),
    inputDecorationTheme: InputDecorationTheme(
      isDense: true,
      filled: true,
      fillColor: AnalyticsColors.bg2,
      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      hintStyle: const TextStyle(
        color: AnalyticsColors.muted2,
        fontWeight: FontWeight.w400,
      ),
      labelStyle: const TextStyle(
        color: AnalyticsColors.muted,
        fontWeight: FontWeight.w400,
      ),
      border: inputBorder(AnalyticsColors.line),
      enabledBorder: inputBorder(AnalyticsColors.line),
      focusedBorder: inputBorder(AnalyticsColors.blue, width: 1.5),
      errorBorder: inputBorder(AnalyticsColors.red),
      focusedErrorBorder: inputBorder(AnalyticsColors.red, width: 1.5),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        foregroundColor: AnalyticsColors.blue,
        textStyle: const TextStyle(fontWeight: FontWeight.w500),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ),
    ),
    elevatedButtonTheme: ElevatedButtonThemeData(
      style: ElevatedButton.styleFrom(
        elevation: 0,
        foregroundColor: Colors.white,
        backgroundColor: AnalyticsColors.blue,
        textStyle: const TextStyle(fontWeight: FontWeight.w500),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        foregroundColor: Colors.white,
        backgroundColor: AnalyticsColors.blue,
        textStyle: const TextStyle(fontWeight: FontWeight.w500),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        foregroundColor: AnalyticsColors.text,
        side: const BorderSide(color: AnalyticsColors.line),
        textStyle: const TextStyle(fontWeight: FontWeight.w500),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ),
    ),
    progressIndicatorTheme: const ProgressIndicatorThemeData(
      color: AnalyticsColors.blue,
    ),
    snackBarTheme: const SnackBarThemeData(
      backgroundColor: AnalyticsColors.text,
      contentTextStyle: TextStyle(color: Colors.white),
      actionTextColor: Color(0xFFB9BAFF),
      behavior: SnackBarBehavior.floating,
    ),
  );
}
