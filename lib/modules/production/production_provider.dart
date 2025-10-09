// lib/modules/production/production_provider.dart
//
// Variant B: enforce auth in code and read stages from production.v_plan_with_stages.
// Drop this file in your project to replace the existing provider (or add if missing).
//
// Requirements in your project:
//   - package:provider/provider.dart
//   - package:supabase_flutter/supabase_flutter.dart
//   - services/app_auth.dart with AppAuth.ensureSignedIn()
//
// This provider exposes:
//   - loadPlanByOrderCode(String orderCode)
//   - planTitle, dueAt, planId, stages (sorted by step_no), isLoading, error
//
// It performs AppAuth.ensureSignedIn() before any DB access so that RLS policies
// that require "authenticated" are satisfied.

import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../services/app_auth.dart';

class ProdStage {
  final String stageId;
  final int stepNo;
  final String stageName;
  final String? stageStatus;
  final int? orderInQueue;
  final String? assigneeAuthUid;
  final String? assignedWorkplaceId;
  final String? requiredPositionId;
  final DateTime? startedAt;
  final DateTime? finishedAt;
  final int? actualMinutes;

  const ProdStage({
    required this.stageId,
    required this.stepNo,
    required this.stageName,
    this.stageStatus,
    this.orderInQueue,
    this.assigneeAuthUid,
    this.assignedWorkplaceId,
    this.requiredPositionId,
    this.startedAt,
    this.finishedAt,
    this.actualMinutes,
  });

  factory ProdStage.fromRow(Map<String, dynamic> r) {
    DateTime? _ts(dynamic v) =>
        (v == null) ? null : DateTime.tryParse(v.toString());
    return ProdStage(
      stageId: r['stage_id']?.toString() ?? '',
      stepNo: (r['step_no'] is int) ? r['step_no'] as int : int.tryParse('${r['step_no']}') ?? 0,
      stageName: r['stage_name']?.toString() ?? '',
      stageStatus: r['stage_status']?.toString(),
      orderInQueue: (r['order_in_queue'] is int) ? r['order_in_queue'] as int : int.tryParse('${r['order_in_queue']}'),
      assigneeAuthUid: r['assignee_auth_uid']?.toString(),
      assignedWorkplaceId: r['assigned_workplace_id']?.toString(),
      requiredPositionId: r['required_position_id']?.toString(),
      startedAt: _ts(r['started_at']),
      finishedAt: _ts(r['finished_at']),
      actualMinutes: (r['actual_minutes'] is int) ? r['actual_minutes'] as int : int.tryParse('${r['actual_minutes']}'),
    );
  }
}

class ProductionProvider with ChangeNotifier {
  final SupabaseClient _sb = Supabase.instance.client;

  // Current plan context
  String? _planId;
  String? _planTitle;
  String? _orderCode;
  String? _planStatus;
  DateTime? _plannedStartAt;
  DateTime? _dueAt;

  bool _isLoading = false;
  String? _error;
  List<ProdStage> _stages = const [];

  String? get planId => _planId;
  String? get planTitle => _planTitle;
  String? get orderCode => _orderCode;
  String? get planStatus => _planStatus;
  DateTime? get plannedStartAt => _plannedStartAt;
  DateTime? get dueAt => _dueAt;
  bool get isLoading => _isLoading;
  String? get error => _error;
  List<ProdStage> get stages => List.unmodifiable(_stages);

  Future<void> _ensureAuthed() async {
    await AppAuth.ensureSignedIn();
  }

  /// Loads plan+stages by order_code from production.v_plan_with_stages
  /// (sorted by step_no). Satisfies RLS by authenticating first.
  Future<void> loadPlanByOrderCode(String orderCode) async {
    _isLoading = true;
    _error = null;
    notifyListeners();

    try {
      await _ensureAuthed();

      // Read from the view; it already joins plans + plan_stages
      final rows = await _sb
          .from('production.v_plan_with_stages')
          .select<List<Map<String, dynamic>>>()
          .eq('order_code', orderCode)
          .order('step_no', ascending: true);

      if (rows.isEmpty) {
        // Keep state clean but signal that nothing found.
        _planId = null;
        _planTitle = null;
        _orderCode = orderCode;
        _planStatus = null;
        _plannedStartAt = null;
        _dueAt = null;
        _stages = const [];
        _error = 'План этапов не найден для order_code=$orderCode';
        _isLoading = false;
        notifyListeners();
        return;
      }

      // Common columns are repeated per stage; take them from the first row.
      final first = rows.first;
      _planId = first['plan_id']?.toString();
      _planTitle = first['plan_title']?.toString();
      _orderCode = first['order_code']?.toString();
      _planStatus = first['plan_status']?.toString();

      DateTime? _ts(dynamic v) =>
          (v == null) ? null : DateTime.tryParse(v.toString());
      _plannedStartAt = _ts(first['planned_start_at']);
      _dueAt = _ts(first['due_at']);

      _stages = rows.map((r) => ProdStage.fromRow(r)).toList(growable: false);

      _isLoading = false;
      notifyListeners();
    } catch (e) {
      _error = e.toString();
      _isLoading = false;
      notifyListeners();
    }
  }
}
