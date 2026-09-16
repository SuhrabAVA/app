import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../personnel/employee_model.dart';
import '../../personnel/personnel_provider.dart';
import '../calculators/salary_calculator.dart';
import '../models/day_shift_type.dart';
import '../models/salary_adjustments.dart';
import '../services/analytics_permission_service.dart';
import '../services/analytics_service.dart';
import '../utils/analytics_colors.dart';
import '../utils/analytics_constants.dart';
import '../utils/format_utils.dart';
import '../widgets/analytics_shell.dart';
import '../widgets/analytics_states.dart';

/// Аналитика сотрудников со статусом и без должности (уборщик, охранник).
///
/// В общей таблице сотрудников у них пусто: заданий они не выполняют, а вся
/// их аналитика — это график, отметки прихода/ухода и оплата по ставке
/// статуса. Отсюда и отдельное окно.
///
/// Смены считаются по графику, а не по отметкам: сотрудник может забыть
/// нажать кнопку, и на зарплату это не влияет (см. SalaryCalculator).
class StatusStaffAnalyticsScreen extends StatelessWidget {
  const StatusStaffAnalyticsScreen({
    super.key,
    required this.service,
    required this.permission,
  });

  final AnalyticsService service;
  final AnalyticsPermissionService permission;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: service,
      builder: (context, _) {
        final state = service.state;
        if (state.loading) return const AnalyticsLoadingState();
        if (state.error != null) {
          return AnalyticsErrorState(
            message: 'Не удалось загрузить аналитику.\n${state.error}',
            onRetry: service.refresh,
          );
        }

        final personnel = context.read<PersonnelProvider>();
        final rows = buildStatusStaffRows(
          employees: personnel.employees,
          state: state,
          canViewFinance: permission.canViewFinance,
        );

        if (rows.isEmpty) {
          return const AnalyticsEmptyState(
            icon: Icons.badge_outlined,
            message: 'Нет сотрудников со статусом без должности.\n'
                'Такие сотрудники появятся здесь, как только им назначат '
                'статус и не назначат должность.',
          );
        }

        return Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 2),
          child: Container(
            decoration: BoxDecoration(
              color: AnalyticsColors.card,
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: AnalyticsColors.line),
            ),
            clipBehavior: Clip.antiAlias,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const AnalyticsCardHeader(
                  title: 'Сотрудники по статусу',
                  subtitle: 'Смены начисляются по графику и ставке статуса. '
                      'Отметки прихода и ухода показаны для контроля и на '
                      'оплату не влияют.',
                ),
                const Divider(height: 1, color: AnalyticsColors.line),
                Expanded(
                  child: ListView.separated(
                    padding: const EdgeInsets.all(12),
                    itemCount: rows.length,
                    separatorBuilder: (_, __) => const SizedBox(height: 10),
                    itemBuilder: (context, i) => _StatusStaffCard(
                      row: rows[i],
                      showMoney: permission.canViewFinance,
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

/// Строка сводки по одному сотруднику со статусом.
class StatusStaffRow {
  const StatusStaffRow({
    required this.employeeId,
    required this.name,
    required this.statusName,
    required this.scheduledShifts,
    required this.dayShifts,
    required this.nightShifts,
    required this.rate,
    required this.accrued,
    required this.markedDays,
    required this.missingMarkDays,
  });

  final String employeeId;
  final String name;
  final String statusName;

  /// Смены по графику — они же оплачиваемые.
  final int scheduledShifts;
  final int dayShifts;
  final int nightShifts;
  final double rate;
  final double accrued;

  /// Дней с отметкой прихода.
  final int markedDays;

  /// Смен по графику, где отметки не было. Это не штраф — только наглядность.
  final int missingMarkDays;
}

/// Собирает строки для экрана. Вынесено из виджета, чтобы правило отбора
/// («есть статус, нет должности») можно было проверить тестом.
List<StatusStaffRow> buildStatusStaffRows({
  required List<EmployeeModel> employees,
  required AnalyticsState state,
  required bool canViewFinance,
}) {
  final statusNames = {for (final s in state.statuses) s.id: s.name};
  final rows = <StatusStaffRow>[];

  for (final emp in employees) {
    if (emp.isFired) continue;
    final hasPosition = emp.positionIds.any((id) => id.trim().isNotEmpty);
    if (hasPosition) continue;
    final statusId = state.employeeStatusIds[emp.id];
    if (statusId == null || statusId.trim().isEmpty) continue;

    final breakdown = SalaryCalculator.compute(
      events: const [],
      coefficients: state.coefficients,
      helperCoefficients: state.helperCoefficients,
      settings: state.settings,
      adjustments: state.adjustments[emp.id] ??
          SalaryAdjustments.zero(emp.id, state.month.firstDay),
      halfShiftMinutes: AnalyticsConstants.halfShiftMinutes,
      month: state.month,
      statusPeriods: state.employeeStatusHistory[emp.id] ?? const [],
      statusPayRates: state.statusPayRates,
      statusNames: statusNames,
      scheduledShifts: state.scheduledShiftsFor(emp.id),
    );

    final schedule = state.schedules[emp.id] ?? const {};
    final attendance = state.attendance[emp.id] ?? const {};
    var marked = 0;
    var missing = 0;
    for (final entry in schedule.entries) {
      if (entry.value.shiftType == DayShiftType.off) continue;
      if (attendance[entry.key]?.arrivedAt != null) {
        marked++;
      } else {
        missing++;
      }
    }

    rows.add(StatusStaffRow(
      employeeId: emp.id,
      name: _displayName(emp),
      statusName: statusNames[statusId] ?? 'Без названия',
      scheduledShifts: breakdown.statusShiftsTotal,
      dayShifts: breakdown.dayShifts,
      nightShifts: breakdown.nightShifts,
      rate: canViewFinance ? (state.statusPayRates[statusId] ?? 0) : 0,
      accrued: canViewFinance ? breakdown.fixedStatusPay : 0,
      markedDays: marked,
      missingMarkDays: missing,
    ));
  }

  rows.sort((a, b) => a.name.compareTo(b.name));
  return rows;
}

String _displayName(EmployeeModel emp) {
  final parts = [emp.lastName, emp.firstName, emp.patronymic]
      .map((p) => p.trim())
      .where((p) => p.isNotEmpty);
  final full = parts.join(' ');
  if (full.isNotEmpty) return full;
  return emp.login.isEmpty ? 'Без имени' : emp.login;
}

class _StatusStaffCard extends StatelessWidget {
  const _StatusStaffCard({required this.row, required this.showMoney});

  final StatusStaffRow row;
  final bool showMoney;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AnalyticsColors.bg2,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AnalyticsColors.line),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  row.name,
                  style: const TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                    color: AnalyticsColors.text,
                  ),
                ),
              ),
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                decoration: BoxDecoration(
                  color: AnalyticsColors.card,
                  borderRadius: BorderRadius.circular(999),
                  border: Border.all(color: AnalyticsColors.line),
                ),
                child: Text(
                  row.statusName,
                  style: const TextStyle(
                    fontSize: 12,
                    color: AnalyticsColors.muted,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 22,
            runSpacing: 8,
            children: [
              _metric('Смен по графику', '${row.scheduledShifts}'),
              _metric('День / ночь', '${row.dayShifts} / ${row.nightShifts}'),
              _metric('Отметился', '${row.markedDays}'),
              _metric(
                'Без отметки',
                '${row.missingMarkDays}',
                muted: row.missingMarkDays == 0,
              ),
              if (showMoney) ...[
                _metric('Ставка', AnalyticsFormat.money(row.rate)),
                _metric('Начислено', AnalyticsFormat.money(row.accrued), strong: true),
              ],
            ],
          ),
        ],
      ),
    );
  }

  Widget _metric(
    String label,
    String value, {
    bool strong = false,
    bool muted = false,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          label,
          style: const TextStyle(fontSize: 11, color: AnalyticsColors.muted),
        ),
        const SizedBox(height: 2),
        Text(
          value,
          style: TextStyle(
            fontSize: strong ? 16 : 14,
            fontWeight: strong ? FontWeight.w700 : FontWeight.w600,
            color: muted ? AnalyticsColors.muted : AnalyticsColors.text,
          ),
        ),
      ],
    );
  }
}
