import 'dart:async';

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../personnel/employee_model.dart';
import '../personnel/personnel_provider.dart';
import '../tasks/task_model.dart';
import '../tasks/task_provider.dart';

class PieceworkAnalyticsTab extends StatefulWidget {
  const PieceworkAnalyticsTab({
    super.key,
    required this.selectedEmployeeId,
    required this.range,
    required this.personnel,
    required this.taskProvider,
  });

  final String? selectedEmployeeId;
  final DateTimeRange? range;
  final PersonnelProvider personnel;
  final TaskProvider taskProvider;

  @override
  State<PieceworkAnalyticsTab> createState() => _PieceworkAnalyticsTabState();
}

class _PieceworkAnalyticsTabState extends State<PieceworkAnalyticsTab> {
  final SupabaseClient _supabase = Supabase.instance.client;

  final Map<String, _RateRow> _rates = <String, _RateRow>{};
  bool _loadingRates = true;
  String? _ratesError;

  @override
  void initState() {
    super.initState();
    _loadRates();
  }

  Future<void> _loadRates() async {
    setState(() {
      _loadingRates = true;
      _ratesError = null;
    });

    try {
      final rows = await _supabase
          .from('production_analytics_rates')
          .select('workplace_id, unit_price, setup_price');

      final next = <String, _RateRow>{};
      if (rows is List) {
        for (final raw in rows) {
          if (raw is! Map) continue;
          final map = Map<String, dynamic>.from(raw);
          final workplaceId = (map['workplace_id'] ?? '').toString();
          if (workplaceId.isEmpty) continue;
          next[workplaceId] = _RateRow(
            unitPrice: _toDouble(map['unit_price']),
            setupPrice: _toDouble(map['setup_price']),
          );
        }
      }

      if (!mounted) return;
      setState(() {
        _rates
          ..clear()
          ..addAll(next);
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _ratesError =
            'Не удалось загрузить цены. Проверьте таблицу production_analytics_rates в базе.';
      });
    } finally {
      if (mounted) {
        setState(() {
          _loadingRates = false;
        });
      }
    }
  }

  Future<void> _saveRate(
    String workplaceId, {
    required double unitPrice,
    required double setupPrice,
  }) async {
    setState(() {
      _rates[workplaceId] = _RateRow(unitPrice: unitPrice, setupPrice: setupPrice);
    });

    try {
      await _supabase.from('production_analytics_rates').upsert({
        'workplace_id': workplaceId,
        'unit_price': unitPrice,
        'setup_price': setupPrice,
      });
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Не удалось сохранить цену. Проверьте доступ к таблице production_analytics_rates.',
          ),
        ),
      );
    }
  }

  double _parseQty(String rawText) {
    final normalized = rawText.replaceAll(',', '.').trim();
    final match = RegExp(r'-?[0-9]+(?:\.[0-9]+)?').firstMatch(normalized);
    if (match != null) {
      return double.tryParse(match.group(0)!) ?? 0;
    }
    return double.tryParse(normalized) ?? 0;
  }

  bool _inRange(int timestamp) {
    final range = widget.range;
    if (range == null) return true;

    final start = DateTime(range.start.year, range.start.month, range.start.day)
        .millisecondsSinceEpoch;
    final end = DateTime(range.end.year, range.end.month, range.end.day)
            .add(const Duration(days: 1))
            .millisecondsSinceEpoch -
        1;
    return timestamp >= start && timestamp <= end;
  }

  Map<String, _AggregatedRow> _aggregate() {
    final result = <String, _AggregatedRow>{};
    final selectedEmployee = widget.selectedEmployeeId;

    bool matchesEmployee(TaskComment c) {
      if (selectedEmployee == null || selectedEmployee.isEmpty) return true;
      return c.userId == selectedEmployee;
    }

    for (final TaskModel task in widget.taskProvider.tasks) {
      final stageId = task.stageId;
      if (stageId.trim().isEmpty) continue;

      final row = result.putIfAbsent(stageId, () => _AggregatedRow());

      for (final TaskComment comment in task.comments) {
        if (!matchesEmployee(comment) || !_inRange(comment.timestamp)) continue;

        if (comment.type == 'quantity_done' ||
            comment.type == 'quantity_team_total' ||
            comment.type == 'quantity_share') {
          row.quantity += _parseQty(comment.text);
        }

        if (comment.type == 'setup_done') {
          row.setupCount += 1;
        }
      }
    }

    result.removeWhere((_, row) => row.quantity <= 0 && row.setupCount <= 0);
    return result;
  }

  String _employeeTitle() {
    final employeeId = widget.selectedEmployeeId;
    if (employeeId == null || employeeId.isEmpty) {
      return 'Все сотрудники';
    }
    try {
      final EmployeeModel employee =
          widget.personnel.employees.firstWhere((e) => e.id == employeeId);
      return '${employee.lastName} ${employee.firstName}'.trim();
    } catch (_) {
      return employeeId;
    }
  }

  String _formatDouble(double value, {int precision = 2}) {
    if (value == value.roundToDouble()) return value.toInt().toString();
    return value.toStringAsFixed(precision).replaceAll(RegExp(r'0+$'), '').replaceAll(RegExp(r'\.$'), '');
  }

  @override
  Widget build(BuildContext context) {
    if (_loadingRates) {
      return const Center(child: CircularProgressIndicator());
    }

    final aggregated = _aggregate();
    final workplaces = widget.personnel.workplaces;
    final sortedWorkplaces = workplaces
        .where((w) => aggregated.containsKey(w.id))
        .toList()
      ..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));

    double grandTotal = 0;

    return RefreshIndicator(
      onRefresh: _loadRates,
      child: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(16),
              boxShadow: const [
                BoxShadow(
                  color: Color(0x14000000),
                  blurRadius: 16,
                  offset: Offset(0, 6),
                ),
              ],
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Сдельная аналитика',
                  style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 8),
                Text('Сотрудник: ${_employeeTitle()}'),
                const SizedBox(height: 4),
                Text(
                  widget.range == null
                      ? 'Период: за всё время'
                      : 'Период: ${DateFormat('dd.MM.yyyy').format(widget.range!.start)} — ${DateFormat('dd.MM.yyyy').format(widget.range!.end)}',
                ),
                if (_ratesError != null) ...[
                  const SizedBox(height: 10),
                  Text(
                    _ratesError!,
                    style: const TextStyle(color: Colors.red),
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(height: 12),
          if (sortedWorkplaces.isEmpty)
            const Padding(
              padding: EdgeInsets.all(16),
              child: Center(child: Text('Нет данных по выбранным фильтрам.')),
            )
          else
            ...sortedWorkplaces.map((workplace) {
              final stat = aggregated[workplace.id]!;
              final rate = _rates[workplace.id] ?? const _RateRow();
              final unitPrice = rate.unitPrice;
              final setupPrice = rate.setupPrice;
              final total = stat.quantity * unitPrice + stat.setupCount * setupPrice;
              grandTotal += total;

              return _PieceworkRowCard(
                workplaceName: workplace.name,
                unit: workplace.unit?.trim().isNotEmpty == true
                    ? workplace.unit!.trim()
                    : 'ед.',
                quantity: stat.quantity,
                setupCount: stat.setupCount,
                unitPrice: unitPrice,
                setupPrice: setupPrice,
                total: total,
                formatDouble: _formatDouble,
                onRateChanged: (newUnitPrice, newSetupPrice) {
                  _saveRate(
                    workplace.id,
                    unitPrice: newUnitPrice,
                    setupPrice: newSetupPrice,
                  );
                },
              );
            }),
          if (sortedWorkplaces.isNotEmpty)
            Container(
              margin: const EdgeInsets.only(top: 10),
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(12),
                color: const Color(0xFF0F172A),
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  const Text(
                    'ИТОГО',
                    style: TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.w700,
                      fontSize: 16,
                    ),
                  ),
                  Text(
                    _formatDouble(grandTotal),
                    style: const TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.w700,
                      fontSize: 18,
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

class _PieceworkRowCard extends StatefulWidget {
  const _PieceworkRowCard({
    required this.workplaceName,
    required this.unit,
    required this.quantity,
    required this.setupCount,
    required this.unitPrice,
    required this.setupPrice,
    required this.total,
    required this.formatDouble,
    required this.onRateChanged,
  });

  final String workplaceName;
  final String unit;
  final double quantity;
  final int setupCount;
  final double unitPrice;
  final double setupPrice;
  final double total;
  final String Function(double value, {int precision}) formatDouble;
  final void Function(double unitPrice, double setupPrice) onRateChanged;

  @override
  State<_PieceworkRowCard> createState() => _PieceworkRowCardState();
}

class _PieceworkRowCardState extends State<_PieceworkRowCard> {
  late final TextEditingController _unitController;
  late final TextEditingController _setupController;
  Timer? _debounce;

  @override
  void initState() {
    super.initState();
    _unitController =
        TextEditingController(text: widget.formatDouble(widget.unitPrice));
    _setupController =
        TextEditingController(text: widget.formatDouble(widget.setupPrice));
  }

  @override
  void didUpdateWidget(covariant _PieceworkRowCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.unitPrice != widget.unitPrice) {
      _unitController.text = widget.formatDouble(widget.unitPrice);
    }
    if (oldWidget.setupPrice != widget.setupPrice) {
      _setupController.text = widget.formatDouble(widget.setupPrice);
    }
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _unitController.dispose();
    _setupController.dispose();
    super.dispose();
  }

  double _parse(String text) {
    return double.tryParse(text.replaceAll(',', '.').trim()) ?? 0;
  }

  void _scheduleSave() {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 450), () {
      widget.onRateChanged(_parse(_unitController.text), _parse(_setupController.text));
    });
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: const Color(0xFFE2E8F0)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            widget.workplaceName,
            style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 12,
            runSpacing: 10,
            children: [
              _infoChip('Ед. изм.', widget.unit),
              _infoChip('Кол-во', widget.formatDouble(widget.quantity)),
              _infoChip('Приладки', widget.setupCount.toString()),
              _infoChip('Сумма', widget.formatDouble(widget.total)),
            ],
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _unitController,
                  keyboardType:
                      const TextInputType.numberWithOptions(decimal: true),
                  decoration: const InputDecoration(
                    labelText: 'Цена за ед.',
                    border: OutlineInputBorder(),
                    isDense: true,
                  ),
                  onChanged: (_) => _scheduleSave(),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: TextField(
                  controller: _setupController,
                  keyboardType:
                      const TextInputType.numberWithOptions(decimal: true),
                  decoration: const InputDecoration(
                    labelText: 'Цена за приладку',
                    border: OutlineInputBorder(),
                    isDense: true,
                  ),
                  onChanged: (_) => _scheduleSave(),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _infoChip(String title, String value) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(10),
        color: const Color(0xFFF8FAFC),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: const TextStyle(
              color: Color(0xFF64748B),
              fontSize: 12,
              fontWeight: FontWeight.w500,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            value,
            style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
          ),
        ],
      ),
    );
  }
}

class _AggregatedRow {
  double quantity = 0;
  int setupCount = 0;
}

class _RateRow {
  final double unitPrice;
  final double setupPrice;

  const _RateRow({this.unitPrice = 0, this.setupPrice = 0});
}

double _toDouble(dynamic value) {
  if (value == null) return 0;
  if (value is num) return value.toDouble();
  return double.tryParse(value.toString().replaceAll(',', '.')) ?? 0;
}
