import 'package:flutter/material.dart';

import 'order_form_design.dart';

/// Paint only the outline on animation ticks; the order's contents stay cached.
class OrderEditingFrame extends StatefulWidget {
  const OrderEditingFrame(
      {super.key, required this.editorName, required this.child});
  final String? editorName;
  final Widget child;

  @override
  State<OrderEditingFrame> createState() => _OrderEditingFrameState();
}

class _OrderEditingFrameState extends State<OrderEditingFrame>
    with SingleTickerProviderStateMixin {
  late final AnimationController _pulse = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1100),
  );

  void _syncAnimation() {
    if (widget.editorName != null && !MediaQuery.disableAnimationsOf(context)) {
      if (!_pulse.isAnimating) _pulse.repeat(reverse: true);
    } else {
      _pulse.stop();
      _pulse.value = 1;
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _syncAnimation();
  }

  @override
  void didUpdateWidget(covariant OrderEditingFrame oldWidget) {
    super.didUpdateWidget(oldWidget);
    _syncAnimation();
  }

  @override
  void dispose() {
    _pulse.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (widget.editorName == null) return widget.child;
    final label = 'Редактирует: ${widget.editorName}. Дождитесь сохранения.';
    return Semantics(
      label: label,
      child: Tooltip(
          message: label,
          child: Stack(children: [
            widget.child,
            Positioned.fill(
                child: IgnorePointer(
                    child: CustomPaint(
              painter: _EditingOutline(_pulse),
            ))),
          ])),
    );
  }
}

class _EditingOutline extends CustomPainter {
  _EditingOutline(this.pulse) : super(repaint: pulse);
  final Animation<double> pulse;

  @override
  void paint(Canvas canvas, Size size) {
    final path = RRect.fromRectAndRadius(
      (Offset.zero & size).deflate(1.5),
      const Radius.circular(OrderFormMetrics.cardRadius),
    );
    canvas.drawRRect(
        path,
        Paint()
          ..color =
              OrderFormColors.blueText.withValues(alpha: .4 + .6 * pulse.value)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2 + pulse.value);
  }

  @override
  bool shouldRepaint(covariant _EditingOutline oldDelegate) =>
      oldDelegate.pulse != pulse;
}
