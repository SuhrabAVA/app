import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../common/pulsing_dot.dart';
import '../orders/id_format.dart';
import '../orders/order_model.dart';
import '../orders/orders_provider.dart';
import '../personnel/personnel_provider.dart';
import '../tasks/task_provider.dart';
import '../tasks/workspace_design.dart';
import 'production_details_screen.dart';
import 'production_issues.dart';

/// Доска проблем: всё, что на производстве требует вмешательства.
///
/// Занимает главный экран панели администратора вместо пустого места справа от
/// кнопок модулей. Смысл простой: чтобы узнать, где встало, раньше надо было
/// открыть МУПЗ, пролистать заказы и заглянуть в каждый. Теперь список сам
/// показывает то, ради чего туда и заходят: разошедшееся количество,
/// остановленные этапы, заказы без материала и просроченные — те, у которых
/// срок прошёл, а последний этап ещё не закрыт.
///
/// Что считать проблемой, решает [collectProductionIssues] — здесь только
/// показ, фильтры и переход в карточку заказа.
class ProblemsBoard extends StatefulWidget {
  const ProblemsBoard({super.key, this.canManageProduction = true});

  /// Разрешить действия с этапами в открытой карточке заказа.
  final bool canManageProduction;

  @override
  State<ProblemsBoard> createState() => _ProblemsBoardState();
}

class _ProblemsBoardState extends State<ProblemsBoard> {
  /// Пусто — показываем все поводы. Иначе только отмеченные.
  final Set<ProductionIssueKind> _kinds = <ProductionIssueKind>{};

  /// Только красное: когда горит несколько заказов, жёлтое мешает читать.
  bool _dangerOnly = false;

  String _search = '';

  @override
  Widget build(BuildContext context) {
    final orders = context.watch<OrdersProvider>();
    final tasks = context.watch<TaskProvider>();
    final personnel = context.watch<PersonnelProvider>();

    final issues = collectProductionIssues(
      orders: orders.orders,
      tasks: tasks.tasks,
      stageMeta: (stageId) {
        final workplace = personnel.workplaceById(stageId);
        return StageMeta(
          name: workplace?.name.trim().isNotEmpty == true
              ? workplace!.name.trim()
              : 'Этап',
          unit: workplace?.unit,
          splitByTime: workplace?.splitQuantityByTime ?? true,
        );
      },
    );

    final visible = issues.where((issue) {
      if (_dangerOnly && issue.severity != IssueSeverity.danger) return false;
      if (_kinds.isNotEmpty && !_kinds.contains(issue.kind)) return false;
      final query = _search.trim().toLowerCase();
      if (query.isEmpty) return true;
      return issue.customer.toLowerCase().contains(query) ||
          orderDisplayId(issue.order).toLowerCase().contains(query) ||
          (issue.stageName ?? '').toLowerCase().contains(query);
    }).toList(growable: false);

    return Container(
      decoration: workspaceCardDecoration(),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _Header(issues: issues),
          _Filters(
            issues: issues,
            kinds: _kinds,
            dangerOnly: _dangerOnly,
            onToggleKind: (kind) => setState(() {
              if (!_kinds.remove(kind)) _kinds.add(kind);
            }),
            onToggleDanger: () => setState(() => _dangerOnly = !_dangerOnly),
            onSearch: (value) => setState(() => _search = value),
          ),
          const Divider(height: 1),
          if (visible.isNotEmpty) const _TableHeader(),
          Expanded(
            child: visible.isEmpty
                ? WorkspaceEmptyState(
                    icon: issues.isEmpty
                        ? Icons.check_circle_outline
                        : Icons.filter_alt_off_outlined,
                    title: issues.isEmpty
                        ? 'Проблем нет'
                        : 'Ничего не найдено',
                    message: issues.isEmpty
                        ? 'Количество сходится, этапы идут, материал на месте.'
                        : 'Снимите фильтры или измените запрос.',
                  )
                : ListView.separated(
                    padding: const EdgeInsets.symmetric(vertical: 6),
                    itemCount: visible.length,
                    separatorBuilder: (_, __) => const Divider(height: 1),
                    itemBuilder: (context, index) => _IssueTile(
                      issue: visible[index],
                      onOpen: () => _openOrder(visible[index].order),
                    ),
                  ),
          ),
        ],
      ),
    );
  }

  void _openOrder(OrderModel order) {
    // Та же карточка, что открывается из МУПЗ: детали, этапы, комментарии.
    showDialog<void>(
      context: context,
      barrierDismissible: true,
      builder: (_) => ProductionDetailsScreen(
        order: order,
        allowStageActions: widget.canManageProduction,
      ),
    );
  }
}

class _Header extends StatelessWidget {
  const _Header({required this.issues});

  final List<ProductionIssue> issues;

  @override
  Widget build(BuildContext context) {
    final danger =
        issues.where((i) => i.severity == IssueSeverity.danger).length;
    final warning = issues.length - danger;

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Требует внимания',
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w700,
                    color: WorkspaceColors.foreground,
                  ),
                ),
                SizedBox(height: 2),
                Text(
                  'Расхождения по количеству, остановленные этапы, материал '
                  'и просроченные заказы',
                  style: TextStyle(
                    fontSize: 12,
                    color: WorkspaceColors.mutedForeground,
                  ),
                ),
              ],
            ),
          ),
          if (danger > 0) ...[
            _Counter(
              value: danger,
              label: 'срочно',
              color: WorkspaceColors.danger,
            ),
            const SizedBox(width: 14),
          ],
          _Counter(
            value: warning,
            label: 'внимание',
            color: WorkspaceColors.warning,
          ),
        ],
      ),
    );
  }
}

class _Counter extends StatelessWidget {
  const _Counter({
    required this.value,
    required this.label,
    required this.color,
  });

  final int value;
  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.end,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          '$value',
          style: TextStyle(
            fontSize: 20,
            height: 1.1,
            fontWeight: FontWeight.w700,
            color: color,
          ),
        ),
        Text(
          label,
          style: const TextStyle(
            fontSize: 10.5,
            color: WorkspaceColors.mutedForeground,
          ),
        ),
      ],
    );
  }
}

class _Filters extends StatelessWidget {
  const _Filters({
    required this.issues,
    required this.kinds,
    required this.dangerOnly,
    required this.onToggleKind,
    required this.onToggleDanger,
    required this.onSearch,
  });

  final List<ProductionIssue> issues;
  final Set<ProductionIssueKind> kinds;
  final bool dangerOnly;
  final void Function(ProductionIssueKind) onToggleKind;
  final VoidCallback onToggleDanger;
  final ValueChanged<String> onSearch;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
      child: Wrap(
        spacing: 8,
        runSpacing: 8,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          for (final kind in ProductionIssueKind.values)
            _FilterChip(
              label: issueKindLabel(kind),
              // Счётчик рядом с фильтром: видно, есть ли смысл его включать.
              count: issues.where((i) => i.kind == kind).length,
              selected: kinds.contains(kind),
              onTap: () => onToggleKind(kind),
            ),
          _FilterChip(
            label: 'Только срочные',
            count: issues
                .where((i) => i.severity == IssueSeverity.danger)
                .length,
            selected: dangerOnly,
            color: WorkspaceColors.danger,
            onTap: onToggleDanger,
          ),
          SizedBox(
            width: 210,
            height: 34,
            child: TextField(
              onChanged: onSearch,
              style: const TextStyle(fontSize: 13),
              decoration: InputDecoration(
                isDense: true,
                hintText: 'Заказчик, номер, этап',
                hintStyle: const TextStyle(fontSize: 12.5),
                prefixIcon: const Icon(Icons.search, size: 17),
                prefixIconConstraints:
                    const BoxConstraints(minWidth: 32, minHeight: 32),
                contentPadding: const EdgeInsets.symmetric(vertical: 8),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(10),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _FilterChip extends StatelessWidget {
  const _FilterChip({
    required this.label,
    required this.count,
    required this.selected,
    required this.onTap,
    this.color = WorkspaceColors.primary,
  });

  final String label;
  final int count;
  final bool selected;
  final VoidCallback onTap;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: selected ? color.withValues(alpha: 0.12) : WorkspaceColors.surface,
      borderRadius: BorderRadius.circular(999),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(999),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(999),
            border: Border.all(
              color: selected
                  ? color.withValues(alpha: 0.45)
                  : WorkspaceColors.border,
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                label,
                style: TextStyle(
                  fontSize: 12.5,
                  fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
                  color:
                      selected ? color : WorkspaceColors.mutedForeground,
                ),
              ),
              const SizedBox(width: 6),
              Text(
                '$count',
                style: TextStyle(
                  fontSize: 11.5,
                  fontWeight: FontWeight.w700,
                  color: selected
                      ? color
                      : WorkspaceColors.disabledForeground,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Шапка таблицы. Доли столбцов повторяют [_IssueTile] — иначе заголовок
/// разъедется со строками при первой же правке одной из сторон.
class _TableHeader extends StatelessWidget {
  const _TableHeader();

  static const TextStyle _style = TextStyle(
    fontSize: 10,
    fontWeight: FontWeight.w700,
    letterSpacing: 0.6,
    color: WorkspaceColors.disabledForeground,
  );

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 6, 12, 6),
      color: WorkspaceColors.secondaryBackground,
      child: const Row(
        children: [
          SizedBox(width: 6 * 2.6 + 8),
          Expanded(flex: 26, child: Text('ЗАКАЗЧИК', style: _style)),
          SizedBox(width: 8),
          Expanded(flex: 22, child: Text('ГДЕ', style: _style)),
          SizedBox(width: 8),
          Expanded(flex: 20, child: Text('ЧТО', style: _style)),
          SizedBox(width: 8),
          Expanded(flex: 32, child: Text('ПОДРОБНОСТИ', style: _style)),
          SizedBox(width: 18),
        ],
      ),
    );
  }
}

class _IssueTile extends StatelessWidget {
  const _IssueTile({required this.issue, required this.onOpen});

  final ProductionIssue issue;
  final VoidCallback onOpen;

  Color get _color => issue.severity == IssueSeverity.danger
      ? WorkspaceColors.danger
      : WorkspaceColors.warning;

  /// Строка — одна линия таблицы: столбцы фиксированной доли, чтобы взгляд шёл
  /// вниз по колонке, а не прыгал. Вертикальная вёрстка на три строки давала
  /// полтора десятка проблем на экран; горизонтальная — вчетверо больше.
  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onOpen,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 7, 12, 7),
        child: Row(
          children: [
            PulsingDot(color: _color, size: 6),
            const SizedBox(width: 8),

            // Заказчик и номер.
            Expanded(
              flex: 26,
              child: Row(
                children: [
                  Flexible(
                    child: Text(
                      issue.customer.isEmpty ? 'Без заказчика' : issue.customer,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w700,
                        color: WorkspaceColors.foreground,
                      ),
                    ),
                  ),
                  const SizedBox(width: 6),
                  Text(
                    orderDisplayId(issue.order),
                    style: const TextStyle(
                      fontSize: 10.5,
                      color: WorkspaceColors.disabledForeground,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),

            // Повод и этап.
            Expanded(
              flex: 22,
              child: Align(
                alignment: Alignment.centerLeft,
                child: _Badge(
                  text: issue.stageName == null
                      ? issueKindLabel(issue.kind)
                      : '${issueKindLabel(issue.kind)} · ${issue.stageName}',
                  color: _color,
                ),
              ),
            ),
            const SizedBox(width: 8),

            // Суть.
            Expanded(
              flex: 20,
              child: Text(
                issue.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 12.5,
                  fontWeight: FontWeight.w600,
                  color: _color,
                ),
              ),
            ),
            const SizedBox(width: 8),

            // Подробность.
            Expanded(
              flex: 32,
              child: Text(
                issue.detail,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontSize: 12,
                  color: WorkspaceColors.mutedForeground,
                ),
              ),
            ),

            const Icon(
              Icons.chevron_right,
              size: 18,
              color: WorkspaceColors.disabledForeground,
            ),
          ],
        ),
      ),
    );
  }
}

class _Badge extends StatelessWidget {
  const _Badge({required this.text, required this.color});

  final String text;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        text,
        style: TextStyle(
          fontSize: 10.5,
          fontWeight: FontWeight.w700,
          color: color,
        ),
      ),
    );
  }
}
