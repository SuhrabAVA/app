/// Живой обратный отсчёт до срока заказа — виджет для списков.
///
/// ОДНИ ЧАСЫ НА ВЕСЬ ЭКРАН
/// Карточки заказов строятся все разом (`Wrap` внутри прокрутки), и на восьми
/// десятках заказов персональный `Timer` в каждой строке означал бы восемьдесят
/// таймеров и восемьдесят независимых перерисовок. Поэтому такт один общий —
/// [_CountdownClock], — а виджеты только слушают его. Часы заводятся с первым
/// видимым отсчётом и глохнут, когда исчезает последний: на экранах без
/// таймеров ничего не тикает.
///
/// ТАКТ 60 мс, А НЕ КАДР
/// Свечению хватает шестнадцати обновлений в секунду, а полный кадровый такт
/// на восьмидесяти строках — это восемьдесят пересборок каждые 16 мс на
/// цеховом планшете. Цифры всё равно меняются раз в секунду.
library;

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'order_deadline_countdown.dart';
import 'order_form_design.dart';
import 'order_model.dart';

class _CountdownClock extends ChangeNotifier {
  _CountdownClock._();

  static final _CountdownClock instance = _CountdownClock._();

  static const Duration _tick = Duration(milliseconds: 60);

  /// Период «вдоха» свечения. Медленнее секунды намеренно: пульс в такт
  /// цифрам читался бы как мигание, а не как ровное горение.
  static const double _pulsePeriodMs = 2200;

  Timer? _timer;
  int _subscribers = 0;
  DateTime _now = DateTime.now().toUtc();
  double _pulse = 1;
  final Stopwatch _phase = Stopwatch();

  DateTime get now => _now;

  /// 0 — тускло, 1 — ярко.
  double get pulse => _pulse;

  void subscribe() {
    _subscribers++;
    if (_timer != null) return;
    _phase.start();
    _timer = Timer.periodic(_tick, (_) {
      _now = DateTime.now().toUtc();
      final phase = (_phase.elapsedMilliseconds % _pulsePeriodMs) / _pulsePeriodMs;
      _pulse = 0.5 - 0.5 * math.cos(phase * 2 * math.pi);
      notifyListeners();
    });
  }

  void unsubscribe() {
    _subscribers--;
    if (_subscribers > 0) return;
    _subscribers = 0;
    _timer?.cancel();
    _timer = null;
    _phase
      ..stop()
      ..reset();
  }
}

/// Обратный отсчёт заказа: дни, часы, минуты и секунды.
///
/// Цвет ведёт [countdownColor] — от зелёного к красному по мере расхода срока;
/// свечение дышит, пока часы идут. У завершённого заказа часы стоят, поэтому
/// и свечение выключено: статичная отметка не должна привлекать внимание
/// наравне с горящим сроком.
class OrderDeadlineTimer extends StatefulWidget {
  const OrderDeadlineTimer({
    super.key,
    required this.order,
    this.fontSize = 11,
  });

  final OrderModel order;
  final double fontSize;

  @override
  State<OrderDeadlineTimer> createState() => _OrderDeadlineTimerState();
}

class _OrderDeadlineTimerState extends State<OrderDeadlineTimer> {
  final _CountdownClock _clock = _CountdownClock.instance;

  @override
  void initState() {
    super.initState();
    _clock.subscribe();
  }

  @override
  void dispose() {
    _clock.unsubscribe();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _clock,
      builder: (context, _) {
        final countdown = countdownForOrder(widget.order, now: _clock.now);
        if (countdown == null) {
          return Text(
            '—',
            style: TextStyle(
              fontSize: widget.fontSize,
              color: OrderFormColors.placeholder,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          );
        }

        final base = countdownColor(countdown.fractionLeft);
        final glow = countdown.running ? _clock.pulse : 0.0;
        final manual = hasManualDeadline(widget.order);
        final deadline = effectiveDeadlineDate(widget.order);
        if (deadline == null) {
          return Text('—',
              style: TextStyle(
                fontSize: widget.fontSize,
                color: OrderFormColors.placeholder,
              ));
        }
        final text = formatDeadlineDate(deadline, manual: manual);

        // Цвет ведёт ДОЛЯ оставшегося срока, а не сама дата: у заказа на сутки
        // и на месяц «мало времени» наступает в разные моменты. Поэтому дата
        // статична, а её цвет продолжает переливаться, как переливался отсчёт.
        if (!manual) {
          // Обычный срок: цветные цифры на белом.
          return Text(
            text,
            maxLines: 1,
            overflow: TextOverflow.clip,
            style: TextStyle(
              fontSize: widget.fontSize,
              fontWeight: FontWeight.w700,
              letterSpacing: 0.2,
              color: countdown.running
                  ? Color.lerp(base, _brighten(base), 0.35 * glow)!
                  : base.withValues(alpha: 0.55),
              fontFeatures: const [FontFeature.tabularFigures()],
              shadows: glow <= 0.02
                  ? null
                  : [
                      Shadow(
                        color: base.withValues(alpha: 0.22 + 0.38 * glow),
                        blurRadius: 4 + 8 * glow,
                      ),
                    ],
            ),
          );
        }

        // Назначенный вручную: белые цифры в цветной плашке. Разница читается
        // мгновенно и не требует подписи — видно, что срок назначил цех, а не
        // менеджер при оформлении.
        final fill = countdown.running
            ? Color.lerp(base, _brighten(base), 0.30 * glow)!
            : base.withValues(alpha: 0.55);
        return Container(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
          decoration: BoxDecoration(
            color: fill,
            borderRadius: BorderRadius.circular(6),
            boxShadow: glow <= 0.02
                ? null
                : [
                    BoxShadow(
                      color: base.withValues(alpha: 0.18 + 0.30 * glow),
                      blurRadius: 4 + 8 * glow,
                    ),
                  ],
          ),
          child: Text(
            text,
            maxLines: 1,
            overflow: TextOverflow.clip,
            style: TextStyle(
              fontSize: widget.fontSize,
              fontWeight: FontWeight.w700,
              letterSpacing: 0.2,
              color: Colors.white,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
        );
      },
    );
  }

  /// Тот же цвет, но светлее — вершина «вдоха».
  ///
  /// Именно светлее, а не белее: подмешивание белого на светлом фоне списка
  /// съедает контраст, и на пике текст становился бы хуже читаемым.
  static Color _brighten(Color color) {
    final hsl = HSLColor.fromColor(color);
    return hsl
        .withLightness((hsl.lightness + 0.14).clamp(0.0, 1.0))
        .withSaturation((hsl.saturation + 0.08).clamp(0.0, 1.0))
        .toColor();
  }
}
