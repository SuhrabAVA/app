import 'package:flutter/material.dart';

/// Оформление формы заказа.
///
/// Токены и примитивы вынесены отдельно: экран заказа собирается из общих
/// строителей (`_buildOrderSectionCard`, `_buildLabelRow`, поля ввода), и
/// менять вид по месту пришлось бы в сотне точек. Здесь — один источник.
abstract final class OrderFormColors {
  static const background = Color(0xFFF0F0F6);
  static const surface = Colors.white;
  static const border = Color(0xFFE2E4EA);
  static const divider = Color(0xFFF3F4F6);

  /// Заливка полей ввода в покое; в фокусе поле становится белым.
  static const fieldFill = Color(0xFFF7F8FB);

  static const accent = Color(0xFF7C3AED);
  static const accentSoft = Color(0xFFEDE9FE);
  static const accentBorder = Color(0xFFC4B5FD);

  static const text = Color(0xFF111827);
  static const label = Color(0xFF9CA3AF);
  static const muted = Color(0xFF6B7280);
  static const placeholder = Color(0xFFD1D5DB);

  // Цвета шапок карточек — по макету.
  static const greenText = Color(0xFF16A34A);
  static const greenBg = Color(0xFFDCFCE7);
  static const orangeText = Color(0xFFEA580C);
  static const orangeBg = Color(0xFFFFEDD5);
  static const violetText = Color(0xFF7C3AED);
  static const violetBg = Color(0xFFEDE9FE);
  static const blueText = Color(0xFF2563EB);
  static const blueBg = Color(0xFFDBEAFE);
}

abstract final class OrderFormMetrics {
  static const cardRadius = 16.0;
  static const fieldRadius = 6.0;
  static const fieldHeight = 30.0;
  static const labelWidth = 108.0;
  static const gap = 12.0;
}

/// Шапка карточки: цветной значок в квадрате + подпись капсом.
class OrderSectionHead extends StatelessWidget {
  const OrderSectionHead({
    super.key,
    required this.icon,
    required this.label,
    required this.color,
    required this.background,
  });

  final IconData icon;
  final String label;
  final Color color;
  final Color background;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Container(
                width: 24,
                height: 24,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: background,
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Icon(icon, size: 13, color: color),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  label.toUpperCase(),
                  style: TextStyle(
                    fontSize: 10.5,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 1.2,
                    color: color,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          const Divider(height: 1, color: OrderFormColors.divider),
        ],
      ),
    );
  }
}

/// Оформление поля ввода: невысокое, с заливкой, в фокусе — фиолетовая рамка.
InputDecoration orderFieldDecoration({
  String? hintText,
  String? labelText,
  Widget? prefixIcon,
  Widget? suffixIcon,
  String? suffixText,
  bool dense = true,
}) {
  OutlineInputBorder border(Color color, [double width = 1]) =>
      OutlineInputBorder(
        borderRadius: BorderRadius.circular(OrderFormMetrics.fieldRadius),
        borderSide: BorderSide(color: color, width: width),
      );

  return InputDecoration(
    hintText: hintText,
    labelText: labelText,
    prefixIcon: prefixIcon,
    suffixIcon: suffixIcon,
    suffixText: suffixText,
    isDense: dense,
    filled: true,
    fillColor: OrderFormColors.fieldFill,
    hintStyle: const TextStyle(
      fontSize: 12,
      color: OrderFormColors.placeholder,
    ),
    labelStyle: const TextStyle(fontSize: 12, color: OrderFormColors.label),
    contentPadding:
        const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
    border: border(OrderFormColors.border),
    enabledBorder: border(OrderFormColors.border),
    focusedBorder: border(OrderFormColors.accent, 1.4),
    disabledBorder: border(OrderFormColors.border),
  );
}

/// Переключатель 32×16 — по макету он заметно компактнее материалового.
class OrderToggle extends StatelessWidget {
  const OrderToggle({super.key, required this.value, this.onChanged});

  final bool value;
  final ValueChanged<bool>? onChanged;

  @override
  Widget build(BuildContext context) {
    final enabled = onChanged != null;
    return Opacity(
      opacity: enabled ? 1 : 0.5,
      child: GestureDetector(
        onTap: enabled ? () => onChanged!(!value) : null,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 160),
          width: 32,
          height: 16,
          decoration: BoxDecoration(
            color: value ? OrderFormColors.accent : const Color(0xFFD1D5DB),
            borderRadius: BorderRadius.circular(8),
          ),
          child: AnimatedAlign(
            duration: const Duration(milliseconds: 160),
            curve: Curves.easeOut,
            alignment: value ? Alignment.centerRight : Alignment.centerLeft,
            child: Container(
              margin: const EdgeInsets.symmetric(horizontal: 2),
              width: 12,
              height: 12,
              decoration: const BoxDecoration(
                color: Colors.white,
                shape: BoxShape.circle,
                boxShadow: [
                  BoxShadow(
                    color: Color(0x33000000),
                    blurRadius: 2,
                    offset: Offset(0, 1),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
