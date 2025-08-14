import 'package:flutter/material.dart';
import 'package:firebase_database/firebase_database.dart';

import '../orders/order_model.dart';

import 'task_model.dart';

class TaskProvider with ChangeNotifier {
  final DatabaseReference _tasksRef =
      FirebaseDatabase.instance.ref('tasks');

  final List<TaskModel> _tasks = [];

  TaskProvider() {
    _listenToTasks();
  }

  List<TaskModel> get tasks => List.unmodifiable(_tasks);

  void _listenToTasks() {
    _tasksRef.onValue.listen((event) {
      final data = event.snapshot.value;
      _tasks.clear();
      if (data is Map) {
        data.forEach((key, value) {
          final map = Map<String, dynamic>.from(value as Map);
          _tasks.add(TaskModel.fromMap(map, key));
        });
      }
      notifyListeners();
    });
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
    await _tasksRef.child(id).update({
      'status': status.name,
      'spentSeconds': updated.spentSeconds,
      'startedAt': updated.startedAt,
    });

    // После обновления статуса проверяем, все ли задачи этого заказа завершены.
    final orderId = updated.orderId;
    final tasksForOrder = _tasks.where((t) => t.orderId == orderId).toList();
    final allDone = tasksForOrder.isNotEmpty &&
        tasksForOrder.every((t) => t.status == TaskStatus.completed);
    if (allDone) {
      // Обновляем статус заказа на "completed" в Firebase. OrdersProvider слушает это и обновит локальное состояние.
      await FirebaseDatabase.instance
          .ref('orders/$orderId')
          .update({'status': OrderStatus.completed.name});
    }
  }

  /// Обновляет список исполнителей для задачи. Перезаписывает существующий
  /// список идентификаторов сотрудников и обновляет запись в Firebase.
  Future<void> updateAssignees(String id, List<String> assignees) async {
    final index = _tasks.indexWhere((t) => t.id == id);
    if (index == -1) return;
    final current = _tasks[index];
    final updated = current.copyWith(assignees: assignees, comments: current.comments);
    _tasks[index] = updated;
    notifyListeners();
    await _tasksRef.child(id).update({'assignees': assignees});
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
    // Создаём новую запись в Firebase.
    final commentRef = _tasksRef.child(taskId).child('comments').push();
    final timestamp = DateTime.now().millisecondsSinceEpoch;
    await commentRef.set({
      'type': type,
      'text': text,
      'userId': userId,
      'timestamp': timestamp,
    });
    // Обновляем локальную модель.
    final index = _tasks.indexWhere((t) => t.id == taskId);
    if (index != -1) {
      final current = _tasks[index];
      final newComment = TaskComment(
        id: commentRef.key ?? '',
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
}