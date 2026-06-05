import 'package:flutter/material.dart';

import '../utils/analytics_colors.dart';

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
class StickyScrollArea extends StatelessWidget {
  const StickyScrollArea({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        Positioned.fill(child: child),
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
