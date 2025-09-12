import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'dart:async';

import '../orders/order_model.dart';
import 'task_model.dart';

class TaskProvider with ChangeNotifier {
  final SupabaseClient _supabase = Supabase.instance.client;

  final List<TaskModel> _tasks = [];
  StreamSubscription<List<Map<String, dynamic>>>? _tasksSub;

  TaskProvider() {
    _listenToTasks();
  }

  List<TaskModel> get tasks => List.unmodifiable(_tasks);

  void _listenToTasks() {
    _tasksSub?.cancel();
    _tasksSub =
        _supabase.from('tasks').stream(primaryKey: ['id']).listen((rows) {
      _tasks
        ..clear()
        ..addAll(rows.map((row) {
          final map = Map<String, dynamic>.from(row as Map);
          return TaskModel.fromMap(map, map['id'].toString());
        }));
      notifyListeners();
    });
  }

  Future<void> refresh() async {
    try {
      final rows = await _supabase.from('tasks').select();
      _tasks
        ..clear()
        ..addAll(rows.map((row) {
          final map = Map<String, dynamic>.from(row as Map);
          return TaskModel.fromMap(map, map['id'].toString());
        }));
      notifyListeners();
    } catch (e, st) {
      debugPrint('❌ refresh tasks error: $e\n$st');
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
      startedAt: startedAt,
      comments: current.comments,
      assignees: current.assignees,
    );
    _tasks[index] = updated;
    notifyListeners();

    await _supabase.from('tasks').update({
      'status': status.name,
      'spentSeconds': updated.spentSeconds,
      'startedAt': updated.startedAt,
    }).eq('id', id);

    // Если все задачи заказа завершены — закрываем заказ
    final orderId = updated.orderId;
    final tasksForOrder = _tasks.where((t) => t.orderId == orderId).toList();
    final allDone = tasksForOrder.isNotEmpty &&
        tasksForOrder.every((t) => t.status == TaskStatus.completed);
    if (allDone) {
      await _supabase
          .from('orders')
          .update({'status': OrderStatus.completed.name}).eq('id', orderId);
    }

    await refresh();
  }

  Future<void> updateAssignees(String id, List<String> assignees) async {
    final index = _tasks.indexWhere((t) => t.id == id);
    if (index == -1) return;

    final current = _tasks[index];
    final updated = current.copyWith(
      assignees: assignees,
      comments: current.comments,
    );
    _tasks[index] = updated;
    notifyListeners();

    await _supabase.from('tasks').update({'assignees': assignees}).eq('id', id);
  }

  Future<void> addAssignee(String taskId, String userId) async {
    try {
      await _supabase.rpc(
        'append_unique_assignee',
        params: {'p_task_id': taskId, 'p_user_id': userId},
      );
    } catch (_) {
      // Fallback: читаем текущее и обновляем массив вручную
      final row =
          await _supabase.from('tasks').select().eq('id', taskId).single();
      final current = List<String>.from((row['assignees'] ?? []) as List);
      if (!current.contains(userId)) {
        current.add(userId);
        await _supabase
            .from('tasks')
            .update({'assignees': current}).eq('id', taskId);
      }
    }

    // Локально тоже обновим
    final idx = _tasks.indexWhere((t) => t.id == taskId);
    if (idx != -1) {
      final local = _tasks[idx];
      if (!local.assignees.contains(userId)) {
        final newAssignees = List<String>.from(local.assignees)..add(userId);
        _tasks[idx] = local.copyWith(assignees: newAssignees);
        notifyListeners();
      }
    }
  }

  /// Добавляет комментарий (отдельная таблица `task_comments`) и
  /// синхронизирует локальное состояние.
  Future<void> addComment({
    required String taskId,
    required String type,
    required String text,
    required String userId,
  }) async {
    final timestamp = DateTime.now().millisecondsSinceEpoch;

    final res = await _supabase
        .from('task_comments')
        .insert({
          'task_id': taskId,
          'type': type,
          'text': text,
          'user_id': userId,
          'timestamp': timestamp,
        })
        .select()
        .single();

    final idx = _tasks.indexWhere((t) => t.id == taskId);
    if (idx != -1) {
      final current = _tasks[idx];
      final newComment = TaskComment(
        id: res['id'].toString(),
        type: type,
        text: text,
        userId: userId,
        timestamp: timestamp,
      );
      final updatedComments = List<TaskComment>.from(current.comments)
        ..add(newComment)
        ..sort((a, b) => a.timestamp.compareTo(b.timestamp));
      _tasks[idx] = current.copyWith(comments: updatedComments);
      notifyListeners();
    }
  }

  Future<void> cloneTaskForUser(TaskModel task, String userId) async {
    final insert = {
      'orderId': task.orderId,
      'stageId': task.stageId,
      'status': TaskStatus.waiting.name,
      'assignees': [userId],
      'spentSeconds': 0,
      'comments': [],
      'startedAt': null,
    };
    await _supabase.from('tasks').insert(insert);
    await refresh();
  }

  @override
  void dispose() {
    _tasksSub?.cancel();
    super.dispose();
  }
}
