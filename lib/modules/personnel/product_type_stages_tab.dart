import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../orders/product_type_route.dart';
import '../orders/product_type_settings.dart';
import 'product_type_stage_preview.dart';
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
  });

  final ProductTypeRef productType;
  final String? activeConfigId;

  /// Есть ли черновик. Правки без него не бывает — её включает кнопка
  /// «Начать правку» в оболочке.
  final bool isDraft;

  @override
  State<ProductTypeStagesTab> createState() => _ProductTypeStagesTabState();
}

class _ProductTypeStagesTabState extends State<ProductTypeStagesTab> {
  final SupabaseClient _sb = Supabase.instance.client;

  bool _loading = true;
  bool _busy = false;
  String? _error;
  ProductTypeRoute? _route;
  List<String> _problems = const <String>[];

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

  @override
  void didUpdateWidget(covariant ProductTypeStagesTab oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.activeConfigId != widget.activeConfigId) _load();
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
      if (!mounted) return;
      setState(() {
        _route = route;
        _problems = problems;
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

    await _write((configId) async {
      // Перенумерация всей последовательности групп одним заходом: раздельные
      // UPDATE оставили бы при обрыве два этапа на одной позиции, а раздача
      // позиций только уровню 0 сталкивала бы ручки с под-этапами вариантов.
      await _sb.rpc('set_product_type_stage_positions', params: {
        'p_config_id': configId,
        'p_ordered_groups': reorder.orderedGroups,
      });
    });
  }

  // ── Этап ──────────────────────────────────────────────────────────────────

  Future<void> _toggleEnabled(RouteStage stage, bool value) async {
    await _write((_) async {
      await _sb
          .from('product_type_stages')
          .update({'is_enabled': value}).eq('id', stage.rowId);
    });
  }

  Future<void> _deleteStage(RouteStage stage) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Удалить этап «${stage.title}»?'),
        content: const Text(
          'Вместе с этапом удалятся его рабочие места, условия и под-этапы '
          'вариантов.',
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Отмена')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Удалить')),
        ],
      ),
    );
    if (confirmed != true) return;
    await _write((_) async {
      await _sb.from('product_type_stages').delete().eq('id', stage.rowId);
    });
  }

  // ── Рабочие места ─────────────────────────────────────────────────────────

  Future<void> _addWorkplace(RouteStage stage, String workplaceId) async {
    final nextSortOrder = stage.workplaces.isEmpty
        ? 1
        : stage.workplaces
                .map((w) => w.sortOrder)
                .reduce((a, b) => a > b ? a : b) +
            1;
    await _write((_) async {
      await _sb.from('product_type_stage_workplaces').insert({
        'stage_id': stage.rowId,
        'workplace_id': workplaceId,
        // Для переключаемого этапа подпись варианта заполняем сразу именем
        // рабочего места — так же, как это делает смена режима.
        if (stage.isSwitchable)
          'variant_title':
              ProductTypeSettings.instance.workplaceName(workplaceId),
        'is_default': false,
        'sort_order': nextSortOrder,
      });
    });
  }

  /// Обычный DELETE: он атомарен сам по себе, и каскад на под-этапы — его
  /// часть. Опасна была не потеря атомарности, а тишина, поэтому перечисление
  /// того, что уйдёт, показывает панель ДО вызова.
  Future<void> _removeWorkplace(RouteStageWorkplace workplace) async {
    await _write((_) async {
      await _sb
          .from('product_type_stage_workplaces')
          .delete()
          .eq('id', workplace.rowId);
    });
  }

  Future<void> _setDefaultVariant(RouteStageWorkplace variant) async {
    await _write((_) async {
      await _sb.rpc('set_product_type_stage_default_variant',
          params: {'p_variant_id': variant.rowId});
    });
  }

  Future<void> _changeSelectionMode(RouteStage stage, String targetMode) async {
    await _write((_) async {
      final deleted = await _sb.rpc('set_product_type_stage_selection_mode',
          params: {'p_stage_id': stage.rowId, 'p_mode': targetMode});
      final count = (deleted as num?)?.toInt() ?? 0;
      // Отчитываемся фактом из возврата функции, а не обещанием из диалога.
      if (count > 0 && mounted) {
        _showInfo('Удалено под-этапов: $count');
      }
    });
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
      ),
    );

    return ListView(
      padding: const EdgeInsets.only(bottom: 24),
      children: [
        ProductTypeStagePreview(route: route),
        if (_problems.isNotEmpty) _buildProblems(),
        const Divider(height: 1),
        for (final group in _groups) rows.build(context, group),
      ],
    );
  }

  Widget _buildProblems() {
    return Container(
      width: double.infinity,
      color: const Color(0xFFFFEBEE),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Маршрут нельзя опубликовать:',
              style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: Colors.red.shade900)),
          for (final problem in _problems)
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Text('• $problem',
                  style: TextStyle(fontSize: 12, color: Colors.red.shade900)),
            ),
        ],
      ),
    );
  }
}
