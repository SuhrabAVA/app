import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../orders/product_type_route.dart';
import '../orders/product_type_settings.dart';
import '../orders/production_ids.dart';
import 'product_type_settings_shell.dart';
import 'product_type_stage_preview.dart';

/// Этапы, подпись которых задана системой.
///
/// Постобработка `normalizeBuiltOrderStageQueue` принудительно переименовывает
/// эти три этапа. Дай техлиду поле ввода — он переименует, увидит в очереди
/// прежнее имя и пойдёт искать баг. Поэтому подпись показываем, но не даём
/// править. Ключи берутся из реестра `production_ids.dart`, а не литералами.
const Set<String> kSystemNamedStageKeys = <String>{
  wpBobbinUuid,
  wpFlexPrintingUuid,
  wpPackagingUuid,
};

/// Вкладка «Очередь этапов».
///
/// Первый срез: список этапов уровня 0, перестановка, переключатель
/// «активен», удаление и превью слитой очереди. Рабочие места, варианты с
/// под-очередями и правка условий — следующими срезами.
class ProductTypeStagesTab extends StatefulWidget {
  const ProductTypeStagesTab({
    super.key,
    required this.productType,
    required this.activeConfigId,
    required this.isDraft,
    required this.ensureDraft,
  });

  final ProductTypeRef productType;
  final String? activeConfigId;
  final bool isDraft;
  final EnsureDraft ensureDraft;

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
  /// перепрыгивало бы невидимое. Панель варианта отвечает на вопрос ЧЬЁ,
  /// этот список — на вопрос ГДЕ.
  List<StageGroup> get _groups {
    final route = _route;
    if (route == null) return const <StageGroup>[];
    return stageGroupsOf(route);
  }

  /// Группы, которые техлид может двигать: закреплённая упаковка вне игры.
  List<StageGroup> get _movableGroups =>
      _groups.where((g) => !g.isPinned).toList(growable: false);

  Future<void> _write(Future<void> Function(String configId) action) async {
    setState(() => _busy = true);
    try {
      final configId = await widget.ensureDraft();
      await action(configId);
      if (!mounted) return;
      setState(() => _busy = false);
      await _load();
    } catch (e) {
      if (!mounted) return;
      setState(() => _busy = false);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('$e'),
        backgroundColor: Colors.red.shade700,
      ));
    }
  }

  /// Проверяем ход заранее, чтобы кнопка была неактивной с подсказкой, а не
  /// отказывала молча после нажатия.
  StageGroupReorder _reorderFor(int movableIndex, int delta) {
    final route = _route;
    if (route == null) {
      return const StageGroupReorder.blocked('Маршрут не загружен.');
    }
    return reorderStageGroups(route, groupIndex: movableIndex, delta: delta);
  }

  Future<void> _move(int movableIndex, int delta) async {
    final reorder = _reorderFor(movableIndex, delta);
    if (!reorder.isAllowed) return;

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

  Future<void> _toggleEnabled(RouteStage stage, bool value) async {
    await _write((_) async {
      await _sb
          .from('product_type_stages')
          .update({'is_enabled': value}).eq('id', stage.rowId);
    });
  }

  Future<void> _delete(RouteStage stage) async {
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
    if (_route == null) {
      return const Center(child: Text('У типа продукта нет версии настроек.'));
    }

    final groups = _groups;
    return ListView(
      padding: const EdgeInsets.only(bottom: 24),
      children: [
        ProductTypeStagePreview(route: _route!),
        if (_problems.isNotEmpty) _buildProblems(),
        const Divider(height: 1),
        for (final group in groups) _buildGroupRow(group),
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
                  style:
                      TextStyle(fontSize: 12, color: Colors.red.shade900)),
            ),
        ],
      ),
    );
  }

  /// Строка списка — ГРУППА ранга, а не этап.
  ///
  /// Группа из нескольких этапов рисуется свёрнутой: «Ручка — 3 варианта по
  /// типу ручки». Внутри группы порядка нет и быть не может, поэтому «вверх»
  /// у отдельного члена было бы бессмысленным жестом.
  Widget _buildGroupRow(StageGroup group) {
    final movable = _movableGroups;
    final index = movable.indexWhere((g) => g.position == group.position);
    final up = group.isPinned ? null : _reorderFor(index, -1);
    final down = group.isPinned ? null : _reorderFor(index, 1);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (group.stages.length == 1)
          _buildSingleStageTile(group, group.stages.first, up, down)
        else
          _buildBundleTile(group, up, down),
        const Divider(height: 1, indent: 16),
      ],
    );
  }

  Widget _buildSingleStageTile(
    StageGroup group,
    RouteStage stage,
    StageGroupReorder? up,
    StageGroupReorder? down,
  ) {
    return Opacity(
      opacity: stage.isEnabled ? 1 : 0.5,
      child: ListTile(
        contentPadding: EdgeInsets.only(
          left: group.isSubQueue ? 40 : 16,
          right: 8,
        ),
        leading: _positionBadge(group),
        title: Row(
          children: [
            Flexible(child: Text(stage.title)),
            if (kSystemNamedStageKeys.contains(stage.key)) _systemNameLock(),
            if (group.isSubQueue) ..._variantBadges(group),
          ],
        ),
        subtitle: Text(_stageSubtitle(stage),
            style: TextStyle(fontSize: 12, color: Colors.grey.shade600)),
        trailing: _rowActions(group, stage, up, down),
      ),
    );
  }

  /// Свёрнутая строка связки: раскрывается, чтобы править членов по отдельности.
  Widget _buildBundleTile(
    StageGroup group,
    StageGroupReorder? up,
    StageGroupReorder? down,
  ) {
    return Theme(
      data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
      child: ExpansionTile(
        tilePadding: EdgeInsets.only(
          left: group.isSubQueue ? 40 : 16,
          right: 8,
        ),
        leading: _positionBadge(group),
        title: Row(
          children: [
            Flexible(child: Text(_bundleTitle(group))),
            if (group.isSubQueue) ..._variantBadges(group),
          ],
        ),
        subtitle: Text(
          'Взаимоисключающие: в очередь попадёт не более одного',
          style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
        ),
        trailing: _rowActions(group, null, up, down),
        childrenPadding: EdgeInsets.only(
          left: group.isSubQueue ? 56 : 32,
          bottom: 4,
        ),
        children: [
          for (final stage in group.stages)
            Opacity(
              opacity: stage.isEnabled ? 1 : 0.5,
              child: ListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                title: Row(
                  children: [
                    Flexible(child: Text(stage.title)),
                    if (kSystemNamedStageKeys.contains(stage.key))
                      _systemNameLock(),
                  ],
                ),
                subtitle: Text(_stageSubtitle(stage),
                    style:
                        TextStyle(fontSize: 12, color: Colors.grey.shade600)),
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Switch(
                      value: stage.isEnabled,
                      onChanged:
                          _busy ? null : (v) => _toggleEnabled(stage, v),
                    ),
                    IconButton(
                      tooltip: 'Удалить этап',
                      icon: const Icon(Icons.delete_outline, size: 18),
                      onPressed: _busy ? null : () => _delete(stage),
                    ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }

  /// Подпись связки. Если все члены различаются одним и тем же предикатом,
  /// говорим об этом прямо — так техлиду видно, чем они переключаются.
  String _bundleTitle(StageGroup group) {
    final predicates = group.stages
        .expand((s) => s.conditions.map((c) => c.predicate))
        .toSet();
    if (predicates.length == 1 &&
        group.stages.every((s) => s.conditions.length == 1)) {
      final label = switch (predicates.first) {
        'handle_type_is' => 'Ручка',
        _ => 'Этап',
      };
      return '$label — ${group.stages.length} варианта по условию';
    }
    return '${group.stages.length} этапа на одном шаге';
  }

  Widget _positionBadge(StageGroup group) {
    return SizedBox(
      width: 34,
      child: Text('${group.position}',
          style: TextStyle(
              fontWeight: FontWeight.w600, color: Colors.grey.shade600)),
    );
  }

  Widget _systemNameLock() {
    return Padding(
      padding: const EdgeInsets.only(left: 6),
      child: Tooltip(
        message: 'Имя задано системой: сборка очереди всё равно вернёт его',
        child: Icon(Icons.lock_outline, size: 14, color: Colors.grey.shade500),
      ),
    );
  }

  /// Бейджи вариантов-владельцев у под-этапа: список отвечает на вопрос ГДЕ,
  /// бейдж — на вопрос ЧЬЁ.
  List<Widget> _variantBadges(StageGroup group) {
    final route = _route;
    if (route == null) return const <Widget>[];
    final titles = <String>[];
    for (final stage in group.stages) {
      for (final parent in route.stages) {
        for (final workplace in parent.workplaces) {
          if (workplace.rowId != stage.parentVariantId) continue;
          titles.add(workplace.variantTitle ??
              ProductTypeSettings.instance.workplaceName(workplace.workplaceId));
        }
      }
    }
    return [
      for (final title in titles)
        Padding(
          padding: const EdgeInsets.only(left: 6),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
            decoration: BoxDecoration(
              color: const Color(0xFFEFEAFF),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Text(title,
                style: const TextStyle(fontSize: 10, color: Color(0xFF5B21B6))),
          ),
        ),
    ];
  }

  Widget _rowActions(
    StageGroup group,
    RouteStage? single,
    StageGroupReorder? up,
    StageGroupReorder? down,
  ) {
    if (group.isPinned) {
      return Tooltip(
        message: 'Упаковка всегда завершает очередь: количество заказа '
            'пересчитывается после её завершения',
        child: Icon(Icons.push_pin_outlined,
            size: 18, color: Colors.grey.shade500),
      );
    }
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        _moveButton(Icons.arrow_upward, 'Выше', up, () => _move(_indexOf(group), -1)),
        _moveButton(
            Icons.arrow_downward, 'Ниже', down, () => _move(_indexOf(group), 1)),
        if (single != null) ...[
          Switch(
            value: single.isEnabled,
            onChanged: _busy ? null : (v) => _toggleEnabled(single, v),
          ),
          IconButton(
            tooltip: 'Удалить этап',
            icon: const Icon(Icons.delete_outline, size: 18),
            onPressed: _busy ? null : () => _delete(single),
          ),
        ],
      ],
    );
  }

  int _indexOf(StageGroup group) =>
      _movableGroups.indexWhere((g) => g.position == group.position);

  /// Невозможный ход показываем неактивной кнопкой с причиной в подсказке —
  /// молчаливый отказ после нажатия оставил бы техлида гадать.
  Widget _moveButton(
    IconData icon,
    String label,
    StageGroupReorder? reorder,
    VoidCallback onPressed,
  ) {
    final allowed = reorder?.isAllowed ?? false;
    return Tooltip(
      message: allowed ? label : (reorder?.blockedReason ?? label),
      child: IconButton(
        icon: Icon(icon, size: 18),
        onPressed: _busy || !allowed ? null : onPressed,
      ),
    );
  }


  String _stageSubtitle(RouteStage stage) {
    final parts = <String>[];
    if (stage.isSwitchable) {
      parts.add('вариантов: ${stage.workplaces.length}');
    } else {
      parts.add('РМ: ${stage.workplaces.length}');
    }
    if (stage.conditions.isEmpty) {
      parts.add('всегда');
    } else {
      parts.add('если: ${stage.conditions.map(_conditionLabel).join(' и ')}');
    }
    final subStages = _route?.stages
            .where((s) =>
                s.level == 1 &&
                stage.workplaces.any((w) => w.rowId == s.parentVariantId))
            .length ??
        0;
    if (subStages > 0) parts.add('под-этапов: $subStages');
    return parts.join(' · ');
  }

  String _conditionLabel(RouteCondition condition) {
    final base = switch (condition.predicate) {
      'has_paint' => 'есть краски',
      'has_cardboard' => 'есть картон',
      'has_trimming' => 'есть подрезка',
      'needs_bobbin_cutting' => 'заказ уже формата бумаги',
      'handle_type_is' => 'ручка ${condition.param ?? ''}',
      _ => condition.predicate,
    };
    return condition.negate ? 'не $base' : base;
  }
}
