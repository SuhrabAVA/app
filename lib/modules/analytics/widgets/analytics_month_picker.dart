import 'package:flutter/material.dart';

import '../models/analytics_month.dart';
import '../utils/analytics_colors.dart';

class AnalyticsMonthPicker extends StatelessWidget {
  const AnalyticsMonthPicker({
    super.key,
    required this.month,
    required this.onChanged,
  });

  final AnalyticsMonth month;
  final ValueChanged<AnalyticsMonth> onChanged;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        IconButton(
          tooltip: 'Предыдущий месяц',
          icon: const Icon(Icons.chevron_left, color: AnalyticsColors.text),
          onPressed: () => onChanged(month.previous),
        ),
        InkWell(
          borderRadius: BorderRadius.circular(14),
          onTap: () => _pickMonth(context),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            decoration: BoxDecoration(
              color: const Color(0xB30B1226),
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: AnalyticsColors.line),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.calendar_month,
                    color: AnalyticsColors.blue, size: 18),
                const SizedBox(width: 8),
                Text(
                  month.humanTitle,
                  style: const TextStyle(
                    color: AnalyticsColors.text,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ],
            ),
          ),
        ),
        IconButton(
          tooltip: 'Следующий месяц',
          icon: const Icon(Icons.chevron_right, color: AnalyticsColors.text),
          onPressed: () {
            final next = AnalyticsMonth.fromYearMonth(
              month.month == 12 ? month.year + 1 : month.year,
              month.month == 12 ? 1 : month.month + 1,
            );
            onChanged(next);
          },
        ),
      ],
    );
  }

  Future<void> _pickMonth(BuildContext context) async {
    final now = DateTime.now();
    final picked = await showDatePicker(
      context: context,
      initialDate: month.firstDay,
      firstDate: DateTime(now.year - 10, 1),
      lastDate: DateTime(now.year + 5, 12),
      helpText: 'Выберите любой день месяца',
      builder: (context, child) {
        return Theme(
          data: ThemeData.dark(),
          child: child ?? const SizedBox.shrink(),
        );
      },
    );
    if (picked != null) {
      onChanged(AnalyticsMonth(picked));
    }
  }
}
