import 'package:flutter/material.dart';

import '../../utils/shift_day.dart';
import '../tasks/workspace_design.dart';
import 'employee_attendance_repository.dart';

/// Рабочее место сотрудника со статусом и без должности (уборщик, охранник).
///
/// Заданий у такого сотрудника нет, поэтому и производственного рабочего
/// пространства ему показывать нечего: весь экран — две кнопки, «Пришёл» и
/// «Ушёл».
///
/// Отметка ни на что не влияет в деньгах: смена оплачивается по графику и по
/// ставке статуса, даже если сотрудник забыл нажать кнопку. Об этом на экране
/// сказано прямо, чтобы отметку не считали условием оплаты.
/// Ключи кнопок отметки — по ним их находят тесты: `ElevatedButton.icon`
/// строит подкласс, и поиск по типу его не видит.
const Key arriveButtonKey = ValueKey('status-shift-arrive');
const Key leaveButtonKey = ValueKey('status-shift-leave');

class StatusShiftScreen extends StatefulWidget {
  const StatusShiftScreen({
    super.key,
    required this.employeeId,
    required this.employeeName,
    this.statusName,
    this.repository,
    this.onExit,
  });

  final String employeeId;
  final String employeeName;
  final String? statusName;

  /// Подменяется в тестах.
  final EmployeeAttendanceRepository? repository;

  /// Выход из аккаунта; null — кнопка не показывается.
  final Future<void> Function()? onExit;

  @override
  State<StatusShiftScreen> createState() => _StatusShiftScreenState();
}

class _StatusShiftScreenState extends State<StatusShiftScreen> {
  late final EmployeeAttendanceRepository _repo =
      widget.repository ?? EmployeeAttendanceRepository();

  EmployeeAttendanceDay? _today;
  bool _loading = true;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  Future<void> _reload() async {
    try {
      final day = await _repo.loadDay(
        employeeId: widget.employeeId,
        workDate: shiftDayOf(DateTime.now()),
      );
      if (!mounted) return;
      setState(() {
        _today = day;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _loading = false);
      _snack('Не удалось загрузить отметку: $e');
    }
  }

  void _snack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _mark({required bool arrival}) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      if (arrival) {
        await _repo.markArrival(employeeId: widget.employeeId);
      } else {
        await _repo.markDeparture(employeeId: widget.employeeId);
      }
      await _reload();
      _snack(arrival ? 'Отмечен приход' : 'Отмечен уход');
    } catch (e) {
      _snack('Не удалось отметить: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  static String _time(DateTime? value) {
    if (value == null) return '—';
    String two(int n) => n.toString().padLeft(2, '0');
    return '${two(value.hour)}:${two(value.minute)}';
  }

  @override
  Widget build(BuildContext context) {
    final today = _today;
    final arrived = today?.arrivedAt;
    final left = today?.leftAt;
    final onShift = today?.isOnShift ?? false;

    return Scaffold(
      backgroundColor: WorkspaceColors.background,
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 520),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _header(),
                  const SizedBox(height: 16),
                  if (_loading)
                    const Padding(
                      padding: EdgeInsets.symmetric(vertical: 32),
                      child: Center(child: CircularProgressIndicator()),
                    )
                  else ...[
                    _statusCard(arrived: arrived, left: left, onShift: onShift),
                    const SizedBox(height: 16),
                    _button(
                      key: arriveButtonKey,
                      label: 'Пришёл',
                      icon: Icons.login_rounded,
                      color: WorkspaceColors.success,
                      enabled: !_busy && !onShift,
                      onTap: () => _mark(arrival: true),
                    ),
                    const SizedBox(height: 12),
                    _button(
                      key: leaveButtonKey,
                      label: 'Ушёл',
                      icon: Icons.logout_rounded,
                      color: WorkspaceColors.danger,
                      enabled: !_busy && onShift,
                      onTap: () => _mark(arrival: false),
                    ),
                    const SizedBox(height: 16),
                    const Text(
                      'Отметка нужна для учёта присутствия. На зарплату она не '
                      'влияет: смена начисляется по графику и ставке статуса, '
                      'даже если отметиться забыли.',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        color: WorkspaceColors.mutedForeground,
                        fontSize: 12,
                        height: 1.35,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _header() {
    final status = (widget.statusName ?? '').trim();
    return Row(
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                widget.employeeName,
                style: const TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.w600,
                  color: WorkspaceColors.foreground,
                ),
              ),
              if (status.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: Text(
                    status,
                    style: const TextStyle(
                      fontSize: 13,
                      color: WorkspaceColors.mutedForeground,
                    ),
                  ),
                ),
            ],
          ),
        ),
        if (widget.onExit != null)
          IconButton(
            tooltip: 'Выйти',
            icon: const Icon(Icons.logout, color: WorkspaceColors.foreground),
            onPressed: () async {
              await widget.onExit!.call();
            },
          ),
      ],
    );
  }

  Widget _statusCard({
    required DateTime? arrived,
    required DateTime? left,
    required bool onShift,
  }) {
    final label = onShift
        ? 'На смене'
        : (left != null ? 'Смена завершена' : 'Смена не начата');
    final color = onShift
        ? WorkspaceColors.success
        : (left != null
            ? WorkspaceColors.mutedForeground
            : WorkspaceColors.warning);

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: workspaceCardDecoration(),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 10,
                height: 10,
                decoration: BoxDecoration(color: color, shape: BoxShape.circle),
              ),
              const SizedBox(width: 8),
              Text(
                label,
                style: TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w600,
                  color: color,
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(child: _timeCell('Пришёл', _time(arrived))),
              Expanded(child: _timeCell('Ушёл', _time(left))),
            ],
          ),
        ],
      ),
    );
  }

  Widget _timeCell(String label, String value) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: const TextStyle(
              fontSize: 12,
              color: WorkspaceColors.mutedForeground,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            value,
            style: const TextStyle(
              fontSize: 22,
              fontWeight: FontWeight.w600,
              color: WorkspaceColors.foreground,
            ),
          ),
        ],
      );

  Widget _button({
    required Key key,
    required String label,
    required IconData icon,
    required Color color,
    required bool enabled,
    required VoidCallback onTap,
  }) {
    return SizedBox(
      height: 64,
      child: ElevatedButton.icon(
        key: key,
        onPressed: enabled ? onTap : null,
        icon: Icon(icon, size: 24),
        label: Text(
          label,
          style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
        ),
        style: ElevatedButton.styleFrom(
          backgroundColor: color,
          foregroundColor: Colors.white,
          disabledBackgroundColor: WorkspaceColors.secondaryBackground,
          disabledForegroundColor: WorkspaceColors.disabledForeground,
          elevation: 0,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(14),
          ),
        ),
      ),
    );
  }
}

/// Сотрудник со статусом, но без должности: заданий у него нет, поэтому
/// производственное рабочее пространство ему не подходит.
bool isStatusOnlyEmployee({
  required List<String> positionIds,
  required String? statusId,
}) {
  final hasPosition = positionIds.any((id) => id.trim().isNotEmpty);
  final hasStatus = (statusId ?? '').trim().isNotEmpty;
  return !hasPosition && hasStatus;
}
