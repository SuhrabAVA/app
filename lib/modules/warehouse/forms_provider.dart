import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';

import '../../services/doc_db.dart';

/// Провайдер для модуля нумераций (форм).
/// Данные сохраняются в коллекции `forms` таблицы `documents`.
class FormsProvider with ChangeNotifier {
  final DocDB _db = DocDB();
  final List<Map<String, dynamic>> _series = [];

  /// Возвращает неизменяемый список серий.
  List<Map<String, dynamic>> get series => List.unmodifiable(_series);

  /// Загружает список серий из коллекции `forms`.
  Future<void> load() async {
    final rows = await _db.list('forms');
    _series
      ..clear()
      ..addAll(rows.map((row) {
        final data = Map<String, dynamic>.from(row['data'] as Map<String, dynamic>);
        // перетащим метаданные документа в ожидаемые поля
        return {
          'id': row['id'],
          'series': data['series'],
          'last_number': data['last_number'] ?? 0,
          'created_at': data['createdAt'],
          'updated_at': data['updatedAt'],
        };
      }));
    notifyListeners();
  }

  /// Создаёт новую серию с именем [series].
  Future<void> createSeries(String series) async {
    final id = const Uuid().v4();
    final nowIso = DateTime.now().toUtc().toIso8601String();
    final data = {
      'id': id,
      'series': series,
      'last_number': 0,
      'createdAt': nowIso,
      'updatedAt': nowIso,
    };
    await _db.insert('forms', data, explicitId: id);
    await load();
  }

  /// Увеличивает счётчик для серии с идентификатором [id] на 1.
  Future<void> increment(String id) async {
    // Получаем текущую запись
    final row = await _db.getById(id);
    if (row == null) return;
    final data = Map<String, dynamic>.from(row['data'] as Map<String, dynamic>);
    final current = data['last_number'] as int? ?? 0;
    final newNumber = current + 1;
    final nowIso = DateTime.now().toUtc().toIso8601String();
    data['last_number'] = newNumber;
    data['updatedAt'] = nowIso;
    await _db.updateById(id, data);
    await load();
  }

  /// Устанавливает для серии с идентификатором [id] конкретный номер [n].
  Future<void> setNumber(String id, int n) async {
    final row = await _db.getById(id);
    if (row == null) return;
    final data = Map<String, dynamic>.from(row['data'] as Map<String, dynamic>);
    data['last_number'] = n;
    data['updatedAt'] = DateTime.now().toUtc().toIso8601String();
    await _db.updateById(id, data);
    await load();
  }

  /// Удаляет серию по идентификатору [id].
  Future<void> remove(String id) async {
    await _db.deleteById(id);
    _series.removeWhere((e) => e['id'] == id);
    notifyListeners();
  }
}