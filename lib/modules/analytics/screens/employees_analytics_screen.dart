import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../personnel/personnel_provider.dart';
import '../services/analytics_pdf_export_service.dart';
import '../services/analytics_permission_service.dart';
import '../services/analytics_service.dart';
import '../utils/analytics_colors.dart';
import '../widgets/analytics_shell.dart';
import '../widgets/analytics_states.dart';
import '../widgets/employees_table.dart';
import 'employee_detail_screen.dart';

class EmployeesAnalyticsScreen extends StatefulWidget {
  const EmployeesAnalyticsScreen({
    super.key,
    required this.service,
    required this.permission,
  });

  final AnalyticsService service;
  final AnalyticsPermissionService permission;

  @override
  State<EmployeesAnalyticsScreen> createState() =>
      _EmployeesAnalyticsScreenState();
}

class _EmployeesAnalyticsScreenState extends State<EmployeesAnalyticsScreen> {
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
      final path = await _pdfService.exportEmployeesTablePdf(
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
      debugPrint('Employees PDF export failed: $error');
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
          return const AnalyticsLoadingState();
        }
        if (state.error != null) {
          return AnalyticsErrorState(
            message:
                'Не удалось загрузить аналитику сотрудников.\n${state.error}',
            onRetry: () => widget.service.refresh(),
          );
        }

        final personnel = context.read<PersonnelProvider>();
        final activeEmployees = personnel.employees.where((e) => !e.isFired);
        if (activeEmployees.isEmpty) {
          return const AnalyticsEmptyState(
            icon: Icons.people_outline,
            message: 'Нет активных сотрудников для выбранного месяца.',
          );
        }

        return _AnalyticsTableCard(
          controller: _scrollController,
          title: 'Сотрудники',
          subtitle:
              'Клик по строке открывает детальную аналитику. Таблица прокручивается по горизонтали и вертикали.',
          trailing: AnalyticsPdfButton(
            loading: _pdfLoading,
            onPressed: () => _exportPdf(personnel),
          ),
          child: EmployeesTable(
            service: widget.service,
            personnel: personnel,
            permission: widget.permission,
            verticalController: _scrollController,
            onEmployeeTap: (id) {
              Navigator.of(context).push(MaterialPageRoute(
                builder: (_) => EmployeeDetailScreen(
                  service: widget.service,
                  permission: widget.permission,
                  employeeId: id,
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
            // Вертикальный скролл теперь внутри EmployeesTable (строки и
            // футер под закреплённой шапкой столбцов); Scrollbar остаётся
            // здесь и привязан к тому же контроллеру.
            Expanded(
              child: Scrollbar(
                controller: controller,
                thumbVisibility: true,
                child: child,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
