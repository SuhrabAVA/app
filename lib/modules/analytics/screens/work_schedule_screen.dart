import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../personnel/personnel_provider.dart';
import '../services/analytics_pdf_export_service.dart';
import '../services/analytics_permission_service.dart';
import '../services/analytics_service.dart';
import '../utils/analytics_colors.dart';
import '../widgets/analytics_shell.dart';
import '../widgets/analytics_states.dart';
import '../widgets/schedule_grid.dart';

class WorkScheduleScreen extends StatefulWidget {
  const WorkScheduleScreen({
    super.key,
    required this.service,
    required this.permission,
  });

  final AnalyticsService service;
  final AnalyticsPermissionService permission;

  @override
  State<WorkScheduleScreen> createState() => _WorkScheduleScreenState();
}

class _WorkScheduleScreenState extends State<WorkScheduleScreen> {
  late final ScrollController _scrollController;
  final _pdfService = AnalyticsPdfExportService();
  bool _pdfLoading = false;

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

  Future<void> _exportPdf(PersonnelProvider personnel) async {
    if (_pdfLoading) return;
    setState(() => _pdfLoading = true);
    try {
      final path = await _pdfService.exportWorkSchedulePdf(
        service: widget.service,
        personnel: personnel,
      );
      if (!mounted || path == null) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('PDF сохранён: $path'),
          action: SnackBarAction(
            label: 'Открыть',
            onPressed: () => _pdfService.openPdfFile(path),
          ),
        ),
      );
    } catch (error, stackTrace) {
      debugPrint('Schedule PDF export failed: $error');
      debugPrintStack(stackTrace: stackTrace);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Не удалось создать PDF: $error')),
      );
    } finally {
      if (mounted) setState(() => _pdfLoading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: widget.service,
      builder: (context, _) {
        final state = widget.service.state;
        if (state.loading) {
          return const AnalyticsLoadingState(label: 'Загружаем график работы…');
        }
        if (state.error != null) {
          return AnalyticsErrorState(
            message: 'Не удалось загрузить график работы.\n${state.error}',
            onRetry: () => widget.service.refresh(),
          );
        }

        final personnel = context.read<PersonnelProvider>();
        final activeEmployees = personnel.employees.where((e) => !e.isFired);
        if (activeEmployees.isEmpty) {
          return const AnalyticsEmptyState(
            icon: Icons.calendar_month_outlined,
            message: 'Нет активных сотрудников для графика работы.',
          );
        }

        return _AnalyticsTableCard(
          controller: _scrollController,
          title: 'Графики работы',
          subtitle:
              'В каждой ячейке сверху время прихода, по центру день и тип смены, снизу время ухода. '
              'ЛКМ по числу переключает День → Ночь → Выходной, ПКМ по ячейке быстро открывает ввод времени прихода.',
          trailing: Wrap(
            spacing: 12,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              const _ScheduleLegend(),
              AnalyticsPdfButton(
                loading: _pdfLoading,
                onPressed: () => _exportPdf(personnel),
              ),
            ],
          ),
          child: ScheduleGrid(
            service: widget.service,
            personnel: personnel,
            canEdit: widget.permission.canEdit,
          ),
        );
      },
    );
  }
}

/// Легенда смен в шапке графика: День / Ночь / Выходной.
class _ScheduleLegend extends StatelessWidget {
  const _ScheduleLegend();

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 12,
      runSpacing: 6,
      children: const [
        _LegendItem(color: AnalyticsColors.yellow, label: 'День'),
        _LegendItem(color: AnalyticsColors.blackShift, label: 'Ночь'),
        _LegendItem(color: AnalyticsColors.gray, label: 'Выходной'),
      ],
    );
  }
}

class _LegendItem extends StatelessWidget {
  const _LegendItem({required this.color, required this.label});

  final Color color;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 13,
          height: 13,
          decoration: BoxDecoration(
            color: color,
            borderRadius: BorderRadius.circular(5),
            border: Border.all(color: AnalyticsColors.line),
          ),
        ),
        const SizedBox(width: 7),
        Text(label,
            style: const TextStyle(color: AnalyticsColors.muted, fontSize: 12)),
      ],
    );
  }
}

class _AnalyticsTableCard extends StatelessWidget {
  const _AnalyticsTableCard({
    required this.controller,
    required this.child,
    required this.title,
    this.subtitle,
    this.trailing,
  });

  final ScrollController controller;
  final Widget child;
  final String title;
  final String? subtitle;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 2),
      child: Container(
        decoration: BoxDecoration(
          color: AnalyticsColors.card,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: AnalyticsColors.line),
          boxShadow: const [
            BoxShadow(
              color: Color(0x12000000),
              blurRadius: 10,
              offset: Offset(0, 2),
            ),
          ],
        ),
        clipBehavior: Clip.antiAlias,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            AnalyticsCardHeader(
              title: title,
              subtitle: subtitle,
              trailing: trailing,
            ),
            const Divider(height: 1, color: AnalyticsColors.line),
            Expanded(
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
          ],
        ),
      ),
    );
  }
}
