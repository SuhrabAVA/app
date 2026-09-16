/// Редактор дополнительных опций заказа.
///
/// Опции заводит техлид, а не программист: в форме заказа блок «Дополнительные
/// опции» строится по этому справочнику. Правка действует сразу — версий и
/// черновиков, как у настроек типа продукта, здесь нет (почему — в шапке
/// миграции 20260910_order_extra_options.sql).
///
/// Экран отдельный, а не вкладка в ProductTypeSettingsShell, именно поэтому:
/// в той оболочке всё живёт по модели «правь черновик, потом публикуй», и
/// вкладка с немедленной записью читалась бы как ошибка.
library;

import 'package:flutter/material.dart';

import '../orders/order_extra_options.dart';
import '../orders/order_extra_options_repository.dart';
import '../orders/product_type_settings.dart';
import 'order_option_dialogs.dart';
import 'personnel_list_controls.dart';
import 'personnel_list_filters.dart';
import 'product_type_design.dart';

class OrderOptionsScreen extends StatefulWidget {
  const OrderOptionsScreen({super.key});

  @override
  State<OrderOptionsScreen> createState() => _OrderOptionsScreenState();
}

class _OrderOptionsScreenState extends State<OrderOptionsScreen> {
  final OrderExtraOptionsRepository _repo = OrderExtraOptionsRepository();

  List<ProductTypeRef> _types = const <ProductTypeRef>[];
  ProductTypeRef? _selected;
  List<OrderOptionDef> _options = const <OrderOptionDef>[];

  bool _loading = true;
  bool _busy = false;
  String? _error;

  final OrderOptionListFilter _filter = OrderOptionListFilter();
  final TextEditingController _search = TextEditingController();

  @override
  void initState() {
    super.initState();
    _loadTypes();
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  void _reset() {
    _search.clear();
    setState(_filter.clear);
  }

  Future<void> _loadTypes() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      await ProductTypeSettings.instance.ensureLoaded();
      final types = ProductTypeSettings.instance.productTypes;
      if (!mounted) return;
      setState(() {
        _types = types;
        _selected = types.isEmpty ? null : types.first;
      });
      await _loadOptions();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = 'Не удалось загрузить типы продукта: $e';
        _loading = false;
      });
    }
  }

  Future<void> _loadOptions() async {
    final type = _selected;
    if (type == null) {
      setState(() {
        _options = const <OrderOptionDef>[];
        _loading = false;
      });
      return;
    }
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final options = await _repo.loadForProductType(type.id);
      if (!mounted) return;
      setState(() {
        _options = options;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = 'Не удалось загрузить опции: $e';
        _loading = false;
      });
    }
  }

  /// Выполняет правку и перечитывает список; отказ показывает словами.
  Future<void> _run(Future<void> Function() action) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await action();
      await _loadOptions();
    } on OrderExtraOptionsFailure catch (e) {
      if (mounted) setState(() => _error = e.message);
    } catch (e) {
      if (mounted) setState(() => _error = 'Не удалось сохранить: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _addOption() async {
    final type = _selected;
    if (type == null) return;
    final request = await showNewOrderOptionDialog(context);
    if (request == null) return;
    await _run(() => _repo.createOption(
          productTypeId: type.id,
          title: request.title,
          kind: request.kind,
          sortOrder: _options.length * OrderExtraOptionsRepository.orderStep,
        ));
  }

  Future<void> _renameOption(OrderOptionDef option) async {
    final title = await showOrderOptionTextPrompt(
      context: context,
      title: 'Переименовать опцию',
      label: 'Название опции',
      initial: option.title,
      hint: 'В заказах, где значение уже выбрано, останется прежнее название.',
    );
    if (title == null || title == option.title) return;
    await _run(() => _repo.renameOption(id: option.id, title: title));
  }

  Future<void> _deleteOption(OrderOptionDef option) async {
    final ok = await showOrderOptionConfirm(
      context: context,
      title: 'Удалить опцию?',
      message: '«${option.title}» исчезнет из формы новых заказов. В заказах, '
          'где значение уже выбрано, оно останется видимым.',
    );
    if (!ok) return;
    await _run(() => _repo.retireOption(option.id));
  }

  Future<void> _editValues(OrderOptionDef option) async {
    final changed = await showDialog<bool>(
      context: context,
      builder: (_) => OrderOptionValuesDialog(
        option: option,
        repository: _repo,
      ),
    );
    if (changed == true) await _loadOptions();
  }

  Future<void> _reorder(int oldIndex, int newIndex) async {
    if (newIndex > oldIndex) newIndex -= 1;
    final moved = List<OrderOptionDef>.from(_options);
    moved.insert(newIndex, moved.removeAt(oldIndex));
    setState(() => _options = moved);
    await _run(
        () => _repo.saveOptionOrder(moved.map((def) => def.id).toList()));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: PtColors.background,
      appBar: AppBar(
        title: const Text('Редактор опций'),
        actions: [
          IconButton(
            tooltip: 'Обновить',
            onPressed: _loading || _busy ? null : _loadOptions,
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      floatingActionButton: _selected == null
          ? null
          : FloatingActionButton.extended(
              onPressed: _busy ? null : _addOption,
              icon: const Icon(Icons.add),
              label: const Text('Добавить опцию'),
            ),
      body: Padding(
        padding: const EdgeInsets.all(PtMetrics.pagePadding),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _buildHeader(),
            if (_error != null) ...[
              const SizedBox(height: 10),
              Text(
                _error!,
                style: const TextStyle(color: PtColors.danger, fontSize: 12),
              ),
            ],
            const SizedBox(height: 14),
            Expanded(child: _buildBody()),
          ],
        ),
      ),
    );
  }

  Widget _buildHeader() {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: PtColors.surface,
        border: Border.all(color: PtColors.border),
        borderRadius: BorderRadius.circular(PtMetrics.cardRadius),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const PtSectionHeader(
            icon: Icons.category_outlined,
            label: 'Тип продукта',
          ),
          DropdownButtonFormField<String>(
            initialValue: _selected?.id,
            isExpanded: true,
            decoration: const InputDecoration(
              isDense: true,
              border: OutlineInputBorder(),
            ),
            items: [
              for (final type in _types)
                DropdownMenuItem<String>(
                  value: type.id,
                  child: Text(type.title),
                ),
            ],
            onChanged: _busy
                ? null
                : (id) {
                    final next =
                        _types.where((type) => type.id == id).firstOrNull;
                    if (next == null) return;
                    setState(() => _selected = next);
                    _loadOptions();
                  },
          ),
          const SizedBox(height: 10),
          const Text(
            'Опции показываются в заказе отдельным блоком под «Бобинорезкой» '
            'и на маршрут не влияют. Заводить здесь «Тип ручки» не нужно: '
            'ручка уже есть в форме отдельным полем, и только она управляет '
            'этапами.',
            style: TextStyle(fontSize: 12, color: PtColors.mutedStrong),
          ),
        ],
      ),
    );
  }

  Widget _buildBody() {
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_types.isEmpty) {
      return const Center(child: Text('Типы продукта не заведены.'));
    }
    if (_options.isEmpty) {
      return const Center(
        child: Text(
          'У этого типа продукта опций пока нет.',
          style: TextStyle(color: PtColors.mutedStrong),
        ),
      );
    }

    final visible = _options.where(_filter.matches).toList();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        PersonnelFilterBar(
          controller: _search,
          hint: 'Опция или её вариант…',
          onQueryChanged: (v) => setState(() => _filter.query = v),
          shown: visible.length,
          total: _options.length,
          isActive: _filter.isActive,
          onReset: _reset,
          // Перестановка по отфильтрованному списку перемешала бы порядок
          // скрытых опций: номер строки на экране ≠ место в полном списке.
          note: _filter.isActive
              ? 'Пока включены поиск или фильтр, порядок не меняется.'
              : null,
          filters: [
            MultiSelectFilterChip(
              label: 'Вид',
              options: const [
                FilterOption(kOrderOptionKindBoolean, 'Да / Нет'),
                FilterOption(kOrderOptionKindSelect, 'Список вариантов'),
              ],
              selected: _filter.kinds,
              onChanged: (ids) => setState(() => _filter.kinds
                ..clear()
                ..addAll(ids)),
            ),
          ],
        ),
        Expanded(
          child: visible.isEmpty
              ? PersonnelEmptyResult(
                  isFiltered: true,
                  emptyText: '',
                  onReset: _reset,
                )
              : _filter.isActive
                  ? ListView.builder(
                      itemCount: visible.length,
                      itemBuilder: (context, index) =>
                          _optionCard(visible[index], index, draggable: false),
                    )
                  : ReorderableListView.builder(
                      buildDefaultDragHandles: false,
                      itemCount: _options.length,
                      onReorder: _busy ? (_, __) {} : _reorder,
                      itemBuilder: (context, index) =>
                          _optionCard(_options[index], index),
                    ),
        ),
      ],
    );
  }

  Widget _optionCard(
    OrderOptionDef option,
    int index, {
    bool draggable = true,
  }) {
    return Container(
      key: ValueKey<String>(option.id),
      margin: const EdgeInsets.only(bottom: PtMetrics.gap),
      padding: const EdgeInsets.symmetric(vertical: 4),
      decoration: BoxDecoration(
        color: PtColors.surface,
        border: Border.all(color: PtColors.border),
        borderRadius: BorderRadius.circular(PtMetrics.cardRadius),
      ),
      child: Row(
        children: [
          if (draggable)
            ReorderableDragStartListener(
              index: index,
              child: const Padding(
                padding: EdgeInsets.all(12),
                child: Icon(Icons.drag_indicator,
                    size: 18, color: PtColors.muted),
              ),
            )
          else
            const SizedBox(width: 12),
          Icon(
            option.isBoolean ? Icons.rule : Icons.list_alt_outlined,
            size: 18,
            color: PtColors.primary,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  option.title,
                  style: const TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    color: PtColors.text,
                  ),
                ),
                const SizedBox(height: 2),
                _optionSummary(option),
              ],
            ),
          ),
          if (option.isSelect)
            TextButton.icon(
              onPressed: _busy ? null : () => _editValues(option),
              icon: const Icon(Icons.edit_note, size: 18),
              label: const Text('Варианты'),
            ),
          PopupMenuButton<String>(
            enabled: !_busy,
            tooltip: 'Действия',
            onSelected: (action) {
              if (action == 'rename') _renameOption(option);
              if (action == 'delete') _deleteOption(option);
            },
            itemBuilder: (_) => const [
              PopupMenuItem<String>(
                value: 'rename',
                child: Text('Переименовать'),
              ),
              PopupMenuItem<String>(
                value: 'delete',
                child: Text('Удалить'),
              ),
            ],
          ),
        ],
      ),
    );
  }

  /// Подпись под названием: чем эта опция окажется в форме заказа.
  Widget _optionSummary(OrderOptionDef option) {
    if (option.isBoolean) {
      return const Text(
        'Да / Нет',
        style: TextStyle(fontSize: 12, color: PtColors.mutedStrong),
      );
    }

    final titles = option.values
        .where((value) => value.isActive)
        .map((value) => value.title)
        .toList();
    if (titles.isEmpty) {
      return const Text(
        'Вариантов нет — в заказе не показывается',
        style: TextStyle(fontSize: 12, color: PtColors.warnText),
      );
    }
    return Text(
      titles.join(' · '),
      maxLines: 2,
      overflow: TextOverflow.ellipsis,
      style: const TextStyle(fontSize: 12, color: PtColors.mutedStrong),
    );
  }
}
