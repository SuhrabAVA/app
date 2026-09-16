import 'package:flutter/material.dart';

import '../orders/product_type_execution_options.dart';
import '../orders/product_type_route.dart';

/// Режим очерёдности этапа и его партнёр.
///
/// Живёт в панели этапа рядом с условием: оба отвечают на вопрос «когда этот
/// этап вообще появляется», только условие решает ПОПАДЁТ ЛИ он в маршрут, а
/// режим — КОГДА ему разрешено начаться.
///
/// Партнёр выбирается из списка, а не вводится: правила достижимости
/// (партнёр раньше по рангу, чужая ветка переключателя не годится) техлиду
/// проще соблюдать, когда неподходящего варианта просто нет в списке.
class ProductTypeStageExecutionEditor extends StatelessWidget {
  const ProductTypeStageExecutionEditor({
    super.key,
    required this.stage,
    required this.route,
    required this.locked,
    required this.onChanged,
  });

  final RouteStage stage;
  final ProductTypeRoute route;
  final bool locked;

  /// Режим и партнёр меняются одним вызовом: раздельная запись оставила бы
  /// этап «параллельно без партнёра».
  final Future<void> Function(String mode, String? partnerRowId) onChanged;

  @override
  Widget build(BuildContext context) {
    final partners = eligiblePartners(route, stage);
    final partner = partnerOf(route, stage);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'ОЧЕРЁДНОСТЬ',
          style: TextStyle(
            fontSize: 10,
            fontWeight: FontWeight.w700,
            letterSpacing: 0.6,
            color: Colors.grey.shade600,
          ),
        ),
        const SizedBox(height: 4),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              flex: 3,
              child: DropdownButtonFormField<String>(
                initialValue: kExecutionModes.contains(stage.executionMode)
                    ? stage.executionMode
                    : 'sequential',
                isExpanded: true,
                isDense: true,
                decoration: const InputDecoration(
                  border: OutlineInputBorder(),
                  contentPadding:
                      EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                ),
                items: [
                  for (final mode in kExecutionModes)
                    DropdownMenuItem<String>(
                      value: mode,
                      // Режим «параллельно с выбранным этапом» без единого
                      // кандидата выбрать нельзя: партнёра взять неоткуда, и
                      // этап оказался бы в невалидном состоянии.
                      enabled: mode != 'parallel_with' || partners.isNotEmpty,
                      child: Text(
                        executionModeLabel(mode),
                        style: TextStyle(
                          fontSize: 13,
                          color: mode == 'parallel_with' && partners.isEmpty
                              ? Colors.grey
                              : null,
                        ),
                      ),
                    ),
                ],
                onChanged: locked ? null : (value) => _onMode(value, partners),
              ),
            ),
            if (stage.executionMode == 'parallel_with') ...[
              const SizedBox(width: 8),
              Expanded(
                flex: 3,
                child: DropdownButtonFormField<String>(
                  initialValue:
                      partners.any((p) => p.rowId == partner?.rowId)
                          ? partner?.rowId
                          : null,
                  isExpanded: true,
                  isDense: true,
                  decoration: const InputDecoration(
                    border: OutlineInputBorder(),
                    labelText: 'Партнёр',
                    contentPadding:
                        EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                  ),
                  items: [
                    for (final candidate in partners)
                      DropdownMenuItem<String>(
                        value: candidate.rowId,
                        child: Text(candidate.title,
                            style: const TextStyle(fontSize: 13)),
                      ),
                  ],
                  onChanged: locked
                      ? null
                      : (value) {
                          if (value == null) return;
                          onChanged('parallel_with', value);
                        },
                ),
              ),
            ],
          ],
        ),
        const SizedBox(height: 4),
        Text(
          _hint(partners),
          style: TextStyle(fontSize: 11, color: Colors.grey.shade700),
        ),
      ],
    );
  }

  String _hint(List<RouteStage> partners) {
    if (stage.executionMode == 'parallel_with' && partners.isEmpty) {
      return 'Партнёра выбрать не из чего: подходят только этапы, стоящие '
          'раньше и появляющиеся в той же ветке.';
    }
    return executionModeHint(stage.executionMode);
  }

  /// Переход в `parallel_with` сразу берёт ближайшего допустимого партнёра.
  ///
  /// Иначе между выбором режима и выбором партнёра существовало бы записанное
  /// состояние «параллельно без партнёра» — валидатор его ловит, но чинить
  /// пришлось бы техлиду, хотя выбор за него очевиден.
  void _onMode(String? value, List<RouteStage> partners) {
    if (value == null || value == stage.executionMode) return;
    if (value == 'parallel_with') {
      if (partners.isEmpty) return;
      final current = stage.parallelWithStageId;
      final keep = partners.any((p) => p.rowId == current);
      onChanged(value, keep ? current : partners.last.rowId);
      return;
    }
    onChanged(value, null);
  }
}
