import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

import '../utils/analytics_colors.dart';

/// Отдаёт intrinsic-высоту, измеренную на реальной ширине контента
/// ([measureWidth] = restWidth таблицы), а не на той, что передаёт снаружи
/// IntrinsicHeight (видимая область строки). RenderConstrainedBox (SizedBox)
/// не подставляет свою tight-ширину в intrinsic-запросы — без этой обёртки
/// строки измерялись на ширине экрана: текст «переносился» в измерении и
/// раздувал высоту строки, хотя рисуется он на restWidth в одну-две строки.
/// На layout/paint не влияет (прокси) — меняется только ответ intrinsic.
class IntrinsicHeightAtWidth extends SingleChildRenderObjectWidget {
  const IntrinsicHeightAtWidth({
    super.key,
    required this.measureWidth,
    required super.child,
  });

  final double measureWidth;

  @override
  RenderObject createRenderObject(BuildContext context) =>
      RenderIntrinsicHeightAtWidth(measureWidth);

  @override
  void updateRenderObject(
      BuildContext context, RenderIntrinsicHeightAtWidth renderObject) {
    renderObject.measureWidth = measureWidth;
  }
}

class RenderIntrinsicHeightAtWidth extends RenderProxyBox {
  RenderIntrinsicHeightAtWidth(this._measureWidth);

  double _measureWidth;
  set measureWidth(double value) {
    if (value == _measureWidth) return;
    _measureWidth = value;
    markNeedsLayout();
  }

  @override
  double computeMinIntrinsicHeight(double width) =>
      child?.getMinIntrinsicHeight(_measureWidth) ?? 0.0;

  @override
  double computeMaxIntrinsicHeight(double width) =>
      child?.getMaxIntrinsicHeight(_measureWidth) ?? 0.0;
}

/// Строка таблицы с локальным hover-состоянием. Только эта строка
/// перерисовывается при наведении — синхронный горизонтальный скролл и
/// остальные строки не трогаются (нет лишних rebuild всей таблицы), поэтому
/// производительность скролла не страдает.
class HoverableRow extends StatefulWidget {
  const HoverableRow({super.key, required this.builder});

  final Widget Function(bool hovered) builder;

  @override
  State<HoverableRow> createState() => _HoverableRowState();
}

class _HoverableRowState extends State<HoverableRow> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: RepaintBoundary(child: widget.builder(_hovered)),
    );
  }
}

/// Прокручиваемая область справа от sticky-колонки с фиксированной тенью у
/// левого края — имитирует `box-shadow: 16px 0 26px` sticky-колонки, которую
/// в Flutter иначе перекрыл бы контент строки (порядок отрисовки в Row).
///
/// ВАЖНО: контент — непозиционированный ребёнок Stack. Stack, у которого все
/// дети Positioned, отдаёт нулевую intrinsic-высоту, из-за чего IntrinsicHeight
/// в строках таблиц мерил высоту только по sticky-ячейке и сплющивал контент
/// (RenderFlex overflow). Кроме того, Positioned.fill навязывал контенту tight-
/// ширину видимой области, схлопывая SizedBox(width: restWidth).
/// StackFit.passthrough пробрасывает constraints ячейки как есть, чтобы фон и
/// нижняя граница строки растягивались на всю её высоту.
class StickyScrollArea extends StatelessWidget {
  const StickyScrollArea({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Stack(
      fit: StackFit.passthrough,
      children: [
        child,
        const Positioned(
          left: 0,
          top: 0,
          bottom: 0,
          child: IgnorePointer(
            child: SizedBox(
              width: 18,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.centerLeft,
                    end: Alignment.centerRight,
                    colors: [
                      AnalyticsColors.stickyShadow,
                      Color(0x00020617),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}
