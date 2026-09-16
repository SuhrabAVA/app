import 'package:flutter/material.dart';

import '../warehouse/tmc_model.dart';

/// Выбор материала со склада с поиском — краска в «Изменить краски», бумага в
/// «Изменить бумагу» и в окне расхода бумаги.
///
/// Поле поиска живёт в StatefulWidget с постоянным контроллером. Раньше оно
/// собиралось прямо в диалоге как `TextFormField(key: ValueKey(search.isEmpty),
/// initialValue: search)`: на ПЕРВОМ символе ключ менялся с true на false,
/// Flutter считал это другим полем, старое уничтожал — фокус слетал и
/// клавиатура закрывалась. Сотруднику приходилось тыкать в поле на каждую
/// букву.
Future<TmcModel?> showMaterialPickerDialog({
  required BuildContext context,
  required String title,
  required String searchLabel,
  required List<TmcModel> items,
  required bool Function(TmcModel item, String query) matches,
  required String Function(TmcModel item) subtitleOf,
  String? searchHint,
}) {
  return showDialog<TmcModel>(
    context: context,
    builder: (_) => MaterialPickerDialog(
      title: title,
      searchLabel: searchLabel,
      searchHint: searchHint,
      items: items,
      matches: matches,
      subtitleOf: subtitleOf,
    ),
  );
}

class MaterialPickerDialog extends StatefulWidget {
  const MaterialPickerDialog({
    super.key,
    required this.title,
    required this.searchLabel,
    required this.items,
    required this.matches,
    required this.subtitleOf,
    this.searchHint,
  });

  final String title;
  final String searchLabel;
  final String? searchHint;
  final List<TmcModel> items;
  final bool Function(TmcModel item, String query) matches;
  final String Function(TmcModel item) subtitleOf;

  @override
  State<MaterialPickerDialog> createState() => _MaterialPickerDialogState();
}

class _MaterialPickerDialogState extends State<MaterialPickerDialog> {
  final TextEditingController _search = TextEditingController();

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final query = _search.text;
    final filtered = widget.items
        .where((item) => widget.matches(item, query))
        .toList(growable: false);

    return AlertDialog(
      title: Text(widget.title),
      content: SizedBox(
        width: 540,
        height: 420,
        child: Column(
          children: [
            TextField(
              controller: _search,
              decoration: InputDecoration(
                labelText: widget.searchLabel,
                hintText: widget.searchHint,
                prefixIcon: const Icon(Icons.search),
                // Кнопка появляется и исчезает, но само поле остаётся тем же —
                // фокус и клавиатура не теряются.
                suffixIcon: query.isEmpty
                    ? null
                    : IconButton(
                        tooltip: 'Очистить',
                        onPressed: () {
                          _search.clear();
                          setState(() {});
                        },
                        icon: const Icon(Icons.clear),
                      ),
              ),
              onChanged: (_) => setState(() {}),
            ),
            const SizedBox(height: 12),
            Expanded(
              child: filtered.isEmpty
                  ? const Center(child: Text('Ничего не найдено.'))
                  : ListView.separated(
                      itemCount: filtered.length,
                      separatorBuilder: (_, __) => const Divider(height: 1),
                      itemBuilder: (context, index) {
                        final item = filtered[index];
                        return ListTile(
                          title: Text(item.description),
                          subtitle: Text(widget.subtitleOf(item)),
                          onTap: () => Navigator.of(context).pop(item),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Отмена'),
        ),
      ],
    );
  }
}
