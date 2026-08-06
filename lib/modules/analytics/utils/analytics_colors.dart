import 'package:flutter/material.dart';

class AnalyticsColors {
  AnalyticsColors._();

  static const Color bg = Color(0xFFF2F2F7);
  static const Color bg2 = Color(0xFFF7F7FA);
  static const Color card = Color(0xFFFFFFFF);
  static const Color card2 = Color(0xFFF7F7FA);
  static const Color line = Color(0x1A000000);
  static const Color text = Color(0xFF111118);
  static const Color muted = Color(0xFF717182);
  static const Color muted2 = Color(0xFF90909D);

  static const Color blue = Color(0xFF6A6CF7);
  static const Color blueDeep = Color(0xFF5856D6);
  static const Color green = Color(0xFF34C759);
  static const Color greenDark = Color(0xFF248A3D);
  static const Color yellow = Color(0xFFFFCC00);
  static const Color orange = Color(0xFFFF9500);
  static const Color red = Color(0xFFFF3B30);
  static const Color purple = Color(0xFFAF52DE);
  static const Color gray = Color(0xFF8E8E93);
  static const Color blackShift = Color(0xFF1C1C1E);

  // Timeline segment colors
  static const Color tlIdle = Color(0xFF8E8E93);
  static const Color tlWork = Color(0xFF007AFF);
  static const Color tlSetup = Color(0xFF5856D6);
  static const Color tlPause = Color(0xFFFF9500);
  static const Color tlProblem = Color(0xFFFF3B30);
  static const Color tlOverlap = Color(0xFFAF52DE);

  static const Gradient accentGradient = LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: [Color(0xFF6A6CF7), Color(0xFF5856D6)],
  );

  /// Аватар сотрудника в таблице в палитре раздела аналитики.
  static const Gradient avatarGradient = LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: [Color(0xFF6A6CF7), Color(0xFFAF52DE)],
  );

  static const Gradient appBgGradient = LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: [Color(0xFFF2F2F7), Color(0xFFF2F2F7), Color(0xFFF7F7FA)],
    stops: [0.0, 0.44, 1.0],
  );

  // ── Таблицы аналитики (1:1 из styles.css эталона) ──────────────────────────
  /// Светлый заголовок таблицы.
  static const Gradient tableHeaderGradient = LinearGradient(
    begin: Alignment.topCenter,
    end: Alignment.bottomCenter,
    colors: [Color(0xFFF7F7FA), Color(0xFFF2F2F7)],
  );

  /// Закреплённая ячейка заголовка.
  static const Gradient tableStickyHeaderGradient = LinearGradient(
    begin: Alignment.topCenter,
    end: Alignment.bottomCenter,
    colors: [Color(0xFFF7F7FA), Color(0xFFF2F2F7)],
  );

  /// Закреплённая колонка строки.
  static const Gradient tableStickyColumnGradient = LinearGradient(
    begin: Alignment.topCenter,
    end: Alignment.bottomCenter,
    colors: [Color(0xFFFFFFFF), Color(0xFFFAFAFC)],
  );

  /// Закреплённая колонка при наведении.
  static const Gradient tableStickyHoverGradient = LinearGradient(
    begin: Alignment.topCenter,
    end: Alignment.bottomCenter,
    colors: [Color(0xFFF0EEFF), Color(0xFFF5F3FF)],
  );

  /// Закреплённая колонка футера.
  static const Gradient tableFooterStickyGradient = LinearGradient(
    begin: Alignment.topCenter,
    end: Alignment.bottomCenter,
    colors: [Color(0xFFF7F7FA), Color(0xFFF2F2F7)],
  );

  static const Color tableHeaderText = Color(0xFF717182);
  static const Color zebraOdd = Color(0xFFFFFFFF);
  static const Color zebraEven = Color(0xFFFAFAFC);
  static const Color rowHover = Color(0xFFF0EEFF);
  static const Color footerBg = Color(0xFFF7F7FA);
  static const Color stickyShadow = Color(0x14000000);
}
