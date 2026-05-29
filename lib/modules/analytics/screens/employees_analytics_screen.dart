import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../personnel/personnel_provider.dart';
import '../services/analytics_pdf_export_service.dart';
import '../services/analytics_permission_service.dart';
import '../services/analytics_service.dart';
import '../utils/analytics_colors.dart';
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

        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 6, 16, 4),
              child: Align(
                alignment: Alignment.centerRight,
                child: _PdfButton(
                  loading: _pdfLoading,
                  onPressed: () => _exportPdf(personnel),
                ),
              ),
            ),
            Expanded(
              child: _AnalyticsTableCard(
                controller: _scrollController,
                child: EmployeesTable(
                  service: widget.service,
                  personnel: personnel,
                  permission: widget.permission,
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
              ),
            ),
          ],
        );
      },
    );
  }
}

class _PdfButton extends StatelessWidget {
  const _PdfButton({required this.loading, required this.onPressed});

  final bool loading;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return FilledButton.icon(
      onPressed: loading ? null : onPressed,
      icon: loading
          ? const SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : const Icon(Icons.picture_as_pdf_outlined),
      label: Text(loading ? 'Создаём PDF…' : 'Скачать PDF'),
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
