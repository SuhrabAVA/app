import 'package:flutter/material.dart';

import '../orders/product_type_settings.dart';

/// Выбор формулы фактического количества для версии настроек.
///
/// Настройка версии, а не этапа, поэтому карточка стоит над списком этапов, а
/// не в строке. Показана здесь, а не на вкладке блоков формы, потому что
/// отвечает на вопрос о РЕЗУЛЬТАТЕ маршрута: чем считается сделанное, когда
/// заказ прошёл очередь.
///
/// Список закрыт: каждый код реализован функцией в Dart, и новая формула — это
/// релиз приложения. Поэтому здесь выпадающий список справочника, а не поле
/// ввода выражения.
class ProductTypeFormulaCard extends StatelessWidget {
  const ProductTypeFormulaCard({
    super.key,
    required this.formula,
    required this.locked,
    required this.onChanged,
  });

  /// Текущее значение `product_type_configs.actual_qty_formula`.
  final String? formula;
  final bool locked;
  final Future<void> Function(String formula) onChanged;

  @override
  Widget build(BuildContext context) {
    final formulas = ProductTypeSettings.instance.actualQtyFormulas;
    final selected = formulas.where((f) => f.code == formula).firstOrNull;

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'ФАКТИЧЕСКОЕ КОЛИЧЕСТВО',
            style: TextStyle(
              fontSize: 10,
              fontWeight: FontWeight.w700,
              letterSpacing: 0.6,
              color: Colors.grey.shade600,
            ),
          ),
          const SizedBox(height: 6),
          DropdownButtonFormField<String>(
            initialValue: selected?.code,
            isExpanded: true,
            isDense: true,
            decoration: const InputDecoration(
              border: OutlineInputBorder(),
              contentPadding: EdgeInsets.symmetric(horizontal: 10, vertical: 8),
            ),
            items: [
              for (final f in formulas)
                DropdownMenuItem<String>(
                  value: f.code,
                  child: Text(f.title, style: const TextStyle(fontSize: 13)),
                ),
            ],
            onChanged: locked
                ? null
                : (value) {
                    if (value == null || value == formula) return;
                    onChanged(value);
                  },
          ),
          if (selected != null) ...[
            const SizedBox(height: 4),
            Text(
              selected.description,
              style: TextStyle(fontSize: 11, color: Colors.grey.shade700),
            ),
          ],
        ],
      ),
    );
  }
}
