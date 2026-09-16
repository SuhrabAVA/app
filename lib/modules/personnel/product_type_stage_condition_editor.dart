import 'package:flutter/material.dart';

import '../orders/product_type_condition_options.dart';
import '../orders/product_type_route.dart';

/// Редактор условия этапа: когда этап попадает в очередь заказа.
///
/// Условие ОДНО и выбирается из закрытого справочника. Причина не в
/// упрощении: после перехода на подочереди каждое из 36 существующих правил
/// сводится максимум к одному предикату — отрицание, которое было нужно
/// правилу «Вставка картона при картоне И НЕ Труба», теперь выражается тем,
/// чьим под-этапом является строка. Второе условие и `negate` остались в
/// схеме заделом и в редакторе не показываются.
///
/// Живёт в панели этапа, а не в строке списка: строка — это ГРУППА ранга, а
/// условие принадлежит конкретному этапу, и у связки из трёх ручек условий
/// три разных.
class ProductTypeStageConditionEditor extends StatelessWidget {
  const ProductTypeStageConditionEditor({
    super.key,
    required this.stage,
    required this.locked,
    required this.onChanged,
  });

  final RouteStage stage;
  final bool locked;

  /// `predicate = null` означает «всегда».
  final Future<void> Function(String? predicate, String? param) onChanged;

  RouteCondition? get _current =>
      stage.conditions.isEmpty ? null : stage.conditions.first;

  ConditionOption get _selectedOption {
    final predicate = _current?.predicate;
    for (final option in kConditionOptions) {
      if (option.predicate == predicate) return option;
    }
    return kConditionOptions.first;
  }

  @override
  Widget build(BuildContext context) {
    final option = _selectedOption;
    final param = _current?.param;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('УСЛОВИЕ',
            style: TextStyle(
              fontSize: 10,
              fontWeight: FontWeight.w700,
              letterSpacing: 0.6,
              color: Colors.grey.shade600,
            )),
        const SizedBox(height: 2),
        Row(
          children: [
            Text('Этап добавляется',
                style: TextStyle(fontSize: 12, color: Colors.grey.shade600)),
            const SizedBox(width: 8),
            DropdownButton<String?>(
              value: option.predicate,
              isDense: true,
              underline: const SizedBox.shrink(),
              style: const TextStyle(fontSize: 13, color: Colors.black87),
              items: [
                for (final o in kConditionOptions)
                  DropdownMenuItem<String?>(
                    value: o.predicate,
                    child: Text(o.label, style: const TextStyle(fontSize: 13)),
                  ),
              ],
              onChanged: locked ? null : (value) => _selectPredicate(value),
            ),
            if (option.requiresParam) ...[
              const SizedBox(width: 8),
              DropdownButton<String>(
                // Значение по умолчанию нужно, иначе смена предиката на
                // handle_type_is оставила бы условие без параметра, и функция
                // отвергла бы запись.
                value: kHandleTypeParamLabels.containsKey(param)
                    ? param
                    : kHandleTypeParamLabels.keys.first,
                isDense: true,
                underline: const SizedBox.shrink(),
                items: [
                  for (final entry in kHandleTypeParamLabels.entries)
                    DropdownMenuItem<String>(
                      value: entry.key,
                      child: Text(entry.value,
                          style: const TextStyle(fontSize: 13)),
                    ),
                ],
                onChanged: locked
                    ? null
                    : (value) => onChanged(option.predicate, value),
              ),
            ],
          ],
        ),
      ],
    );
  }

  Future<void> _selectPredicate(String? predicate) async {
    if (predicate == null) return onChanged(null, null);
    final option =
        kConditionOptions.firstWhere((o) => o.predicate == predicate);
    // Предикат с параметром получает первое допустимое значение сразу: этап с
    // условием без параметра не сохранился бы, а показывать техлиду отказ на
    // ровном месте незачем.
    final param =
        option.requiresParam ? kHandleTypeParamLabels.keys.first : null;
    return onChanged(predicate, param);
  }
}
