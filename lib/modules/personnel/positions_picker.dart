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
    final techLeader = pr.findTechLeaderPosition();
    final wh = pr.findWarehouseHeadPosition();
    final cmm = pr.findCmmSpecialistPosition();

    final managerSelected = manager != null && _selected.contains(manager.id);
    final techLeaderSelected =
        techLeader != null && _selected.contains(techLeader.id);
    final warehouseSelected = wh != null && _selected.contains(wh.id);
    final cmmSelected = cmm != null && _selected.contains(cmm.id);
    final specialSelected = managerSelected || techLeaderSelected || warehouseSelected || cmmSelected;

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
              onSelected: specialSelected
                  ? null // если выбран менеджер или зав. складом — отключаем
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

          // Спецроли (блок 2)
          if (manager != null || techLeader != null || wh != null || cmm != null) ...[
            const Divider(height: 24),
            Text('Роль с отдельным рабочим местом',
                style: Theme.of(context).textTheme.labelLarge),
            const SizedBox(height: 8),
            if (manager != null)
              FilterChip(
                label: const Text('Менеджер (эксклюзивно)'),
                selected: managerSelected,
                onSelected: (v) {
                  setState(() {
                    if (v) {
                      // оставляем только менеджера
                      _selected
                        ..clear()
                        ..add(manager.id);
                    } else {
                      _selected.remove(manager.id);
                    }
                  });
                  _emit();
                },
              ),
            if (manager != null) const SizedBox(height: 8),
            if (techLeader != null)
              FilterChip(
                label: const Text('Технический лидер (эксклюзивно)'),
                selected: techLeaderSelected,
                onSelected: (v) {
                  setState(() {
                    if (v) {
                      _selected
                        ..clear()
                        ..add(techLeader.id);
                    } else {
                      _selected.remove(techLeader.id);
                    }
                  });
                  _emit();
                },
              ),
            if (techLeader != null) const SizedBox(height: 8),
            if (wh != null)
              FilterChip(
                label: const Text('Заведующий складом (эксклюзивно)'),
                selected: warehouseSelected,
                onSelected: (v) {
                  setState(() {
                    if (v) {
                      // только зав. складом
                      _selected
                        ..clear()
                        ..add(wh.id);
                    } else {
                      _selected.remove(wh.id);
                    }
                  });
                  _emit();
                },
              ),
            if (wh != null) const SizedBox(height: 8),
            if (cmm != null)
              FilterChip(
                label: const Text('CMM специалист (эксклюзивно)'),
                selected: cmmSelected,
                onSelected: (v) {
                  setState(() {
                    if (v) {
                      _selected
                        ..clear()
                        ..add(cmm.id);
                    } else {
                      _selected.remove(cmm.id);
                    }
                  });
                  _emit();
                },
              ),
            const SizedBox(height: 4),
            Text(
              'Если выбран «Менеджер», «Технический лидер», «Заведующий складом» или «CMM специалист», выбрать другие должности нельзя, так как у них отдельное рабочее пространство.',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(color: Colors.black54),
            ),
          ],
      ],
    );
  }
  
}
