/// Диалоги редактора дополнительных опций заказа.
///
/// Вынесены из экрана, чтобы тот остался про список опций и его порядок.
library;

import 'package:flutter/material.dart';

import '../orders/order_extra_options.dart';
import '../orders/order_extra_options_repository.dart';
import 'product_type_design.dart';

/// Ввод одной строки: создание и переименование ходят через него.
///
/// Кнопка подтверждения заперта на пустом поле — пустое название отвергнет
/// проверка `btrim(title) <> ''`, и техлид увидел бы код ошибки вместо
/// подсказки.
Future<String?> showOrderOptionTextPrompt({
  required BuildContext context,
  required String title,
  required String label,
  String initial = '',
  String confirmLabel = 'Сохранить',
  String? hint,
}) =>
    showDialog<String>(
      context: context,
      builder: (_) => _TextPromptDialog(
        title: title,
        label: label,
        initial: initial,
        confirmLabel: confirmLabel,
        hint: hint,
      ),
    );

class _TextPromptDialog extends StatefulWidget {
  const _TextPromptDialog({
    required this.title,
    required this.label,
    required this.initial,
    required this.confirmLabel,
    this.hint,
  });

  final String title;
  final String label;
  final String initial;
  final String confirmLabel;
  final String? hint;

  @override
  State<_TextPromptDialog> createState() => _TextPromptDialogState();
}

class _TextPromptDialogState extends State<_TextPromptDialog> {
  late final TextEditingController _text =
      TextEditingController(text: widget.initial);

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  void _submit() {
    final value = _text.text.trim();
    if (value.isEmpty) return;
    Navigator.pop(context, value);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.title),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          TextField(
            controller: _text,
            autofocus: true,
            textInputAction: TextInputAction.done,
            onChanged: (_) => setState(() {}),
            onSubmitted: (_) => _submit(),
            decoration: InputDecoration(labelText: widget.label),
          ),
          if (widget.hint != null) ...[
            const SizedBox(height: 10),
            Text(
              widget.hint!,
              style: const TextStyle(fontSize: 12, color: PtColors.mutedStrong),
            ),
          ],
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Отмена'),
        ),
        FilledButton(
          onPressed: _text.text.trim().isEmpty ? null : _submit,
          child: Text(widget.confirmLabel),
        ),
      ],
    );
  }
}

/// Подтверждение снятия с учёта.
Future<bool> showOrderOptionConfirm({
  required BuildContext context,
  required String title,
  required String message,
  String confirmLabel = 'Удалить',
}) async {
  final result = await showDialog<bool>(
    context: context,
    builder: (_) => AlertDialog(
      title: Text(title),
      content: Text(message),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: const Text('Отмена'),
        ),
        FilledButton(
          style: FilledButton.styleFrom(backgroundColor: PtColors.danger),
          onPressed: () => Navigator.pop(context, true),
          child: Text(confirmLabel),
        ),
      ],
    ),
  );
  return result == true;
}

/// Что техлид задал новой опции.
class NewOrderOptionRequest {
  const NewOrderOptionRequest({required this.title, required this.kind});

  final String title;
  final String kind;
}

/// Название и тип выбора. Тип спрашивается один раз при создании: сменить его
/// у заведённой опции редактор не даёт — у опции Да/Нет вариантов не бывает,
/// и смена типа означала бы либо удаление вариантов, либо опцию списком без
/// единого варианта. Нужен другой тип — заводится другая опция.
Future<NewOrderOptionRequest?> showNewOrderOptionDialog(
  BuildContext context,
) =>
    showDialog<NewOrderOptionRequest>(
      context: context,
      builder: (_) => const _NewOptionDialog(),
    );

class _NewOptionDialog extends StatefulWidget {
  const _NewOptionDialog();

  @override
  State<_NewOptionDialog> createState() => _NewOptionDialogState();
}

class _NewOptionDialogState extends State<_NewOptionDialog> {
  final TextEditingController _title = TextEditingController();
  String _kind = kOrderOptionKindBoolean;

  @override
  void dispose() {
    _title.dispose();
    super.dispose();
  }

  void _submit() {
    final title = _title.text.trim();
    if (title.isEmpty) return;
    Navigator.pop(
      context,
      NewOrderOptionRequest(title: title, kind: _kind),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Новая опция'),
      content: SizedBox(
        width: 380,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(
              controller: _title,
              autofocus: true,
              onChanged: (_) => setState(() {}),
              onSubmitted: (_) => _submit(),
              decoration: const InputDecoration(
                labelText: 'Название',
                hintText: 'Например: Ламинация',
              ),
            ),
            const SizedBox(height: 12),
            const PtSectionHeader(
              icon: Icons.tune,
              label: 'Тип выбора',
            ),
            RadioListTile<String>(
              value: kOrderOptionKindBoolean,
              groupValue: _kind,
              onChanged: (value) => setState(() => _kind = value!),
              contentPadding: EdgeInsets.zero,
              dense: true,
              title: const Text('Да / Нет'),
              subtitle: const Text('Два варианта, менять их не нужно'),
            ),
            RadioListTile<String>(
              value: kOrderOptionKindSelect,
              groupValue: _kind,
              onChanged: (value) => setState(() => _kind = value!),
              contentPadding: EdgeInsets.zero,
              dense: true,
              title: const Text('Выбор из списка'),
              subtitle: const Text('Варианты задаются после создания'),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Отмена'),
        ),
        FilledButton(
          onPressed: _title.text.trim().isEmpty ? null : _submit,
          child: const Text('Создать'),
        ),
      ],
    );
  }
}

/// Редактор вариантов одной опции: добавить, переименовать, удалить, порядок.
///
/// Возвращает `true`, если справочник менялся, — вызывающий экран по этому
/// признаку перечитывает список.
///
/// Вариантов на экране только действующие. Снятые с учёта не показываются:
/// техлиду они не нужны (вернуть вариант — значит завести его заново), а
/// форма заказа поднимает их сама, когда такой вариант где-то выбран.
class OrderOptionValuesDialog extends StatefulWidget {
  const OrderOptionValuesDialog({
    super.key,
    required this.option,
    required this.repository,
  });

  final OrderOptionDef option;
  final OrderExtraOptionsRepository repository;

  @override
  State<OrderOptionValuesDialog> createState() =>
      _OrderOptionValuesDialogState();
}

class _OrderOptionValuesDialogState extends State<OrderOptionValuesDialog> {
  late List<OrderOptionValue> _values = widget.option.values
      .where((value) => value.isActive)
      .toList(growable: true);

  bool _busy = false;
  bool _changed = false;
  String? _error;

  /// Перечитывает варианты этой опции.
  ///
  /// Дёргает загрузку всего типа продукта: опций у типа единицы, отдельный
  /// запрос ради одной строки не окупает второго пути чтения, который пришлось
  /// бы поддерживать наравне с основным.
  Future<void> _reload() async {
    final defs =
        await widget.repository.loadForProductType(widget.option.productTypeId);
    final fresh = defs.where((def) => def.id == widget.option.id).firstOrNull;
    if (!mounted) return;
    setState(() {
      _values = (fresh?.values ?? const <OrderOptionValue>[])
          .where((value) => value.isActive)
          .toList(growable: true);
    });
  }

  /// Выполняет правку и перечитывает список; отказ показывает словами.
  Future<void> _run(Future<void> Function() action) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await action();
      _changed = true;
      await _reload();
    } on OrderExtraOptionsFailure catch (e) {
      if (mounted) setState(() => _error = e.message);
    } catch (e) {
      if (mounted) setState(() => _error = 'Не удалось сохранить: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _add() async {
    final title = await showOrderOptionTextPrompt(
      context: context,
      title: 'Новый вариант',
      label: 'Название варианта',
      confirmLabel: 'Добавить',
    );
    if (title == null) return;
    await _run(() => widget.repository.createValue(
          optionId: widget.option.id,
          title: title,
          sortOrder: _values.length * OrderExtraOptionsRepository.orderStep,
        ));
  }

  Future<void> _rename(OrderOptionValue value) async {
    final title = await showOrderOptionTextPrompt(
      context: context,
      title: 'Переименовать вариант',
      label: 'Название варианта',
      initial: value.title,
      hint: 'В заказах, где вариант уже выбран, останется прежнее название.',
    );
    if (title == null || title == value.title) return;
    await _run(
        () => widget.repository.renameValue(id: value.id, title: title));
  }

  Future<void> _delete(OrderOptionValue value) async {
    final ok = await showOrderOptionConfirm(
      context: context,
      title: 'Удалить вариант?',
      message: '«${value.title}» исчезнет из списка при создании новых '
          'заказов. В заказах, где его уже выбрали, значение останется.',
    );
    if (!ok) return;
    await _run(() => widget.repository.retireValue(value.id));
  }

  Future<void> _reorder(int oldIndex, int newIndex) async {
    if (newIndex > oldIndex) newIndex -= 1;
    final moved = List<OrderOptionValue>.from(_values);
    moved.insert(newIndex, moved.removeAt(oldIndex));
    setState(() => _values = moved);
    await _run(() => widget.repository
        .saveValueOrder(moved.map((value) => value.id).toList()));
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text('Варианты: ${widget.option.title}'),
      content: SizedBox(
        width: 420,
        height: 420,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (_error != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Text(
                  _error!,
                  style: const TextStyle(color: PtColors.danger, fontSize: 12),
                ),
              ),
            Expanded(
              child: _values.isEmpty
                  ? const Center(
                      child: Text(
                        'Вариантов пока нет.\nПока их нет, опция в заказе не '
                        'показывается.',
                        textAlign: TextAlign.center,
                        style: TextStyle(color: PtColors.mutedStrong),
                      ),
                    )
                  : ReorderableListView.builder(
                      buildDefaultDragHandles: false,
                      itemCount: _values.length,
                      onReorder: _busy ? (_, __) {} : _reorder,
                      itemBuilder: (context, index) {
                        final value = _values[index];
                        return _valueRow(value, index);
                      },
                    ),
            ),
            const SizedBox(height: 8),
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                onPressed: _busy ? null : _add,
                icon: const Icon(Icons.add),
                label: const Text('Добавить вариант'),
              ),
            ),
          ],
        ),
      ),
      actions: [
        FilledButton(
          onPressed: () => Navigator.pop(context, _changed),
          child: const Text('Готово'),
        ),
      ],
    );
  }

  Widget _valueRow(OrderOptionValue value, int index) {
    return Container(
      key: ValueKey<String>(value.id),
      margin: const EdgeInsets.only(bottom: 6),
      decoration: BoxDecoration(
        color: PtColors.cardIdle,
        border: Border.all(color: PtColors.border),
        borderRadius: BorderRadius.circular(PtMetrics.cardRadius),
      ),
      child: Row(
        children: [
          ReorderableDragStartListener(
            index: index,
            child: const Padding(
              padding: EdgeInsets.all(10),
              child: Icon(Icons.drag_indicator, size: 18, color: PtColors.muted),
            ),
          ),
          Expanded(
            child: Text(value.title,
                style: const TextStyle(fontSize: 13, color: PtColors.text)),
          ),
          IconButton(
            tooltip: 'Переименовать',
            icon: const Icon(Icons.edit_outlined, size: 18),
            onPressed: _busy ? null : () => _rename(value),
          ),
          IconButton(
            tooltip: 'Удалить',
            icon: const Icon(Icons.delete_outline, size: 18),
            color: PtColors.danger,
            onPressed: _busy ? null : () => _delete(value),
          ),
        ],
      ),
    );
  }
}
