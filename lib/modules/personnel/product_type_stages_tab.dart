import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../orders/product_type_route.dart';
import '../orders/product_type_settings.dart';
import '../orders/product_type_stage_guards.dart';
import 'product_type_add_stage_control.dart';
import 'product_type_formula_card.dart';
import 'product_type_problems_banner.dart';
import 'product_type_stage_actions.dart';
import 'product_type_stage_dialogs.dart';
import 'product_type_stage_row.dart';
import 'product_type_stage_workplaces_panel.dart';

/// Вкладка «Очередь этапов».
///
/// Здесь состояние и запись; отрисовка строки — в `product_type_stage_row.dart`,
/// панель рабочих мест — в `product_type_stage_workplaces_panel.dart`,
/// диалоги-предупреждения — в `product_type_stage_dialogs.dart`.
class ProductTypeStagesTab extends StatefulWidget {
  const ProductTypeStagesTab({
    super.key,
    required this.productType,
    required this.activeConfigId,
    required this.isDraft,
    this.focusStageId,
  });

  final ProductTypeRef productType;
  final String? activeConfigId;

  /// Есть ли черновик. Правки без него не бывает — её включает кнопка
  /// «Начать правку» в оболочке.
  final bool isDraft;

  /// Этап, к которому перешли со вкладки «Условия»: строку подсвечиваем и
  /// подводим к ней список.
  final String? focusStageId;

  @override
  State<ProductTypeStagesTab> createState() => _ProductTypeStagesTabState();
}

class _ProductTypeStagesTabState extends State<ProductTypeStagesTab> {
  final SupabaseClient _sb = Supabase.instance.client;
  late final ProductTypeStageActions _actions =
      ProductTypeStageActions(_sb);

  bool _loading = true;
  bool _busy = false;
  String? _error;
  ProductTypeRoute? _route;
  List<String> _problems = const <String>[];

  /// `actual_qty_formula` показанной версии. Настройка версии, а не этапа,
  /// поэтому в маршруте её нет и читается она отдельно.
  String? _formula;

  /// Раскрыта не больше одной панели рабочих мест за раз.
  String? _expandedStageId;

  /// Версия, ИЗ КОТОРОЙ реально загружен показанный маршрут.
  ///
  /// Ключевая защита: все записи адресуют строки по их id из `_route`, а эти
  /// id принадлежат конкретной версии. Пока перезагрузка после создания
  /// черновика не завершилась, в `_route` лежат строки ОПУБЛИКОВАННОЙ версии,
  /// и запись по ним ушла бы мимо черновика. Поэтому правку включаем только
  /// когда загруженная версия совпала с текущей и это черновик.
  String? _loadedConfigId;

  bool get _canEdit =>
      widget.isDraft &&
      !_loading &&
      !_busy &&
      _loadedConfigId != null &&
      _loadedConfigId == widget.activeConfigId;

  @override
  void initState() {
    super.initState();
    _load();
  }

  /// Ключ подсвеченной строки — только чтобы подвести к ней список после
  /// перехода со вкладки «Условия».
  final GlobalKey _focusKey = GlobalKey();

  @override
  void didUpdateWidget(covariant ProductTypeStagesTab oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.activeConfigId != widget.activeConfigId) _load();
    if (oldWidget.focusStageId != widget.focusStageId) _scrollToFocus();
  }

  void _scrollToFocus() {
    if (widget.focusStageId == null) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final context = _focusKey.currentContext;
      if (context == null) return;
      Scrollable.ensureVisible(context,
          duration: const Duration(milliseconds: 250), alignment: 0.2);
    });
  }

  Future<void> _load() async {
    final configId = widget.activeConfigId;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      if (configId == null) {
        if (!mounted) return;
        setState(() {
          _route = null;
          _loading = false;
        });
        return;
      }
      final route = await ProductTypeSettings.instance.loadRouteForConfig(
        configId: configId,
        productTypeId: widget.productType.id,
        title: widget.productType.title,
      );
      final problems = await _readProblems(configId);
      final config = await _sb
          .from('product_type_configs')
          .select('actual_qty_formula')
          .eq('id', configId)
          .single();
      if (!mounted) return;
      setState(() {
        _route = route;
        _problems = problems;
        _formula = config['actual_qty_formula']?.toString();
        _loadedConfigId = configId;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = 'Не удалось загрузить маршрут: $e';
        _loading = false;
      });
    }
  }

  /// Проблемы структуры показываем сразу после правки, а не при публикации:
  /// иначе техлид узнаёт о них через десять действий и уже не помнит, какое
  /// из них виновато.
  Future<List<String>> _readProblems(String configId) async {
    final rows = await _sb
        .rpc('validate_product_type_config', params: {'p_config_id': configId});
    return <String>[
      for (final row in (rows as List))
        (Map<String, dynamic>.from(row as Map)['message'] ?? '').toString(),
    ]..removeWhere((m) => m.isEmpty);
  }

  /// Все группы маршрута в порядке рангов — оба уровня в одном списке.
  ///
  /// Под-этапы вариантов показываются здесь же, а не только в панели варианта:
  /// раз перестановка идёт по общей последовательности, «вниз» иначе
  /// перепрыгивало бы невидимое. Панель отвечает на вопрос ЧЬЁ, список — ГДЕ.
  List<StageGroup> get _groups {
    final route = _route;
    if (route == null) return const <StageGroup>[];
    return stageGroupsOf(route);
  }

  List<StageGroup> get _movableGroups =>
      _groups.where((g) => !g.isPinned).toList(growable: false);

  int _indexOf(StageGroup group) =>
      _movableGroups.indexWhere((g) => g.position == group.position);

  /// Любая запись проходит через эту проверку.
  ///
  /// Контролы уже неактивны без черновика, но программный путь тоже не должен
  /// вести к записи по строкам чужой версии — это ровно тот дефект, ради
  /// которого правка включается отдельной кнопкой.
  Future<void> _write(
    Future<void> Function(String configId) action, {
    String? successMessage,
  }) async {
    final configId = widget.activeConfigId;
    if (!_canEdit || configId == null) return;
    setState(() => _busy = true);
    try {
      await action(configId);
      if (!mounted) return;
      setState(() => _busy = false);
      if (successMessage != null) _showInfo(successMessage);
      await _load();
    } catch (e) {
      if (!mounted) return;
      setState(() => _busy = false);
      _showError('$e');
    }
  }

  void _showError(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), backgroundColor: Colors.red.shade700),
    );
  }

  void _showInfo(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  // ── Перестановка ──────────────────────────────────────────────────────────

  /// Проверяем ход заранее, чтобы кнопка была неактивной с подсказкой, а не
  /// отказывала молча после нажатия.
  StageGroupReorder? _reorderFor(StageGroup group, int delta) {
    final route = _route;
    if (route == null) return null;
    return reorderStageGroups(route,
        groupIndex: _indexOf(group), delta: delta);
  }

  Future<void> _move(StageGroup group, int delta) async {
    final reorder = _reorderFor(group, delta);
    if (reorder == null || !reorder.isAllowed) return;

    await _write((configId) =>
        _actions.setPositions(configId, reorder.orderedGroups));
  }

  // ── Этап ──────────────────────────────────────────────────────────────────

  Future<void> _toggleEnabled(RouteStage stage, bool value) async {
    await _write((_) => _actions.setEnabled(stage, value));
  }

  /// Блокировка удаления считается по уже загруженному маршруту: без неё
  /// техлид получил бы голый отказ внешнего ключа (ON DELETE RESTRICT на
  /// parallel_with_stage_id) вместо имён зависимых этапов.
  String? _deleteBlockedReason(RouteStage stage) {
    final route = _route;
    if (route == null) return null;
    return stageDeleteBlockedReason(route, stage);
  }

  Future<void> _deleteStage(RouteStage stage) async {
    final confirmed = await confirmStageDeletion(context, stage: stage);
    if (!confirmed) return;
    await _write((_) => _actions.deleteStage(stage.rowId));
  }

  Future<void> _changeExecution(
    RouteStage stage,
    String mode,
    String? partnerRowId,
  ) async {
    await _write((_) => _actions.setExecution(stage.rowId, mode, partnerRowId));
  }

  Future<void> _setFormula(String formula) async {
    await _write((configId) => _actions.setFormula(configId, formula));
  }

  // ── Рабочие места ─────────────────────────────────────────────────────────

  Future<void> _addWorkplace(RouteStage stage, String workplaceId) async {
    final nextSortOrder = stage.workplaces.isEmpty
        ? 1
        : stage.workplaces
                .map((w) => w.sortOrder)
                .reduce((a, b) => a > b ? a : b) +
            1;
    await _write((_) => _actions.addWorkplace(
          stage: stage,
          workplaceId: workplaceId,
          // Для переключаемого этапа подпись варианта заполняем сразу именем
          // рабочего места — так же, как это делает смена режима.
          variantTitle: stage.isSwitchable
              ? ProductTypeSettings.instance.workplaceName(workplaceId)
              : null,
          sortOrder: nextSortOrder,
        ));
  }

  /// Обычный DELETE: он атомарен сам по себе, и каскад на под-этапы — его
  /// часть. Опасна была не потеря атомарности, а тишина, поэтому перечисление
  /// того, что уйдёт, показывает панель ДО вызова.
  Future<void> _removeWorkplace(RouteStageWorkplace workplace) async {
    await _write((_) => _actions.removeWorkplace(workplace.rowId));
  }

  Future<void> _setDefaultVariant(RouteStageWorkplace variant) async {
    await _write((_) => _actions.setDefaultVariant(variant.rowId));
  }

  Future<void> _changeSelectionMode(RouteStage stage, String targetMode) async {
    await _write((_) async {
      final count = await _actions.setSelectionMode(stage.rowId, targetMode);
      // Отчитываемся фактом из возврата функции, а не обещанием из диалога.
      if (count > 0 && mounted) _showInfo('Удалено под-этапов: $count');
    });
  }

  // ── Условие (Фаза A) ──────────────────────────────────────────────────────

  Future<void> _changeCondition(
    RouteStage stage,
    String? predicate,
    String? param,
  ) async {
    // Замена условия — DELETE плюс INSERT; между ними этап был бы «всегда».
    await _write((_) => _actions.setCondition(stage.rowId, predicate, param));
  }

  // ── Под-этапы вариантов (Фаза C) и добавление этапа (Фаза B) ──────────────

  /// Ранг нового этапа выдаёт сервер — см. `insert_product_type_stage`.
  ///
  /// Раньше он считался здесь как «максимум незакреплённых плюс один». После
  /// уплотнения рангов это ровно ранг упаковки: новый этап слипся бы с ней в
  /// одну группу и стал бы неперемещаемым. Сдвинуть упаковку тем же действием
  /// клиент не может — это два оператора.
  Future<void> _addSubStage(
    RouteStageWorkplace variant,
    String workplaceId,
  ) async {
    await _write((configId) async {
      await _actions.insertStage(
        configId: configId,
        stageGroupKey: workplaceId,
        title: ProductTypeSettings.instance.workplaceName(workplaceId),
        workplaceId: workplaceId,
        parentVariantId: variant.rowId,
      );
    });
  }

  Future<void> _deleteSubStage(RouteStage subStage) async {
    final route = _route;
    if (route == null) return;
    var variantTitle = '';
    for (final parent in route.stages) {
      for (final workplace in parent.workplaces) {
        if (workplace.rowId != subStage.parentVariantId) continue;
        variantTitle = workplace.variantTitle ??
            ProductTypeSettings.instance.workplaceName(workplace.workplaceId);
      }
    }
    final confirmed = await confirmSubStageDeletion(
      context,
      subStage: subStage,
      variantTitle: variantTitle,
    );
    if (!confirmed) return;
    await _write((_) => _actions.deleteStage(subStage.rowId));
  }

  Future<void> _copyFromVariant(
    RouteStageWorkplace from,
    RouteStageWorkplace to,
  ) async {
    await _write((_) async {
      final count =
          await _actions.copyVariantSubStages(from.rowId, to.rowId);
      // Функция пропускает под-этапы с уже занятым ключом, поэтому обещанное
      // и реальное могут не совпасть — отчитываемся фактом.
      if (mounted) {
        _showInfo(count == 0
            ? 'Копировать нечего: все под-этапы уже есть у варианта.'
            : 'Скопировано под-этапов: $count');
      }
    });
  }

  Future<void> _addWorkplaceStage(String workplaceId) async {
    await _write((configId) async {
      await _actions.insertStage(
        configId: configId,
        stageGroupKey: workplaceId,
        title: ProductTypeSettings.instance.workplaceName(workplaceId),
        workplaceId: workplaceId,
      );
    });
  }

  Future<void> _addGroupStage() async {
    final result = await promptGroupStage(context);
    if (result == null) return;
    await _write((configId) async {
      await _actions.insertStage(
        configId: configId,
        // Ключ группы генерируется один раз и при переименовании подписи НЕ
        // меняется: по нему группируют потребители и на него ссылаются планы.
        stageGroupKey: _generateGroupKey(),
        title: result.title,
        workplaceId: result.workplaceId,
      );
    });
  }

  String _generateGroupKey() {
    final hex = DateTime.now().microsecondsSinceEpoch.toRadixString(16);
    return 'grp_${hex.substring(hex.length - 8)}';
  }

  void _toggleWorkplaces(RouteStage stage) {
    setState(() {
      _expandedStageId = _expandedStageId == stage.rowId ? null : stage.rowId;
    });
  }

  // ── Отрисовка ─────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(_error!, textAlign: TextAlign.center),
              const SizedBox(height: 12),
              FilledButton(onPressed: _load, child: const Text('Повторить')),
            ],
          ),
        ),
      );
    }
    final route = _route;
    if (route == null) {
      return const Center(child: Text('У типа продукта нет версии настроек.'));
    }

    final rows = StageRowBuilder(
      route: route,
      locked: !_canEdit,
      expandedStageId: _expandedStageId,
      reorderFor: _reorderFor,
      onMove: (group, delta) => _move(group, delta),
      onToggleEnabled: (stage, value) => _toggleEnabled(stage, value),
      onDeleteStage: _deleteStage,
      deleteBlockedFor: _deleteBlockedReason,
      onToggleWorkplaces: _toggleWorkplaces,
      buildWorkplacesPanel: (stage, indent) => ProductTypeStageWorkplacesPanel(
        stage: stage,
        route: route,
        locked: !_canEdit,
        indent: indent,
        onAddWorkplace: (workplaceId) => _addWorkplace(stage, workplaceId),
        onRemoveWorkplace: _removeWorkplace,
        onSetDefaultVariant: _setDefaultVariant,
        onChangeSelectionMode: (mode) => _changeSelectionMode(stage, mode),
        onChangeCondition: (predicate, param) =>
            _changeCondition(stage, predicate, param),
        onChangeExecution: (mode, partnerRowId) =>
            _changeExecution(stage, mode, partnerRowId),
        onAddSubStage: _addSubStage,
        onDeleteSubStage: _deleteSubStage,
        onCopyFromVariant: _copyFromVariant,
      ),
    );

    return ListView(
      padding: const EdgeInsets.only(bottom: 24),
      children: [
        // Превью с переключателями условий убрано: очередь этапов ниже и так
        // показывает маршрут, а после того как заказ стал собираться этим же
        // маршрутом, отдельная «примерка» условий только дублировала экран.
        ProductTypeFormulaCard(
          formula: _formula,
          locked: !_canEdit,
          onChanged: _setFormula,
        ),
        ProductTypeProblemsBanner(problems: _problems),
        const Divider(height: 1),
        for (final group in _groups)
          if (group.stages.any((s) => s.rowId == widget.focusStageId))
            Container(
              key: _focusKey,
              color: const Color(0xFFFFF9E6),
              child: rows.build(context, group),
            )
          else
            rows.build(context, group),
        ProductTypeAddStageControl(
          route: route,
          locked: !_canEdit,
          onAddWorkplaceStage: _addWorkplaceStage,
          onAddGroupStage: _addGroupStage,
        ),
      ],
    );
  }
}
