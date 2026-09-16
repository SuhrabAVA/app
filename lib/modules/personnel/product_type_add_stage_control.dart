import 'package:flutter/material.dart';

import '../orders/product_type_route.dart';
import '../orders/product_type_settings.dart';

/// Добавление этапа в конец маршрута.
///
/// ПОЗИЦИЯ — В КОНЕЦ ДИАПАЗОНА РАНГОВ, НЕ МЕЖДУ
/// Новый этап получает ранг на единицу больше последнего подвижного, то есть
/// встаёт перед закреплённой упаковкой и ничего не сдвигает. Вставка «между»
/// неявно меняла бы ранги существующих этапов — маршрут поехал бы в местах,
/// куда техлид не смотрел. Дальше он двигает этап стрелками, которые уже
/// работают и накрыты тестом.
///
/// ДВА ВИДА ЭТАПА
/// Одиночный: ключ равен uuid рабочего места — так устроены все одиночные
/// этапы сида, и по этому ключу группируют потребители.
/// Группа: ключ генерируется (`grp_` плюс восемь hex), техлид задаёт подпись
/// и набор рабочих мест. Ключ создаётся ОДИН РАЗ и при переименовании подписи
/// не меняется — иначе живые планы разъехались бы с настройками.
class ProductTypeAddStageControl extends StatelessWidget {
  const ProductTypeAddStageControl({
    super.key,
    required this.route,
    required this.locked,
    required this.onAddWorkplaceStage,
    required this.onAddGroupStage,
  });

  final ProductTypeRoute route;
  final bool locked;

  final Future<void> Function(String workplaceId) onAddWorkplaceStage;
  final Future<void> Function() onAddGroupStage;

  /// Рабочие места, уже занятые как ключ этапа ВЕРХНЕГО УРОВНЯ.
  ///
  /// Уникальность — (config_id, parent_variant_id, stage_group_key), поэтому
  /// второй одиночный этап на том же рабочем месте на верхнем уровне
  /// невозможен. Под-этапы вариантов сюда не попадают: там ключ может
  /// повторяться, «Вставка картона» стоит под обоими автоматами.
  Set<String> get _usedAsTopLevelKey => route.stages
      .where((s) => s.level == 0)
      .map((s) => s.key)
      .toSet();

  @override
  Widget build(BuildContext context) {
    final used = _usedAsTopLevelKey;

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
      child: Row(
        children: [
          PopupMenuButton<String>(
            enabled: !locked,
            onSelected: onAddWorkplaceStage,
            itemBuilder: (_) => [
              for (final workplace in ProductTypeSettings.instance.workplaces)
                PopupMenuItem<String>(
                  value: workplace.id,
                  enabled: !used.contains(workplace.id),
                  child: Row(
                    children: [
                      Expanded(child: Text(workplace.name)),
                      if (used.contains(workplace.id))
                        Text('уже есть в маршруте',
                            style: TextStyle(
                                fontSize: 11, color: Colors.grey.shade500)),
                    ],
                  ),
                ),
            ],
            child: _label(Icons.add, 'Добавить этап', Colors.indigo.shade400),
          ),
          const SizedBox(width: 8),
          InkWell(
            onTap: locked ? null : onAddGroupStage,
            child: _label(Icons.layers_outlined, 'Этап-группа из нескольких РМ',
                Colors.grey.shade600),
          ),
        ],
      ),
    );
  }

  Widget _label(IconData icon, String text, Color color) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 4),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 16, color: color),
            const SizedBox(width: 4),
            Text(text, style: TextStyle(fontSize: 12, color: color)),
          ],
        ),
      );
}
