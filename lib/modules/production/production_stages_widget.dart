
// lib/modules/production/production_stages_widget.dart
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// Lightweight widget that reads stages for a given order (by id)
/// from public.v_order_plan_stages and keeps them live via realtime.
class ProductionStagesWidget extends StatefulWidget {
  final String orderId;
  final EdgeInsetsGeometry padding;

  const ProductionStagesWidget({
    super.key,
    required this.orderId,
    this.padding = const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
  });

  @override
  State<ProductionStagesWidget> createState() => _ProductionStagesWidgetState();
}

class _ProductionStagesWidgetState extends State<ProductionStagesWidget> {
  final _sb = Supabase.instance.client;
  List<Map<String, dynamic>> _rows = [];
  String? _planId;
  RealtimeChannel? _chanStages;
  RealtimeChannel? _chanPlans;
  bool _loading = true;


  int _readOrder(Map<String, dynamic> row) {
    const keys = ['step_no', 'step', 'seq', 'order', 'position', 'idx'];
    for (final key in keys) {
      final value = row[key];
      if (value is int) return value;
      if (value is num) return value.toInt();
      if (value is String) {
        final parsed = int.tryParse(value.trim());
        if (parsed != null) return parsed;
      }
    }
    return 0;
  }

  List<Map<String, dynamic>> _normalizeRows(List<Map<String, dynamic>> rows) {
    final indexed = rows.asMap().entries.toList()
      ..sort((a, b) {
        final ao = _readOrder(a.value);
        final bo = _readOrder(b.value);
        if (ao != bo) return ao.compareTo(bo);
        return a.key.compareTo(b.key);
      });

    final result = <Map<String, dynamic>>[];
    final seenStageIds = <String>{};
    for (final entry in indexed) {
      final row = entry.value;
      final stageId = (row['stage_id'] ?? row['id'] ?? '').toString().trim();
      if (stageId.isEmpty || seenStageIds.contains(stageId)) continue;
      seenStageIds.add(stageId);
      result.add(row);
    }
    return result;
  }

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _unsubscribe();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    final res = await _sb
        .from('v_order_plan_stages')
        .select('*')
        .eq('order_id', widget.orderId)
        .order('step_no', ascending: true);
    final rawList = (res as List)
        .whereType<Map>()
        .map((r) => Map<String, dynamic>.from(r))
        .toList();
    final list = _normalizeRows(rawList);
    setState(() {
      _rows = list;
      _planId = list.isNotEmpty ? list.first['plan_id'] as String? : null;
      _loading = false;
    });
    _resubscribe();
  }

  void _resubscribe() {
    _unsubscribe();
    if (_planId == null) return;
    _chanStages = _sb
        .channel('prod_plan_stages_${_planId}')
        .onPostgresChanges(
          event: PostgresChangeEvent.all,
          schema: 'public',
          table: 'prod_plan_stages',
          filter: PostgresChangeFilter.equals('plan_id', _planId!),
          callback: (payload) { _load(); },
        )
        .subscribe();

    _chanPlans = _sb
        .channel('prod_plans_${_planId}')
        .onPostgresChanges(
          event: PostgresChangeEvent.all,
          schema: 'public',
          table: 'prod_plans',
          filter: PostgresChangeFilter.equals('id', _planId!),
          callback: (payload) { _load(); },
        )
        .subscribe();
  }

  void _unsubscribe() {
    if (_chanStages != null) {
      _sb.removeChannel(_chanStages!);
      _chanStages = null;
    }
    if (_chanPlans != null) {
      _sb.removeChannel(_chanPlans!);
      _chanPlans = null;
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    Widget body;

    if (_loading) {
      body = Padding(
        padding: widget.padding,
        child: Row(
          children: [
            const SizedBox(
              height: 18, width: 18,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
            const SizedBox(width: 12),
            Text('Загрузка этапов...', style: theme.textTheme.bodyMedium),
          ],
        ),
      );
    } else if (_rows.isEmpty) {
      body = Padding(
        padding: widget.padding,
        child: Text('План этапов отсутствует', style: theme.textTheme.bodyMedium),
      );
    } else {
      body = Padding(
        padding: widget.padding,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: _rows.map((r) => _StageChip(row: r)).toList(),
            ),
          ],
        ),
      );
    }

    return body;
  }
}

class _StageChip extends StatelessWidget {
  final Map<String, dynamic> row;
  const _StageChip({required this.row});

  Color _statusColor(BuildContext context, String? status) {
    switch (status) {
      case 'inProgress':
        return Colors.blueGrey.shade400;
      case 'paused':
        return const Color(0xFFCCB389); // warm sand
      case 'problem':
        return const Color(0xFFD9A1A3); // soft red
      case 'completed':
        return const Color(0xFFA9C4AE); // soft green
      case 'waiting':
      default:
        return Colors.grey.shade300;
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final name = row['stage_name'] as String? ?? 'Этап';
    final no = row['step_no'] as int?;
    final status = row['status'] as String? ?? 'waiting';

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: _statusColor(context, status),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Text(
        no != null ? '$name ($no)' : name,
        style: theme.textTheme.bodyMedium?.copyWith(
          color: Colors.black87,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}
