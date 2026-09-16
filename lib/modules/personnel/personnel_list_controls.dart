/// Общие элементы поиска и фильтров для списков «Персонала».
///
/// Все экраны модуля собирают одну и ту же полосу: поле поиска, ряд чипов
/// фильтров и строку «Найдено N из M · Сбросить». Чип с выбранным значением
/// подсвечен и подписан выбором — так видно, почему список короче обычного,
/// без открытия каждого фильтра.
library;

import 'package:flutter/material.dart';

import 'personnel_list_filters.dart';

/// Вариант мультивыбора.
class FilterOption {
  const FilterOption(this.id, this.title);
  final String id;
  final String title;
}

/// Поле поиска + чипы + итог.
class PersonnelFilterBar extends StatelessWidget {
  const PersonnelFilterBar({
    super.key,
    required this.controller,
    required this.hint,
    required this.onQueryChanged,
    required this.shown,
    required this.total,
    required this.isActive,
    required this.onReset,
    this.filters = const <Widget>[],
    this.note,
  });

  final TextEditingController controller;
  final String hint;
  final ValueChanged<String> onQueryChanged;
  final List<Widget> filters;
  final int shown;
  final int total;
  final bool isActive;
  final VoidCallback onReset;

  /// Пояснение под итогом (например, почему выключена перестановка).
  final String? note;

  @override
  Widget build(BuildContext context) {
    final muted = TextStyle(fontSize: 12, color: Colors.grey.shade700);
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ValueListenableBuilder<TextEditingValue>(
            valueListenable: controller,
            builder: (context, value, _) => TextField(
              controller: controller,
              onChanged: onQueryChanged,
              decoration: InputDecoration(
                hintText: hint,
                prefixIcon: const Icon(Icons.search),
                isDense: true,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                ),
                suffixIcon: value.text.isEmpty
                    ? null
                    : IconButton(
                        tooltip: 'Очистить поиск',
                        icon: const Icon(Icons.close),
                        onPressed: () {
                          controller.clear();
                          onQueryChanged('');
                        },
                      ),
              ),
            ),
          ),
          if (filters.isNotEmpty) ...[
            const SizedBox(height: 8),
            Wrap(spacing: 8, runSpacing: 6, children: filters),
          ],
          if (isActive) ...[
            const SizedBox(height: 4),
            Row(
              children: [
                Expanded(child: Text('Найдено $shown из $total', style: muted)),
                TextButton.icon(
                  onPressed: onReset,
                  icon: const Icon(Icons.filter_alt_off_outlined, size: 18),
                  label: const Text('Сбросить'),
                ),
              ],
            ),
          ],
          if (note != null) Text(note!, style: muted),
        ],
      ),
    );
  }
}

/// Чип мультивыбора: по нажатию — список с галочками и своим поиском
/// (должностей и рабочих мест бывает несколько десятков).
class MultiSelectFilterChip extends StatelessWidget {
  const MultiSelectFilterChip({
    super.key,
    required this.label,
    required this.options,
    required this.selected,
    required this.onChanged,
  });

  final String label;
  final List<FilterOption> options;
  final Set<String> selected;
  final ValueChanged<Set<String>> onChanged;

  String get _caption {
    if (selected.isEmpty) return label;
    final titles = options
        .where((o) => selected.contains(o.id))
        .map((o) => o.title)
        .toList();
    if (titles.isEmpty) return label;
    if (titles.length == 1) return '$label: ${titles.first}';
    return '$label: ${titles.first} +${titles.length - 1}';
  }

  @override
  Widget build(BuildContext context) {
    return FilterChip(
      label: Text(_caption),
      selected: selected.isNotEmpty,
      showCheckmark: false,
      avatar: const Icon(Icons.arrow_drop_down, size: 18),
      onSelected: (_) async {
        final result = await showDialog<Set<String>>(
          context: context,
          builder: (_) => _MultiSelectDialog(
            title: label,
            options: options,
            initial: selected,
          ),
        );
        if (result != null) onChanged(result);
      },
    );
  }
}

class _MultiSelectDialog extends StatefulWidget {
  const _MultiSelectDialog({
    required this.title,
    required this.options,
    required this.initial,
  });

  final String title;
  final List<FilterOption> options;
  final Set<String> initial;

  @override
  State<_MultiSelectDialog> createState() => _MultiSelectDialogState();
}

class _MultiSelectDialogState extends State<_MultiSelectDialog> {
  late final Set<String> _selected = {...widget.initial};
  String _query = '';

  @override
  Widget build(BuildContext context) {
    final visible = widget.options
        .where((o) => matchesSearch(_query, [o.title]))
        .toList(growable: false);
    return AlertDialog(
      title: Text(widget.title),
      content: SizedBox(
        width: 360,
        height: 420,
        child: Column(
          children: [
            if (widget.options.length > 8)
              TextField(
                autofocus: true,
                decoration: const InputDecoration(
                  hintText: 'Найти…',
                  prefixIcon: Icon(Icons.search),
                  isDense: true,
                ),
                onChanged: (v) => setState(() => _query = v),
              ),
            Expanded(
              child: visible.isEmpty
                  ? const Center(child: Text('Ничего не найдено'))
                  : ListView.builder(
                      itemCount: visible.length,
                      itemBuilder: (_, i) {
                        final option = visible[i];
                        return CheckboxListTile(
                          dense: true,
                          value: _selected.contains(option.id),
                          title: Text(option.title),
                          controlAffinity: ListTileControlAffinity.leading,
                          onChanged: (on) => setState(() {
                            if (on == true) {
                              _selected.add(option.id);
                            } else {
                              _selected.remove(option.id);
                            }
                          }),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, <String>{}),
          child: const Text('Сбросить'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, _selected),
          child: const Text('Готово'),
        ),
      ],
    );
  }
}

/// Чип одиночного выбора: первый вариант — «все» (значение по умолчанию).
class ChoiceFilterChip<T> extends StatelessWidget {
  const ChoiceFilterChip({
    super.key,
    required this.label,
    required this.value,
    required this.choices,
    required this.onChanged,
  });

  final String label;
  final T value;

  /// Пары «значение — подпись»; первая — «не фильтровать».
  final List<(T, String)> choices;
  final ValueChanged<T> onChanged;

  @override
  Widget build(BuildContext context) {
    final isDefault = value == choices.first.$1;
    final current = choices.firstWhere(
      (c) => c.$1 == value,
      orElse: () => choices.first,
    );
    return PopupMenuButton<T>(
      tooltip: label,
      initialValue: value,
      onSelected: onChanged,
      itemBuilder: (_) => [
        for (final choice in choices)
          PopupMenuItem<T>(value: choice.$1, child: Text(choice.$2)),
      ],
      child: IgnorePointer(
        child: FilterChip(
          label: Text(isDefault ? label : '$label: ${current.$2}'),
          selected: !isDefault,
          showCheckmark: false,
          avatar: const Icon(Icons.arrow_drop_down, size: 18),
          onSelected: (_) {},
        ),
      ),
    );
  }
}

/// «Да / Нет / Все» — самый частый случай [ChoiceFilterChip].
class TriFilterChip extends StatelessWidget {
  const TriFilterChip({
    super.key,
    required this.label,
    required this.value,
    required this.onChanged,
    this.yes = 'есть',
    this.no = 'нет',
  });

  final String label;
  final TriFilter value;
  final ValueChanged<TriFilter> onChanged;
  final String yes;
  final String no;

  @override
  Widget build(BuildContext context) {
    return ChoiceFilterChip<TriFilter>(
      label: label,
      value: value,
      choices: [
        (TriFilter.any, 'Все'),
        (TriFilter.yes, yes),
        (TriFilter.no, no),
      ],
      onChanged: onChanged,
    );
  }
}

/// Пустой результат: отличаем «записей нет» от «ничего не нашлось».
class PersonnelEmptyResult extends StatelessWidget {
  const PersonnelEmptyResult({
    super.key,
    required this.isFiltered,
    required this.emptyText,
    required this.onReset,
  });

  final bool isFiltered;
  final String emptyText;
  final VoidCallback onReset;

  @override
  Widget build(BuildContext context) {
    if (!isFiltered) return Center(child: Text(emptyText));
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Text('По запросу и фильтрам ничего не найдено'),
          const SizedBox(height: 8),
          OutlinedButton.icon(
            onPressed: onReset,
            icon: const Icon(Icons.filter_alt_off_outlined),
            label: const Text('Сбросить'),
          ),
        ],
      ),
    );
  }
}
