import 'dart:io' show Platform;
import 'dart:math' as math;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';

import '../services/connectivity_service.dart';

/// Мигающий значок «нет интернета» поверх всего приложения.
///
/// Подключается в `MaterialApp.builder` ВЫШЕ [AppLayoutScale]: значок задан в
/// реальных логических пикселях экрана, а не в design-space эталонного ПК, —
/// иначе на планшете его ещё раз сжало бы общим масштабом макета.
///
/// Размер: 230×230 на компьютере (как заказано), на телефоне и планшете —
/// пропорционально меньше, см. [badgeSizeFor].
class OfflineOverlayHost extends StatefulWidget {
  const OfflineOverlayHost({super.key, required this.child});

  final Widget child;

  /// Размер значка на компьютере, логические пиксели.
  static const double desktopSize = 230;

  /// Доля короткой стороны экрана, которую значок занимает на мобильном.
  static const double mobileShortestSideFraction = 0.32;

  /// Ниже этого значок перестаёт читаться.
  static const double minSize = 88;

  /// Размер значка для экрана [screen].
  ///
  /// На компьютере — ровно [desktopSize], но не больше половины короткой
  /// стороны: в узком окне значок в 230 пикселей закрыл бы пол-экрана.
  /// На Android/iOS считаем от короткой стороны, поэтому телефон получает
  /// примерно 120, планшет — около 155, и во всех случаях не больше 230.
  static double badgeSizeFor(Size screen, {required bool isDesktop}) {
    final double shortest = math.min(screen.width, screen.height);
    if (shortest <= 0) return minSize;
    final double raw = isDesktop
        ? math.min(desktopSize, shortest * 0.5)
        : shortest * mobileShortestSideFraction;
    return raw.clamp(math.min(minSize, shortest * 0.5), desktopSize).toDouble();
  }

  static bool get _isDesktopPlatform {
    if (kIsWeb) return true;
    return Platform.isWindows || Platform.isLinux || Platform.isMacOS;
  }

  @override
  State<OfflineOverlayHost> createState() => _OfflineOverlayHostState();
}

class _OfflineOverlayHostState extends State<OfflineOverlayHost> {
  final ConnectivityService _service = ConnectivityService.instance;

  @override
  void initState() {
    super.initState();
    _service.addListener(_onChanged);
  }

  @override
  void dispose() {
    _service.removeListener(_onChanged);
    super.dispose();
  }

  void _onChanged() {
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    if (_service.isOnline) {
      // Пока связь есть, оверлея нет вовсе: ни Stack, ни анимации, ни
      // лишнего кадра.
      return widget.child;
    }

    final MediaQueryData mq = MediaQuery.of(context);
    final double size = OfflineOverlayHost.badgeSizeFor(
      mq.size,
      isDesktop: OfflineOverlayHost._isDesktopPlatform,
    );

    return Stack(
      textDirection: TextDirection.ltr,
      children: [
        widget.child,
        Positioned(
          top: mq.padding.top + 12,
          left: 0,
          right: 0,
          // Значок ничего не перехватывает: под ним продолжает работать
          // обычный экран.
          child: IgnorePointer(
            child: Center(
              child: _BlinkingNoInternetBadge(size: size),
            ),
          ),
        ),
      ],
    );
  }
}

class _BlinkingNoInternetBadge extends StatefulWidget {
  const _BlinkingNoInternetBadge({required this.size});

  final double size;

  @override
  State<_BlinkingNoInternetBadge> createState() =>
      _BlinkingNoInternetBadgeState();
}

class _BlinkingNoInternetBadgeState extends State<_BlinkingNoInternetBadge>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 700),
  )..repeat(reverse: true);

  late final Animation<double> _opacity = Tween<double>(
    begin: 1.0,
    // Не до нуля: значок должен именно мигать, а не исчезать — исчезающий
    // читается как «показалось».
    end: 0.15,
  ).animate(CurvedAnimation(parent: _controller, curve: Curves.easeInOut));

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FadeTransition(
      opacity: _opacity,
      child: SizedBox(
        width: widget.size,
        height: widget.size,
        child: DecoratedBox(
          decoration: const BoxDecoration(
            shape: BoxShape.circle,
            boxShadow: [
              BoxShadow(
                color: Color(0x40000000),
                blurRadius: 18,
                offset: Offset(0, 6),
              ),
            ],
          ),
          child: CustomPaint(
            painter: _NoInternetPainter(),
            isComplex: true,
          ),
        ),
      ),
    );
  }
}

/// Значок «перечёркнутый Wi-Fi»: оранжевый круг, белое поле, синие дуги и
/// оранжевая перечёркивающая полоса.
class _NoInternetPainter extends CustomPainter {
  static const Color _orangeDark = Color(0xFFE0552A);
  static const Color _orangeLight = Color(0xFFFA6B39);
  static const Color _white = Color(0xFFFFFFFF);
  static const Color _blueLight = Color(0xFF33B5F2);
  static const Color _blueDark = Color(0xFF0C8FD6);

  @override
  void paint(Canvas canvas, Size size) {
    final double r = math.min(size.width, size.height) / 2;
    final Offset c = Offset(size.width / 2, size.height / 2);

    // Круг с лёгким объёмом: тёмная база и сдвинутый вверх-влево светлый
    // круг оставляют затенённый серп справа снизу.
    canvas.drawCircle(c, r, Paint()..color = _orangeDark);
    canvas.drawCircle(
      c.translate(-r * 0.045, -r * 0.045),
      r * 0.955,
      Paint()..color = _orangeLight,
    );

    // Белое поле под антенну.
    canvas.drawCircle(c, r * 0.76, Paint()..color = _white);

    // Дуги Wi-Fi расходятся вверх от точки внизу. Центр веера сдвинут вниз от
    // центра значка, чтобы вся антенна встала посередине белого поля.
    final Offset origin = Offset(c.dx, c.dy + r * 0.40);
    // Сектор ±38° от вертикали: шире выглядит уже не антенной, а зонтом.
    const double sweep = math.pi * 76 / 180;
    const double startAngle = -math.pi / 2 - sweep / 2;
    // Правая треть каждой дуги темнее — так затенён исходный значок.
    const double darkSweep = sweep * 0.35;
    const double darkStart = startAngle + sweep - darkSweep;

    void arc(double radius, double stroke) {
      final rect = Rect.fromCircle(center: origin, radius: radius);
      final base = Paint()
        ..style = PaintingStyle.stroke
        ..strokeCap = StrokeCap.round
        ..strokeWidth = stroke;
      canvas.drawArc(rect, startAngle, sweep, false, base..color = _blueLight);
      canvas.drawArc(
          rect, darkStart, darkSweep, false, base..color = _blueDark);
    }

    arc(r * 0.74, r * 0.155);
    arc(r * 0.52, r * 0.150);
    arc(r * 0.30, r * 0.145);

    // Точка антенны — тоже двухцветная.
    const double dotRadius = 0.115;
    canvas.drawCircle(origin, r * dotRadius, Paint()..color = _blueLight);
    canvas.save();
    canvas.clipRect(Rect.fromLTWH(
      origin.dx,
      origin.dy - r * dotRadius,
      r * dotRadius,
      r * dotRadius * 2,
    ));
    canvas.drawCircle(origin, r * dotRadius, Paint()..color = _blueDark);
    canvas.restore();

    // Перечёркивающая полоса из левого верхнего угла в правый нижний:
    // сначала белая подложка, поверх — оранжевая линия.
    const Offset dir = Offset(math.sqrt1_2, math.sqrt1_2);
    final Offset p1 = c - dir * (r * 0.80);
    final Offset p2 = c + dir * (r * 0.80);
    canvas.drawLine(
      p1,
      p2,
      Paint()
        ..strokeCap = StrokeCap.round
        ..strokeWidth = r * 0.32
        ..color = _white,
    );
    canvas.drawLine(
      p1,
      p2,
      Paint()
        ..strokeCap = StrokeCap.round
        ..strokeWidth = r * 0.22
        ..color = _orangeLight,
    );
  }

  @override
  bool shouldRepaint(covariant _NoInternetPainter oldDelegate) => false;
}
