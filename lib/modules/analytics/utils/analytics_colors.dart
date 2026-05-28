import 'package:flutter/material.dart';

class AnalyticsColors {
  AnalyticsColors._();

  static const Color bg = Color(0xFF0B1020);
  static const Color bg2 = Color(0xFF10182D);
  static const Color card = Color(0xE6121B32);
  static const Color card2 = Color(0xF2172541);
  static const Color line = Color(0x2E94A3B8);
  static const Color text = Color(0xFFE5E7EB);
  static const Color muted = Color(0xFF9CA3AF);
  static const Color muted2 = Color(0xFF64748B);

  static const Color blue = Color(0xFF38BDF8);
  static const Color blueDeep = Color(0xFF0EA5E9);
  static const Color green = Color(0xFF22C55E);
  static const Color greenDark = Color(0xFF16A34A);
  static const Color yellow = Color(0xFFFACC15);
  static const Color orange = Color(0xFFFB923C);
  static const Color red = Color(0xFFEF4444);
  static const Color purple = Color(0xFFA78BFA);
  static const Color gray = Color(0xFF475569);
  static const Color blackShift = Color(0xFF05070D);

  // Timeline segment colors
  static const Color tlIdle = Color(0xFF475569);
  static const Color tlWork = Color(0xFF0EA5E9);
  static const Color tlSetup = Color(0xFF1E3A8A);
  static const Color tlPause = Color(0xFFD69E00);
  static const Color tlProblem = Color(0xFFDC2626);
  static const Color tlOverlap = Color(0xFFA78BFA);

  static const Gradient accentGradient = LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: [Color(0xFF38BDF8), Color(0xFF22C55E)],
  );

  static const Gradient appBgGradient = LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: [Color(0xFF070B16), Color(0xFF0B1020), Color(0xFF0E1726)],
    stops: [0.0, 0.44, 1.0],
  );
}
