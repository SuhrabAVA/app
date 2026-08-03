import 'package:flutter/material.dart';

/// Глобальное масштабирование макета под эталонную ширину ПК.
///
/// Идея: все экраны верстаются один раз под десктопное разрешение
/// ([designWidth] логических пикселей по ширине ≈ 1920×1080 при масштабе
/// Windows 125%). На более узких экранах (планшет, уменьшенное окно) весь
/// макет отрисовывается в эталонной ширине и равномерно сжимается целиком,
/// поэтому взаимное расположение и соотношение размеров карточек, иконок,
/// текста и отступов остаются визуально идентичными ПК-версии — просто в
/// меньшем масштабе.
///
/// Подключается один раз в `MaterialApp.builder` (см. my_app.dart) и потому
/// действует на все маршруты/экраны приложения, включая диалоги, меню и
/// оверлеи навигатора.
///
/// Когда масштабирование НЕ применяется (виджет прозрачен):
///  * телефоны — `shortestSide < [minShortestSide]` (их текущая вёрстка
///    остаётся как была);
///  * экраны шире эталона — масштаб ограничен 1.0, т.е. широкий десктоп
///    ведёт себя как раньше (больше места, без зума).
class AppLayoutScale extends StatelessWidget {
  const AppLayoutScale({super.key, required this.child});

  /// Эталонная логическая ширина макета: 1920 физических пикселей при
  /// масштабе Windows 125%. Если эталонный ПК работает при другом масштабе,
  /// достаточно поправить эту константу.
  static const double designWidth = 1536;

  /// Порог «это уже не телефон»: масштабируем планшеты и десктоп.
  ///
  /// Считается по логическим пикселям, а не по физическим. Рабочий планшет
  /// (800×1280 физических, density 240 → dpr 1.5) даёт всего 853×485
  /// логических: по этой метрике он МЕНЬШЕ порога 600, который принят в
  /// Android/Flutter за границу «планшет» (sw600dp), и с ним масштабирование
  /// не включалось вовсе. Телефоны при этом лежат в диапазоне 360–430
  /// логических по короткой стороне, поэтому 450 разделяет их с планшетом
  /// надёжно.
  static const double minShortestSide = 450;

  /// Во сколько раз укрупнить надписи внутри масштабированного макета.
  ///
  /// Сам макет сжимается под экран целиком (на планшете ×0.556), из-за чего
  /// шрифты становятся мельче, чем на ПК. Этот множитель возвращает тексту
  /// читаемость, не трогая сетку: 0.556 × 1.25 ≈ 0.70 от размера шрифта на
  /// эталонном ПК. Геометрия карточек и отступов остаётся прежней, поэтому
  /// чем больше множитель, тем чаще текст переносится или обрезается в
  /// плотных местах: на 1.5 резались подсказка поиска и ФИО на экране входа.
  static const double textScaleBoost = 1.25;

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final Size size = constraints.biggest;
        if (!size.isFinite ||
            size.shortestSide < minShortestSide ||
            size.width >= designWidth) {
          return child;
        }

        // Без нижнего ограничителя: любой кламп означал бы, что макет шире
        // экрана и правая часть обрезается (на планшете 853 логических
        // масштаб равен 0.56).
        final double scale = size.width / designWidth;
        final Size designSize = Size(size.width / scale, size.height / scale);
        final MediaQueryData mq = MediaQuery.of(context);

        return MediaQuery(
          // Экраны должны верстаться так, будто открыты на эталонном ПК:
          // подменяем размеры и системные отступы на design-space значения.
          data: mq.copyWith(
            size: designSize,
            devicePixelRatio: mq.devicePixelRatio * scale,
            // Системное увеличение текста (Android textScale) не применяем —
            // иначе пропорции разъезжаются с ПК; вместо него задаём наш
            // фиксированный множитель читаемости.
            textScaler: const TextScaler.linear(textScaleBoost),
            padding: _unscaleInsets(mq.padding, scale),
            viewPadding: _unscaleInsets(mq.viewPadding, scale),
            viewInsets: _unscaleInsets(mq.viewInsets, scale),
            systemGestureInsets: _unscaleInsets(mq.systemGestureInsets, scale),
          ),
          child: FittedBox(
            fit: BoxFit.fill,
            alignment: Alignment.topLeft,
            child: SizedBox(
              width: designSize.width,
              height: designSize.height,
              child: child,
            ),
          ),
        );
      },
    );
  }

  /// Переводит системные отступы из физического пространства экрана в
  /// design-space (после сжатия FittedBox'ом они снова совпадут с экранными).
  static EdgeInsets _unscaleInsets(EdgeInsets insets, double scale) {
    return EdgeInsets.fromLTRB(
      insets.left / scale,
      insets.top / scale,
      insets.right / scale,
      insets.bottom / scale,
    );
  }
}
