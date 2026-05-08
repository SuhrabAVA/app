
// lib/modules/production/production_stages_widget.dart
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../orders/order_queue_service.dart';

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
    var list = <Map<String, dynamic>>[];
    try {
      final res = await _sb
          .from('v_order_plan_stages')
          .select('*')
          .eq('order_id', widget.orderId)
          .order('step_no', ascending: true);
      if (res is List) {
        list = res
            .whereType<Map>()
            .map((row) => Map<String, dynamic>.from(row))
            .toList(growable: false);
      }
    } catch (_) {
      // Older deployments may not have the view; loadSavedQueue falls back to
      // prod_plan_stages / saved order JSON using the same priority as the
      // employee workspace.
    }

    if (list.isEmpty) {
      final savedQueue = await OrderQueueService(_sb).loadSavedQueue(
        widget.orderId,
      );
      list = savedQueue.rows;
    }

    list = _logicalStageRows(list);
    if (!mounted) return;
    setState(() {
      _rows = list;
      _planId = list.isNotEmpty ? list.first['plan_id'] as String? : null;
      _loading = false;
    });
    _resubscribe();
  }

  List<Map<String, dynamic>> _logicalStageRows(
    List<Map<String, dynamic>> rows,
  ) {
    final groups = <String, Map<String, dynamic>>{};
    final order = <String>[];
    for (var i = 0; i < rows.length; i++) {
      final row = Map<String, dynamic>.from(rows[i]);
      final stageId = (row['stage_id'] ?? row['stageId'] ?? row['workplaceId'])
              ?.toString()
              .trim() ??
          '';
      if (stageId.isEmpty) continue;
      final explicitGroup = (row['stage_group_key'] ?? row['stageGroupKey'])
              ?.toString()
              .trim() ??
          '';
      final groupKey = explicitGroup.isEmpty ? stageId : explicitGroup;
      final group = groups.putIfAbsent(groupKey, () {
        order.add(groupKey);
        return <String, dynamic>{
          ...row,
          'stage_group_key': groupKey,
          'workplaceIds': <String>[],
        };
      });
      final ids = (group['workplaceIds'] as List).cast<String>();
      if (!ids.contains(stageId)) ids.add(stageId);
      group['stage_id'] ??= stageId;
      group['stageId'] ??= stageId;
      group['stage_name'] = _stageName(group, row);
      group['status'] = _strongerStatus(group['status'], row['status']);
      group['step_no'] = _minInt(
        group['step_no'] ?? group['order'],
        row['step_no'] ?? row['order'] ?? row['seq'],
        i + 1,
      );
      group['order'] = group['step_no'];
      if (row['plan_id'] != null) group['plan_id'] ??= row['plan_id'];
    }
    return order.map((key) => groups[key]!).toList(growable: false)
      ..sort(
        (a, b) => _readInt(a['step_no']).compareTo(_readInt(b['step_no'])),
      );
  }

  String _stageName(Map<String, dynamic> current, Map<String, dynamic> next) {
    for (final row in [current, next]) {
      for (final key in const [
        'stage_name',
        'stageName',
        'name',
        'workplaceName',
      ]) {
        final value = row[key]?.toString().trim();
        if (value != null && value.isNotEmpty) return value;
      }
    }
    return 'Этап';
  }

  int _readInt(dynamic value) {
    if (value is int) return value;
    if (value is num) return value.toInt();
    return int.tryParse(value?.toString() ?? '') ?? 0;
  }

  int _minInt(dynamic a, dynamic b, int fallback) {
    final ai = _readInt(a);
    final bi = _readInt(b);
    if (ai <= 0 && bi <= 0) return fallback;
    if (ai <= 0) return bi;
    if (bi <= 0) return ai;
    return ai < bi ? ai : bi;
  }

  String _strongerStatus(dynamic a, dynamic b) {
    int rank(dynamic status) {
      switch ((status ?? '').toString().toLowerCase().replaceAll('-', '_')) {
        case 'completed':
        case 'complete':
        case 'done':
          return 5;
        case 'inprogress':
        case 'in_progress':
        case 'started':
          return 4;
        case 'paused':
        case 'problem':
          return 3;
        case 'ready':
        case 'available':
          return 2;
        default:
          return 1;
      }
    }

    return rank(b) > rank(a)
        ? (b ?? 'waiting').toString()
        : (a ?? 'waiting').toString();
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
          callback: (payload) {
            _load();
          },
        )
        .subscribe();

    _chanPlans = _sb
        .channel('prod_plans_${_planId}')
        .onPostgresChanges(
          event: PostgresChangeEvent.all,
          schema: 'public',
          table: 'prod_plans',
          filter: PostgresChangeFilter.equals('id', _planId!),
          callback: (payload) {
            _load();
          },
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
        child: Text(
          'План этапов отсутствует',
          style: theme.textTheme.bodyMedium,
        ),
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
    switch ((status ?? '').toLowerCase().replaceAll('-', '_')) {
      case 'inprogress':
      case 'in_progress':
      case 'started':
        return Colors.blueGrey.shade400;
      case 'paused':
        return const Color(0xFFCCB389); // warm sand
      case 'problem':
        return const Color(0xFFD9A1A3); // soft red
      case 'completed':
      case 'complete':
      case 'done':
        return const Color(0xFFA9C4AE); // soft green
      case 'waiting':
      case 'pending':
      case 'planned':
      case 'new':
      case 'todo':
      default:
        return Colors.grey.shade300;
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final name = row['stage_name']?.toString() ?? 'Этап';
    final rawNo = row['step_no'];
    final no = rawNo is int
        ? rawNo
        : rawNo is num
            ? rawNo.toInt()
            : int.tryParse(rawNo?.toString() ?? '');
    final status = row['status']?.toString() ?? 'waiting';

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
