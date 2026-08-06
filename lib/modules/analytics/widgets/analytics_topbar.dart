import 'dart:math' as math;

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
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 8, 16, 4),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: AnalyticsColors.card,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AnalyticsColors.line),
        boxShadow: const [
          BoxShadow(
            color: Color(0x12000000),
            blurRadius: 10,
            offset: Offset(0, 2),
          ),
        ],
      ),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final tabsBlock = _TabsBlock(
            selected: selected,
            onTabChanged: onTabChanged,
          );
          final brandBlock = _BrandBlock(
            maxWidth: constraints.maxWidth,
            onBack: onBack,
          );

          if (constraints.maxWidth < 760) {
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                brandBlock,
                const SizedBox(height: 8),
                tabsBlock,
              ],
            );
          }

          return Row(
            children: [
              Expanded(child: brandBlock),
              const SizedBox(width: 16),
              tabsBlock,
            ],
          );
        },
      ),
    );
  }
}

class _BrandBlock extends StatelessWidget {
  const _BrandBlock({required this.maxWidth, this.onBack});

  final double maxWidth;
  final VoidCallback? onBack;

  @override
  Widget build(BuildContext context) {
    return ConstrainedBox(
      constraints: BoxConstraints(maxWidth: math.min(maxWidth, 560)),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          if (onBack != null) ...[
            IconButton(
              icon: const Icon(Icons.arrow_back, color: AnalyticsColors.text),
              onPressed: onBack,
              tooltip: 'Назад',
              padding: EdgeInsets.zero,
              visualDensity: VisualDensity.compact,
              constraints: const BoxConstraints.tightFor(
                width: 36,
                height: 36,
              ),
            ),
            const SizedBox(width: 6),
          ],
          Container(
            width: 36,
            height: 36,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(10),
              gradient: AnalyticsColors.accentGradient,
            ),
            alignment: Alignment.center,
            child: const Text(
              'A',
              style: TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.w600,
                fontSize: 18,
              ),
            ),
          ),
          const SizedBox(width: 10),
          const Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  'Аналитика производства',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: AnalyticsColors.text,
                    fontWeight: FontWeight.w600,
                    fontSize: 18,
                    height: 1.1,
                  ),
                ),
                SizedBox(height: 2),
                Text(
                  'сотрудники · рабочие места · графики работы · зарплата',
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: AnalyticsColors.muted, fontSize: 11),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _TabsBlock extends StatelessWidget {
  const _TabsBlock({required this.selected, required this.onTabChanged});

  final AnalyticsTopTab selected;
  final ValueChanged<AnalyticsTopTab> onTabChanged;

  @override
  Widget build(BuildContext context) {
    return Wrap(
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
        borderRadius: BorderRadius.circular(12),
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(12),
            gradient: isActive ? AnalyticsColors.accentGradient : null,
            color: isActive ? null : AnalyticsColors.bg2,
            border: Border.all(
              color: isActive ? Colors.transparent : AnalyticsColors.line,
            ),
          ),
          child: Text(
            label,
            style: TextStyle(
              color: isActive ? Colors.white : AnalyticsColors.text,
              fontWeight: FontWeight.w500,
              fontSize: 13,
            ),
          ),
        ),
      ),
    );
  }
}
