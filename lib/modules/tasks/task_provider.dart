import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'dart:async';

import '../orders/order_model.dart';
import 'task_model.dart';
import '../../services/doc_db.dart';

class TaskProvider with ChangeNotifier {
  final SupabaseClient _supabase = Supabase.instance.client;
  final DocDB _docDb = DocDB();

  final List<TaskModel> _tasks = [];
  StreamSubscription<List<Map<String, dynamic>>>? _tasksSub; // не используется, но оставлен для совместимости
  RealtimeChannel? _channel;

  TaskProvider() {
    _listenToTasks();
  }

  List<TaskModel> get tasks => List.unmodifiable(_tasks);

  // ====== realtime из documents/tasks ======
  void _listenToTasks() {
    // первичная загрузка
    refresh();

    // если был старый канал — уберём
    if (_channel != null) {
      _supabase.removeChannel(_channel!);
      _channel = null;
    }

    // подписка на коллекцию tasks
    _channel = _docDb.listenCollection('tasks', (row, eventType) async {
      await refresh();
    });
  }

  // ====== загрузка из documents/tasks ======
  Future<void> refresh() async {
    try {
      final rows = await _docDb.list('tasks'); // [{ id, collection, data, created_at, ...}, ...]
      _tasks
        ..clear()
        ..addAll(rows.map((row) {
          final data = Map<String, dynamic>.from(row['data'] as Map);
          // твоя модель ожидает id вторым аргументом
          return TaskModel.fromMap(data, row['id'].toString());
        }));
      notifyListeners();
    } catch (e, st) {
      debugPrint('❌ refresh tasks error: $e\n$st');
    }
  }

  // ====== обновления ======

  /// Обновляет статус, время и т.д. (совместимая сигнатура).
  /// Всё пишет в documents/tasks с camelCase ключами, как у тебя в модели.
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

    // Патчим документ задачи
    final updates = <String, dynamic>{
      'status': status.name,
      'spentSeconds': updated.spentSeconds,
      'startedAt': updated.startedAt,
    };
    await _docDb.patchById(id, updates);

    // Если все задачи заказа завершены — закрываем заказ (через documents/orders)
    final orderId = updated.orderId;
    if (orderId != null && orderId.isNotEmpty) {
      final tasksForOrder = _tasks.where((t) => t.orderId == orderId).toList();
      final allDone = tasksForOrder.isNotEmpty &&
          tasksForOrder.every((t) => t.status == TaskStatus.completed);
      if (allDone) {
        try {
          await _docDb.patchById(orderId, {'status': OrderStatus.completed.name});
        } catch (e) {
          debugPrint('⚠️ order status patch failed: $e');
        }
      }
    }

    await refresh();
  }

  /// Полностью заменяет список исполнителей.
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

    await _docDb.patchById(id, {'assignees': assignees});
  }

  /// Добавляет исполнителя, не допуская дублей.
  Future<void> addAssignee(String taskId, String userId) async {
    try {
      final row = await _docDb.getById(taskId);
      if (row == null) return;

      final data = Map<String, dynamic>.from(row['data'] as Map);
      final current = List<String>.from((data['assignees'] ?? []) as List);
      if (!current.contains(userId)) {
        current.add(userId);
        await _docDb.patchById(taskId, {'assignees': current});
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
    } catch (e, st) {
      debugPrint('❌ addAssignee error: $e\n$st');
    }
  }

  /// Добавляет комментарий в массив `comments` внутри задачи (documents/tasks).
  /// Сигнатура — как была изначально (named args).
  Future<void> addComment({
    required String taskId,
    required String type,
    required String text,
    required String userId,
  }) async {
    final timestamp = DateTime.now().millisecondsSinceEpoch;

    try {
      final row = await _docDb.getById(taskId);
      if (row == null) return;

      final data = Map<String, dynamic>.from(row['data'] as Map);
      final List<dynamic> comments =
          (data['comments'] as List?)?.toList() ?? <dynamic>[];

      final newComment = {
        'id': '${timestamp}', // локальный id для коммента
        'type': type,
        'text': text,
        'userId': userId,
        'timestamp': timestamp,
      };
      comments.add(newComment);

      await _docDb.patchById(taskId, {'comments': comments});

      // Синхронизируем локально
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

  /// Клонирует задачу на конкретного пользователя (documents/tasks).
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
    await _docDb.insert('tasks', insert);
    await refresh();
  }

  @override
  void dispose() {
    _tasksSub?.cancel();
    if (_channel != null) {
      _supabase.removeChannel(_channel!);
      _channel = null;
    }
    super.dispose();
  }
}
