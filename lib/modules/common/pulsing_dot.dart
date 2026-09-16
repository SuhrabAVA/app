import 'package:flutter/material.dart';

/// Пульсирующая точка — метка «сюда стоит посмотреть».
///
/// Пульсация, а не просто цветная точка: на карточке заказа этапов до восьми,
/// у каждого свой цвет статуса, и неподвижная точка среди них теряется. Здесь
/// движение означает ровно одно — с количеством на этом этапе что-то не так.
///
/// Анимация одна на виджет и останавливается вместе с ним: список заказов
/// перестраивается от realtime по несколько раз в минуту, и оставленные
/// контроллеры съедали бы кадры на планшете.
class PulsingDot extends StatefulWidget {
  const PulsingDot({
    super.key,
    required this.color,
    this.size = 8,
    this.tooltip,
  });

  final Color color;

  /// Диаметр самой точки. Ореол вокруг рисуется поверх, места не занимает.
  final double size;

  final String? tooltip;

  @override
  State<PulsingDot> createState() => _PulsingDotState();
}

class _PulsingDotState extends State<PulsingDot>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1400),
  )..repeat();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final dot = AnimatedBuilder(
      animation: _controller,
      builder: (context, _) {
        final t = _controller.value;
        // Ореол расходится и гаснет — как круг на воде. Точка остаётся
        // непрозрачной: мигающий индикатор читается хуже, чем ровный.
        final halo = widget.size * (1 + t * 1.6);
        return SizedBox(
          width: widget.size * 2.6,
          height: widget.size * 2.6,
          child: Stack(
            alignment: Alignment.center,
            children: [
              Container(
                width: halo,
                height: halo,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: widget.color.withValues(alpha: 0.35 * (1 - t)),
                ),
              ),
              Container(
                width: widget.size,
                height: widget.size,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: widget.color,
                ),
              ),
            ],
          ),
        );
      },
    );

    final tooltip = widget.tooltip;
    if (tooltip == null || tooltip.isEmpty) return dot;
    return Tooltip(message: tooltip, child: dot);
  }
}
