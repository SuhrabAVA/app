import 'package:flutter/material.dart';
import 'package:firebase_database/firebase_database.dart';

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
    final updated = _tasks[index]
        .copyWith(status: status, spentSeconds: spentSeconds, startedAt: startedAt);
    _tasks[index] = updated;
    notifyListeners();
    await _tasksRef.child(id).update({
      'status': status.name,
      'spentSeconds': updated.spentSeconds,
      'startedAt': updated.startedAt,
    });
  }
}
