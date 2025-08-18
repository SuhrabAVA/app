import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'position_model.dart';
import 'personnel_provider.dart';
import 'personnel_constants.dart'; // <-- чтобы был kManagerId


/// Виджет выбора должностей:
/// - «Менеджер» выделен отдельным блоком снизу
/// - Если выбран «Менеджер», остальные должности выбрать нельзя
/// - Если выбрать обычную должность — «Менеджер» снимается
class ManagerAwarePositionsPicker extends StatefulWidget {
  final List<String> value; // выбранные ids
  final ValueChanged<List<String>> onChanged;

  const ManagerAwarePositionsPicker({
    super.key,
    required this.value,
    required this.onChanged,
  });

  @override
  State<ManagerAwarePositionsPicker> createState() => _ManagerAwarePositionsPickerState();
}

class _ManagerAwarePositionsPickerState extends State<ManagerAwarePositionsPicker> {
  late List<String> _selected;

  @override
  void initState() {
    super.initState();
    _selected = List<String>.from(widget.value);
  }

  void _emit() => widget.onChanged(List.unmodifiable(_selected));

  @override
  Widget build(BuildContext context) {
    final pr = context.watch<PersonnelProvider>();

    final regular = pr.regularPositions;
    final manager = pr.findManagerPosition();

    final managerSelected = _selected.contains(kManagerId) ||
        (manager != null && _selected.contains(manager.id));

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Должности', style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 8),

        // Обычные должности (блок 1)
        Wrap(
          spacing: 10,
          runSpacing: 10,
          children: regular.map((p) {
            final sel = _selected.contains(p.id);
            return FilterChip(
              label: Text(p.name),
              selected: sel,
              onSelected: managerSelected
                  ? null // если менеджер выбран — отключаем
                  : (v) {
                      setState(() {
                        if (v) {
                          _selected.add(p.id);
                          _selected = _selected.toSet().toList();
                        } else {
                          _selected.remove(p.id);
                        }
                      });
                      _emit();
                    },
            );
          }).toList(),
        ),

        const SizedBox(height: 16),

        // Менеджер (блок 2)
        if (manager != null) ...[
          const Divider(height: 24),
          Text('Роль с отдельным рабочим местом', style: Theme.of(context).textTheme.labelLarge),
          const SizedBox(height: 8),
          FilterChip(
            label: const Text('Менеджер (эксклюзивно)'),
            selected: managerSelected,
            onSelected: (v) {
              setState(() {
                if (v) {
                  _selected
                    ..clear()
                    ..add(kManagerId); // оставляем только менеджера
                } else {
                  _selected.remove(kManagerId);
                  _selected.remove(manager.id);
                }
              });
              _emit();
            },
          ),
          const SizedBox(height: 4),
          Text(
            'Если выбран «Менеджер», выбрать другие должности нельзя, так как у менеджера отдельное рабочее пространство (Заказы + Чат).',
            style: Theme.of(context).textTheme.bodySmall?.copyWith(color: Colors.black54),
          ),
        ],
      ],
    );
  }
  
}
