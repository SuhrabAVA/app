import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// Провайдер для модуля нумераций (форм).
/// Позволяет хранить и инкрементировать серии и текущие номера в Supabase.
class FormsProvider with ChangeNotifier {
  final _sb = Supabase.instance.client;
  final List<Map<String, dynamic>> _series = [];

  /// Возвращает неизменяемый список серий.
  List<Map<String, dynamic>> get series => List.unmodifiable(_series);

  /// Загружает список серий из Supabase.
  Future<void> load() async {
    final rows = await _sb.from('forms').select().order('series');
    _series
      ..clear()
      ..addAll((rows as List).map((e) => Map<String, dynamic>.from(e)));
    notifyListeners();
  }

  /// Создаёт новую серию с именем [series].
  Future<void> createSeries(String series) async {
    final row = await _sb.from('forms').insert({'series': series}).select().single();
    _series.add(Map<String, dynamic>.from(row));
    notifyListeners();
  }

  /// Увеличивает счётчик для серии с идентификатором [id] на 1.
  Future<void> increment(String id) async {
    // Вызываем хранимую функцию forms_increment для безопасного инкремента.
    final row = await _sb.rpc('forms_increment', params: {'p_id': id});
    final idx = _series.indexWhere((e) => e['id'] == id);
    if (idx != -1) {
      _series[idx] = Map<String, dynamic>.from(row);
      notifyListeners();
    }
  }

  /// Устанавливает для серии с идентификатором [id] конкретный номер [n].
  Future<void> setNumber(String id, int n) async {
    final row = await _sb.from('forms').update({'last_number': n}).eq('id', id).select().single();
    final idx = _series.indexWhere((e) => e['id'] == id);
    if (idx != -1) {
      _series[idx] = Map<String, dynamic>.from(row);
      notifyListeners();
    }
  }

  /// Удаляет серию по идентификатору [id].
  Future<void> remove(String id) async {
    await _sb.from('forms').delete().eq('id', id);
    _series.removeWhere((e) => e['id'] == id);
    notifyListeners();
  }
}