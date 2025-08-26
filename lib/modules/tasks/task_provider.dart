import 'dart:async';
import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

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
    _tasksSub = _supabase.from('tasks').stream(primaryKey: ['id']).listen((rows) {
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

  Future<void> updateStatus(String id, TaskStatus status,
      {int? spentSeconds, int? startedAt}) async {
    final index = _tasks.indexWhere((t) => t.id == id);
    if (index == -1) return;
    // Сохраняем текущие комментарии и исполнителей при обновлении статуса.
    final current = _tasks[index];
    final updated = current.copyWith(
      status: status,
      spentSeconds: spentSeconds,
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

    // После обновления статуса проверяем, все ли задачи этого заказа завершены.
    final orderId = updated.orderId;
    final tasksForOrder = _tasks.where((t) => t.orderId == orderId).toList();
    final allDone = tasksForOrder.isNotEmpty &&
        tasksForOrder.every((t) => t.status == TaskStatus.completed);
    if (allDone) {
      // Обновляем статус заказа на "completed" в Supabase. OrdersProvider слушает это и обновит локальное состояние.
      await _supabase
          .from('orders')
          .update({'status': OrderStatus.completed.name}).eq('id', orderId);
    }

    await refresh();
  }

  /// Обновляет список исполнителей для задачи. Перезаписывает существующий
  /// список идентификаторов сотрудников и обновляет запись в Supabase.
  Future<void> updateAssignees(String id, List<String> assignees) async {
    final index = _tasks.indexWhere((t) => t.id == id);
    if (index == -1) return;
    final current = _tasks[index];
    final updated =
        current.copyWith(assignees: assignees, comments: current.comments);
    _tasks[index] = updated;
    notifyListeners();
    await _supabase
        .from('tasks')
        .update({'assignees': assignees}).eq('id', id);
  }

  /// Добавляет комментарий к задаче. Комментарии хранятся в подузле
  /// `comments` в каждой задаче. Каждый комментарий содержит текст, тип
  /// (pause/problem), идентификатор пользователя и временную метку. При
  /// добавлении комментария обновляется локальный список задач, чтобы
  /// комментарий стал доступен без повторной загрузки данных.
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

    final index = _tasks.indexWhere((t) => t.id == taskId);
    if (index != -1) {
      final current = _tasks[index];
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
      _tasks[index] = current.copyWith(comments: updatedComments);
      notifyListeners();
    }
  }

  @override
  void dispose() {
    _tasksSub?.cancel();
    super.dispose();
  }
}