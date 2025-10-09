import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'dart:async';

import '../orders/order_model.dart';
import 'task_model.dart';

class TaskProvider with ChangeNotifier {
  final SupabaseClient _supabase = Supabase.instance.client;

  final List<TaskModel> _tasks = [];
  RealtimeChannel? _channel;

  TaskProvider() {
    _listenToTasks();
  }

  List<TaskModel> get tasks => List.unmodifiable(_tasks);

  Future<void> _ensureAuthed() async {
    final auth = _supabase.auth;
    if (auth.currentUser == null) {
      // Use anon sign-in or your existing auth flow
      try {
        await auth.signInAnonymously();
      } catch (_) {}
    }
  }

  // Convert SQL row (snake_case) into TaskModel (camelCase map)
  TaskModel _rowToTask(Map<String, dynamic> row) {
    Map<String, dynamic> data = {};
    data['orderId'] = (row['order_id'] ?? '').toString();
    data['stageId'] = (row['stage_id'] ?? '').toString();
    data['status'] = (row['status'] ?? 'waiting').toString();
    data['spentSeconds'] = (row['spent_seconds'] as int?) ?? 0;
    final startedAt = row['started_at'];
    if (startedAt != null) {
      if (startedAt is int) data['startedAt'] = startedAt;
      if (startedAt is String) {
        // try parse int
        final v = int.tryParse(startedAt);
        if (v != null) data['startedAt'] = v;
      }
    }
    // assignees: text[]
    final a = row['assignees'];
    if (a is List) {
      data['assignees'] = List<String>.from(a.map((e) => e.toString()));
    }
    // comments: jsonb can be array or map
    final c = row['comments'];
    if (c is List) {
      // convert list -> map by id
      final Map<String, dynamic> mapped = {};
      for (final item in c) {
        if (item is Map && item['id'] != null) {
          mapped[item['id'].toString()] = item;
        }
      }
      data['comments'] = mapped;
    } else if (c is Map) {
      data['comments'] = c;
    }
    final id = (row['id'] ?? '').toString();
    return TaskModel.fromMap(data, id);
  }

  Future<void> refresh() async {
    await _ensureAuthed();
    try {
      final rows =
          await _supabase.from('tasks').select('*').order('created_at');
      _tasks
        ..clear()
        ..addAll(List<Map<String, dynamic>>.from(rows as List).map(_rowToTask));
      notifyListeners();
    } catch (e, st) {
      debugPrint('❌ refresh tasks error: $e\n$st');
    }
  }

  void _listenToTasks() {
    // initial load
    refresh();

    // remove old channel
    if (_channel != null) {
      _supabase.removeChannel(_channel!);
      _channel = null;
    }

    _channel = _supabase
        .channel('public:tasks')
        .onPostgresChanges(
          event: PostgresChangeEvent.all,
          schema: 'public',
          table: 'tasks',
          callback: (payload) async {
            await refresh();
          },
        )
        .subscribe();
  }

  // ===== updates =====

  /// Создаёт отдельную задачу для пользователя (режим "Отдельный исполнитель").
  /// Клонирует order_id и stage_id, задаёт status=inProgress и started_at=now,
  /// назначает единственного исполнителя [userId].
  Future<void> cloneTaskForUser(TaskModel src, String userId) async {
    await _ensureAuthed();
    try {
      final now = DateTime.now().millisecondsSinceEpoch;
      final row = {
        'order_id': src.orderId,
        'stage_id': src.stageId,
        'status': 'inProgress',
        'spent_seconds': 0,
        'started_at': now,
        'assignees': [userId],
        'comments': [],
      };
      final inserted =
          await _supabase.from('tasks').insert(row).select().single();
      // push into local list
      final task = _rowToTask(Map<String, dynamic>.from(inserted as Map));
      _tasks.add(task);
      notifyListeners();
    } catch (e, st) {
      debugPrint('❌ cloneTaskForUser error: $e\n$st');
    }
  }

  Future<void> updateStatus(
    String id,
    TaskStatus status, {
    int? spentSeconds,
    int? startedAt,
  }) async {
    final index = _tasks.indexWhere((t) => t.id == id);
    if (index == -1) return;

    final current = _tasks[index];
    final updated = current.copyWith(
      status: status,
      spentSeconds: spentSeconds ?? current.spentSeconds,
      startedAt: startedAt ?? current.startedAt,
      comments: current.comments,
      assignees: current.assignees,
    );
    _tasks[index] = updated;
    notifyListeners();

    final updates = <String, dynamic>{
      'status': status.name,
      'spent_seconds': updated.spentSeconds,
      'started_at': updated.startedAt,
      'updated_at': 'now()',
    };
    try {
      await _supabase.from('tasks').update(updates).eq('id', id);
      // if this task just became completed — check last-stage and update actual_qty
      if (status == TaskStatus.completed) {
        final orderId = updated.orderId;
        final stageId = updated.stageId;
        if (orderId.isNotEmpty && stageId.isNotEmpty) {
          await _maybeUpdateActualQtyAfterStage(orderId, stageId);
        }
      }
    } catch (e, st) {
      debugPrint('❌ tasks.updateStatus error: $e\n$st');
    }

    // If all tasks for order are completed — close the order
    final orderId = updated.orderId;
    if (orderId != null && orderId.isNotEmpty) {
      try {
        final rows = await _supabase
            .from('tasks')
            .select('status')
            .eq('order_id', orderId);
        final list = List<Map<String, dynamic>>.from(rows as List);
        final allCompleted = list.isNotEmpty &&
            list.every((r) => (r['status'] ?? '') == 'completed');
        if (allCompleted) {
          await _supabase
              .from('orders')
              .update({'status': OrderStatus.completed.name}).eq('id', orderId);
        }
      } catch (_) {}
    }
  }

  Future<void> addComment(
      {required String taskId,
      required String type,
      required String text,
      required String userId}) async {
    try {
      // Read current comments
      final row = await _supabase
          .from('tasks')
          .select('comments')
          .eq('id', taskId)
          .single();
      List<dynamic> comments = [];
      final c = row['comments'];
      if (c is List) comments = List.from(c);
      if (c is Map) {
        // convert map to list
        c.forEach((_, v) {
          comments.add(v);
        });
      }
      final timestamp = DateTime.now().millisecondsSinceEpoch;
      final newComment = {
        'id': '$timestamp',
        'type': type,
        'text': text,
        'userId': userId,
        'timestamp': timestamp,
      };
      comments.add(newComment);
      // sort by ts
      comments.sort(
          (a, b) => (a['timestamp'] as int).compareTo(b['timestamp'] as int));
      await _supabase
          .from('tasks')
          .update({'comments': comments}).eq('id', taskId);

      // update locally
      final idx = _tasks.indexWhere((t) => t.id == taskId);
      if (idx != -1) {
        final current = _tasks[idx];
        final updatedComments = List<TaskComment>.from(current.comments)
          ..add(TaskComment(
            id: newComment['id'] as String,
            type: type,
            text: text,
            userId: userId,
            timestamp: timestamp,
          ))
          ..sort((a, b) => a.timestamp.compareTo(b.timestamp));
        _tasks[idx] = current.copyWith(comments: updatedComments);
        notifyListeners();
      }
    } catch (e, st) {
      debugPrint('❌ addComment error: $e\n$st');
    }
  }

  Future<void> assignToUser(String taskId, String userId) async {
    try {
      final row = await _supabase
          .from('tasks')
          .select('assignees')
          .eq('id', taskId)
          .single();
      List<String> current = List<String>.from(
          (row['assignees'] as List?)?.map((e) => e.toString()) ?? const []);
      if (!current.contains(userId)) {
        current.add(userId);
        await _supabase
            .from('tasks')
            .update({'assignees': current}).eq('id', taskId);
      }

      // local
      final idx = _tasks.indexWhere((t) => t.id == taskId);
      if (idx != -1) {
        final local = _tasks[idx];
        if (!local.assignees.contains(userId)) {
          final newAssignees = List<String>.from(local.assignees)..add(userId);
          _tasks[idx] = local.copyWith(assignees: newAssignees);
          notifyListeners();
        }
      }
    } catch (e, st) {
      debugPrint('❌ assignToUser error: $e\n$st');
    }
  }

  Future<void> createTask({
    required String orderId,
    required String stageId,
  }) async {
    try {
      await _supabase.from('tasks').insert({
        'order_id': orderId,
        'stage_id': stageId,
        'status': 'waiting',
        'assignees': [],
        'comments': [],
      });
      await refresh();
    } catch (e, st) {
      debugPrint('❌ createTask error: $e\n$st');
    }
  }

  Future<void> updateAssignees(String id, List<String> assignees) async {
    // Local optimistic update
    final index = _tasks.indexWhere((t) => t.id == id);
    if (index != -1) {
      final updated =
          _tasks[index].copyWith(assignees: List<String>.from(assignees));
      _tasks[index] = updated;
      notifyListeners();
    }
    try {
      await _supabase
          .from('tasks')
          .update({'assignees': assignees}).eq('id', id);
    } catch (e, st) {
      debugPrint('❌ updateAssignees error: $e\n$st');
    }
  }

  Future<void> addAssignee(String id, String userId) async {
    try {
      final row = await _supabase
          .from('tasks')
          .select('assignees')
          .eq('id', id)
          .single();
      List<String> current = List<String>.from(
          (row['assignees'] as List?)?.map((e) => e.toString()) ?? const []);
      if (!current.contains(userId)) {
        current.add(userId);
        await _supabase
            .from('tasks')
            .update({'assignees': current}).eq('id', id);
      }
      // Local
      final index = _tasks.indexWhere((t) => t.id == id);
      if (index != -1) {
        final task = _tasks[index];
        if (!task.assignees.contains(userId)) {
          final newAssignees = List<String>.from(task.assignees)..add(userId);
          _tasks[index] = task.copyWith(assignees: newAssignees);
          notifyListeners();
        }
      }
    } catch (e, st) {
      debugPrint('❌ addAssignee error: $e\n$st');
    }
  }

  // ---- Helpers for last-stage quantity propagation to orders.actual_qty ----
  Future<bool> _isLastStage(String orderId, String stageId) async {
    // Try new schema: production.*
    try {
      final plan = await _supabase
          .from('production.plans')
          .select('id')
          .eq('order_id', orderId)
          .maybeSingle();
      if (plan != null && plan is Map && plan['id'] != null) {
        final rows = await _supabase
            .from('production.plan_stages')
            .select('*')
            .eq('plan_id', plan['id'].toString());
        if (rows is List && rows.isNotEmpty) {
          // find max 'order' value
          int maxOrder = 0;
          for (final r in rows) {
            final o = r['order'] ?? r['position'] ?? r['idx'] ?? 0;
            final oi = (o is int) ? o : int.tryParse(o.toString()) ?? 0;
            if (oi > maxOrder) maxOrder = oi;
          }
          // collect stage_ids with max order
          final lastIds = <String>{};
          for (final r in rows) {
            final o = r['order'] ?? r['position'] ?? r['idx'] ?? 0;
            final oi = (o is int) ? o : int.tryParse(o.toString()) ?? 0;
            if (oi == maxOrder) {
              final sid =
                  (r['stage_id'] ?? r['stageId'] ?? r['id'] ?? '').toString();
              if (sid.isNotEmpty) lastIds.add(sid);
            }
          }
          return lastIds.contains(stageId);
        }
      }
    } catch (_) {}

    // Fallback to legacy public.*
    try {
      final plan = await _supabase
          .from('prod_plans')
          .select('id')
          .eq('order_id', orderId)
          .maybeSingle();
      if (plan != null && plan is Map && plan['id'] != null) {
        final rows = await _supabase
            .from('prod_plan_stages')
            .select('*')
            .eq('plan_id', plan['id'].toString());
        if (rows is List && rows.isNotEmpty) {
          int maxOrder = 0;
          for (final r in rows) {
            final o = r['order'] ?? r['position'] ?? r['idx'] ?? 0;
            final oi = (o is int) ? o : int.tryParse(o.toString()) ?? 0;
            if (oi > maxOrder) maxOrder = oi;
          }
          final lastIds = <String>{};
          for (final r in rows) {
            final o = r['order'] ?? r['position'] ?? r['idx'] ?? 0;
            final oi = (o is int) ? o : int.tryParse(o.toString()) ?? 0;
            if (oi == maxOrder) {
              final sid =
                  (r['stage_id'] ?? r['stageId'] ?? r['id'] ?? '').toString();
              if (sid.isNotEmpty) lastIds.add(sid);
            }
          }
          return lastIds.contains(stageId);
        }
      }
    } catch (_) {}

    return false;
  }

  int _parseIntSafe(dynamic v) {
    if (v == null) return 0;
    if (v is int) return v;
    if (v is num) return v.toInt();
    if (v is String) {
      final s = v.trim();
      return int.tryParse(s) ??
          int.tryParse(s.replaceAll(RegExp(r'[^0-9-]'), '')) ??
          0;
    }
    return 0;
  }

  Future<int> _sumLastStageQuantity(String orderId, String stageId) async {
    // get all tasks for this order & stage
    final rows = await _supabase
        .from('tasks')
        .select('comments, assignees')
        .eq('order_id', orderId)
        .eq('stage_id', stageId);

    int total = 0;
    if (rows is List) {
      for (final r in rows) {
        // comments can be list or map
        final c = r['comments'];
        List<Map<String, dynamic>> comments = [];
        if (c is List) {
          comments = List<Map<String, dynamic>>.from(
              c.whereType<Map>().map((e) => Map<String, dynamic>.from(e)));
        } else if (c is Map) {
          c.forEach((_, v) {
            if (v is Map) comments.add(Map<String, dynamic>.from(v));
          });
        }
        // Prefer 'quantity_team_total' if present (joint mode)
        final team =
            comments.where((m) => (m['type'] ?? '') == 'quantity_team_total');
        if (team.isNotEmpty) {
          // take the latest record
          final last = team.reduce((a, b) =>
              ((a['timestamp'] ?? 0) as int) >= ((b['timestamp'] ?? 0) as int)
                  ? a
                  : b);
          total += _parseIntSafe(last['text']);
          continue;
        }
        // Else sum 'quantity_done' (separate executors)
        final parts =
            comments.where((m) => (m['type'] ?? '') == 'quantity_done');
        for (final m in parts) {
          total += _parseIntSafe(m['text']);
        }
      }
    }
    return total;
  }

  Future<void> _maybeUpdateActualQtyAfterStage(
      String orderId, String stageId) async {
    try {
      // 1) Stage tasks all completed?
      final rs = await _supabase
          .from('tasks')
          .select('status')
          .eq('order_id', orderId)
          .eq('stage_id', stageId);
      final list = List<Map<String, dynamic>>.from(rs as List);
      final allStageCompleted = list.isNotEmpty &&
          list.every((r) => (r['status'] ?? '') == 'completed');
      if (!allStageCompleted) return;

      // 2) Is this the last stage?
      final isLast = await _isLastStage(orderId, stageId);
      if (!isLast) return;

      // 3) Sum quantities and update orders.actual_qty
      final total = await _sumLastStageQuantity(orderId, stageId);
      await _supabase
          .from('orders')
          .update({'actual_qty': total}).eq('id', orderId);
    } catch (e, st) {
      debugPrint('❌ _maybeUpdateActualQtyAfterStage error: $e\n$st');
    }
  }

  @override
  void dispose() {
    if (_channel != null) {
      _supabase.removeChannel(_channel!);
      _channel = null;
    }
    super.dispose();
  }

  /// Добавляет комментарий, автоматически подставляя текущего пользователя из Supabase Auth.
  Future<void> addCommentAutoUser({
    required String taskId,
    required String type,
    required String text,
  }) async {
    await _ensureAuthed();
    final uid = _supabase.auth.currentUser?.id;
    if (uid == null) {
      debugPrint('❌ addCommentAutoUser: нет авторизованного пользователя');
      return;
    }
    await addComment(taskId: taskId, type: type, text: text, userId: uid);
  }
}
