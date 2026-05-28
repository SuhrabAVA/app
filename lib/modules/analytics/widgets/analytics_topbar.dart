import 'package:flutter/material.dart';

import '../utils/analytics_colors.dart';

/// Верхняя панель: брэнд + три таб-кнопки.
enum AnalyticsTopTab { employees, workplaces, schedule }

class AnalyticsTopbar extends StatelessWidget {
  const AnalyticsTopbar({
    super.key,
    required this.selected,
    required this.onTabChanged,
    this.onBack,
  });

  final AnalyticsTopTab selected;
  final ValueChanged<AnalyticsTopTab> onTabChanged;
  final VoidCallback? onBack;

  @override
  Widget build(BuildContext context) {
    final brandBlock = Row(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        if (onBack != null) ...[
          IconButton(
            icon:
                const Icon(Icons.arrow_back, color: AnalyticsColors.text),
            onPressed: onBack,
            tooltip: 'Назад',
          ),
          const SizedBox(width: 6),
        ],
        Container(
          width: 44,
          height: 44,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(14),
            gradient: AnalyticsColors.accentGradient,
          ),
          alignment: Alignment.center,
          child: const Text(
            'A',
            style: TextStyle(
              color: Color(0xFF00121C),
              fontWeight: FontWeight.w900,
              fontSize: 22,
            ),
          ),
        ),
        const SizedBox(width: 12),
        ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 460),
          child: const Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                'Аналитика производства',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: AnalyticsColors.text,
                  fontWeight: FontWeight.w900,
                  fontSize: 22,
                  height: 1.1,
                ),
              ),
              SizedBox(height: 4),
              Text(
                'сотрудники · рабочие места · графики работы · зарплата',
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style:
                    TextStyle(color: AnalyticsColors.muted, fontSize: 12),
              ),
            ],
          ),
        ),
      ],
    );

    final tabsBlock = Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        _Tab(
          label: 'Сотрудники',
          isActive: selected == AnalyticsTopTab.employees,
          onTap: () => onTabChanged(AnalyticsTopTab.employees),
        ),
        _Tab(
          label: 'Рабочие места',
          isActive: selected == AnalyticsTopTab.workplaces,
          onTap: () => onTabChanged(AnalyticsTopTab.workplaces),
        ),
        _Tab(
          label: 'Графики работы',
          isActive: selected == AnalyticsTopTab.schedule,
          onTap: () => onTabChanged(AnalyticsTopTab.schedule),
        ),
      ],
    );

    return Container(
      margin: const EdgeInsets.fromLTRB(16, 16, 16, 12),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
      decoration: BoxDecoration(
        color: const Color(0xD10B1020),
        borderRadius: BorderRadius.circular(22),
        border: Border.all(color: AnalyticsColors.line),
        boxShadow: const [
          BoxShadow(
            color: Color(0x59000000),
            blurRadius: 70,
            offset: Offset(0, 22),
          ),
        ],
      ),
      // Внешний Wrap позволяет блокам уйти на новую строку, когда
      // ширины не хватает (узкое окно), и убирает RenderFlex overflow.
      child: Wrap(
        alignment: WrapAlignment.spaceBetween,
        crossAxisAlignment: WrapCrossAlignment.center,
        spacing: 16,
        runSpacing: 12,
        children: [brandBlock, tabsBlock],
      ),
    );
  }
}

class _Tab extends StatelessWidget {
  const _Tab({
    required this.label,
    required this.isActive,
    required this.onTap,
  });
  final String label;
  final bool isActive;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(999),
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 10),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(999),
            gradient: isActive ? AnalyticsColors.accentGradient : null,
            color: isActive ? null : const Color(0xBF0F172A),
            border: Border.all(
              color: isActive ? Colors.transparent : AnalyticsColors.line,
            ),
          ),
          child: Text(
            label,
            style: TextStyle(
              color: isActive
                  ? const Color(0xFF00121C)
                  : AnalyticsColors.text,
              fontWeight: isActive ? FontWeight.w900 : FontWeight.w600,
              fontSize: 13,
            ),
          ),
        ),
      ),
    );
  }
}
