import 'package:flutter/material.dart';

/// Оформление конфигуратора типов продукта.
///
/// Токены собраны в одном месте, потому что редактор состоит из трёх вкладок
/// в разных файлах: без общего словаря они разъезжались по оттенкам и
/// скруглениям при первой же правке.
abstract final class PtColors {
  static const background = Color(0xFFF4F4F6);
  static const surface = Colors.white;
  static const border = Color(0xFFE5E7EB);
  static const borderSoft = Color(0xFFF3F4F6);

  static const primary = Color(0xFF6366F1);
  static const primarySoft = Color(0xFFEDE9FE);
  static const primaryBorder = Color(0xFFA5B4FC);
  static const primaryText = Color(0xFF4338CA);
  static const primaryMuted = Color(0xFF818CF8);
  static const violetText = Color(0xFF5B21B6);

  static const text = Color(0xFF111827);
  static const textSoft = Color(0xFF374151);
  static const muted = Color(0xFF9CA3AF);
  static const mutedStrong = Color(0xFF6B7280);

  static const cardActive = Color(0xFFF0F0FF);
  static const cardIdle = Color(0xFFFAFAFA);

  /// Несколько рабочих мест на этапе — предупреждающий, но не тревожный тон.
  static const warnBackground = Color(0xFFFEF3C7);
  static const warnBorder = Color(0xFFFCD34D);
  static const warnText = Color(0xFF92400E);

  static const danger = Color(0xFFEF4444);
}

abstract final class PtMetrics {
  static const cardRadius = 12.0;
  static const pillRadius = 999.0;
  static const gap = 10.0;
  static const pagePadding = 20.0;
}

/// Что именно включает блок в форме заказа.
///
/// В таблице `order_form_blocks` есть только код и название, а по названию
/// понять нечего: «Кол-во по БЛ» в форме подписано просто «Количество», а
/// «Рулон» — это поле в размерах продукта. Подсказки живут в коде, потому
/// что описывают конкретные поля конкретной формы: уедет форма — уедут и они,
/// и это должно быть видно в том же коммите.
String orderFormBlockHint(String code, bool affectsStageQueue) {
  switch (code) {
    case 'material':
      return 'Бумага заказа: название, формат, граммовка, ширина и длина. '
          'Выключить нельзя — без неё заказ не посчитать.';
    case 'cardboard':
      return 'Галочка «Картон» и выбор картона. Влияет на маршрут: '
          'без картона этапы картонирования не добавляются.';
    case 'trimming':
      return 'Галочка «Подрезка» и её параметры. Влияет на маршрут.';
    case 'handle':
      return 'Выбор типа ручек. Влияет на маршрут: под каждый тип свой этап.';
    case 'paints':
      return 'Краски заказа: список, количество, комментарий. Заказу С '
          'ПЕЧАТНОЙ ФОРМОЙ краска и так обязательна — это правило уже в '
          'системе. Отмечайте «Обязателен» только вместе с условием, иначе '
          'запрёте и непечатные заказы.';
    case 'form':
      return 'Печатная форма: новая или старая, серия и номер.';
    case 'pdf':
      return 'Прикрепление PDF к заказу.';
    case 'makeready':
      return 'Поле «Приладка» — количество приладок по заказу.';
    case 'extra_papers':
      return 'Дополнительные бумаги сверх основной.';
    case 'roll':
      return 'Поле «Рулон» в размерах продукта — печатается рядом с Д×Ш×Г.';
    case 'bl_quantity':
      return 'Поле «Количество» в строке основной бумаги, в карточке '
          '«Бобинорезка». В задании у рабочего показывается как «К».';
    default:
      return affectsStageQueue
          ? 'При выключении соответствующий этап не добавляется в очередь.'
          : 'Блок формы заказа.';
  }
}

/// Заголовок раздела: значок + подпись капсом с разрядкой.
class PtSectionHeader extends StatelessWidget {
  const PtSectionHeader({
    super.key,
    required this.icon,
    required this.label,
    this.color = PtColors.primary,
  });

  final IconData icon;
  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        children: [
          Icon(icon, size: 16, color: color),
          const SizedBox(width: 8),
          Text(
            label.toUpperCase(),
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w700,
              letterSpacing: 1.1,
              color: color,
            ),
          ),
        ],
      ),
    );
  }
}

/// Переключатель 36×20 — компактнее материалового Switch, который в плотных
/// строках этапов занимал бы больше места, чем сама строка.
class PtToggle extends StatelessWidget {
  const PtToggle({super.key, required this.value, this.onChanged});

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
          duration: const Duration(milliseconds: 180),
          width: 36,
          height: 20,
          decoration: BoxDecoration(
            color: value ? PtColors.primary : const Color(0xFFD1D5DB),
            borderRadius: BorderRadius.circular(10),
          ),
          child: AnimatedAlign(
            duration: const Duration(milliseconds: 180),
            curve: Curves.easeOut,
            alignment: value ? Alignment.centerRight : Alignment.centerLeft,
            child: Container(
              margin: const EdgeInsets.symmetric(horizontal: 3),
              width: 14,
              height: 14,
              decoration: const BoxDecoration(
                color: Colors.white,
                shape: BoxShape.circle,
                boxShadow: [
                  BoxShadow(
                    color: Color(0x33000000),
                    blurRadius: 3,
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

/// Вкладка-пилюля: активная залита, остальные прозрачные.
class PtTabPill extends StatelessWidget {
  const PtTabPill({
    super.key,
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(right: 4),
      child: Material(
        color: selected ? PtColors.primary : Colors.transparent,
        borderRadius: BorderRadius.circular(PtMetrics.cardRadius),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(PtMetrics.cardRadius),
          hoverColor: selected ? null : const Color(0xFFF9FAFB),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 9),
            child: Text(
              label,
              style: TextStyle(
                fontSize: 13.5,
                fontWeight: FontWeight.w500,
                color: selected ? Colors.white : PtColors.mutedStrong,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Маленькая пилюля-счётчик («⟨2⟩ РМ», «⇄ Вариант»).
class PtChip extends StatelessWidget {
  const PtChip({
    super.key,
    required this.label,
    this.icon,
    this.accent = false,
    this.warn = false,
    this.onTap,
  });

  final String label;
  final IconData? icon;
  final bool accent;
  final bool warn;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final Color background;
    final Color borderColor;
    final Color foreground;
    if (warn) {
      background = PtColors.warnBackground;
      borderColor = PtColors.warnBorder;
      foreground = PtColors.warnText;
    } else if (accent) {
      background = const Color(0xFFF5F3FF);
      borderColor = const Color(0xFFC4B5FD);
      foreground = PtColors.violetText;
    } else {
      background = const Color(0xFFF9FAFB);
      borderColor = PtColors.border;
      foreground = PtColors.mutedStrong;
    }

    final content = Padding(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[
            Icon(icon, size: 13, color: foreground),
            const SizedBox(width: 5),
          ],
          Text(
            label,
            style: TextStyle(
              fontSize: 11.5,
              fontWeight: FontWeight.w600,
              color: foreground,
            ),
          ),
        ],
      ),
    );

    return Container(
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: borderColor),
      ),
      clipBehavior: Clip.antiAlias,
      child: onTap == null
          ? content
          : Material(
              color: Colors.transparent,
              child: InkWell(onTap: onTap, child: content),
            ),
    );
  }
}
