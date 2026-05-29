import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../personnel/personnel_provider.dart';
import '../services/analytics_permission_service.dart';
import '../services/analytics_service.dart';
import '../utils/analytics_colors.dart';
import '../widgets/analytics_states.dart';
import '../widgets/workplaces_table.dart';
import 'workplace_detail_screen.dart';

class WorkplacesAnalyticsScreen extends StatefulWidget {
  const WorkplacesAnalyticsScreen({
    super.key,
    required this.service,
    required this.permission,
  });

  final AnalyticsService service;
  final AnalyticsPermissionService permission;

  @override
  State<WorkplacesAnalyticsScreen> createState() =>
      _WorkplacesAnalyticsScreenState();
}

class _WorkplacesAnalyticsScreenState extends State<WorkplacesAnalyticsScreen> {
  late final ScrollController _scrollController;

  @override
  void initState() {
    super.initState();
    _scrollController = ScrollController();
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: widget.service,
      builder: (context, _) {
        final state = widget.service.state;
        if (state.loading) {
          return const AnalyticsLoadingState();
        }
        if (state.error != null) {
          return AnalyticsErrorState(
            message:
                'Не удалось загрузить аналитику рабочих мест.\n${state.error}',
            onRetry: () => widget.service.refresh(),
          );
        }

        final personnel = context.read<PersonnelProvider>();
        if (personnel.workplaces.isEmpty) {
          return const AnalyticsEmptyState(
            icon: Icons.precision_manufacturing_outlined,
            message: 'Нет рабочих мест для отображения аналитики.',
          );
        }

        return _AnalyticsTableCard(
          controller: _scrollController,
          child: WorkplacesTable(
            service: widget.service,
            personnel: personnel,
            canEditCoefficient: widget.permission.canEdit,
            onWorkplaceTap: (id) {
              Navigator.of(context).push(MaterialPageRoute(
                builder: (_) => WorkplaceDetailScreen(
                  service: widget.service,
                  permission: widget.permission,
                  workplaceId: id,
                ),
              ));
            },
          ),
        );
      },
    );
  }
}

class _AnalyticsTableCard extends StatelessWidget {
  const _AnalyticsTableCard({
    required this.controller,
    required this.child,
  });

  final ScrollController controller;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      child: Container(
        decoration: BoxDecoration(
          color: AnalyticsColors.card,
          borderRadius: BorderRadius.circular(22),
          border: Border.all(color: AnalyticsColors.line),
        ),
        clipBehavior: Clip.antiAlias,
        child: Scrollbar(
          controller: controller,
          thumbVisibility: true,
          child: SingleChildScrollView(
            controller: controller,
            primary: false,
            child: child,
          ),
        ),
      ),
    );
  }
}
