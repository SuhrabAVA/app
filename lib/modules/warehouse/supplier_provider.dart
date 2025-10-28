import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:uuid/uuid.dart';

import 'supplier_model.dart';

/// Провайдер для управления данными поставщиков.
/// Переезд с JSON-коллекции `documents` на таблицу `public.suppliers`.
class SupplierProvider with ChangeNotifier {
  final SupabaseClient _sb = Supabase.instance.client;
  List<SupplierModel> _suppliers = [];
  List<SupplierModel> get suppliers => List.unmodifiable(_suppliers);

  Future<void> _ensureAuthed() async {
    final auth = _sb.auth;
    if (auth.currentUser == null) {
      await auth.signInAnonymously();
    }
  }

  /// Загрузка поставщиков из таблицы `suppliers`.
  Future<void> fetchSuppliers() async {
    await _ensureAuthed();
    final res = await _sb
        .from('suppliers')
        .select()
        .order('name', ascending: true);
    if (res is List) {
      _suppliers = res.map((row) {
        final m = Map<String, dynamic>.from(row as Map);
        return SupplierModel.fromMap(m);
      }).toList();
      notifyListeners();
    }
  }

  /// Добавление нового поставщика.
  Future<void> addSupplier({
    required String name,
    required String bin,
    required String contact,
    required String phone,
  }) async {
    await _ensureAuthed();
    final id = const Uuid().v4();
    final row = {
      'id': id,
      'name': name,
      'bin': bin,
      'contact': contact,
      'phone': phone,
    };
    await _sb.from('suppliers').insert(row);
    await fetchSuppliers();
  }

  /// Обновление существующего поставщика.
  Future<void> updateSupplier({
    required String id,
    String? name,
    String? bin,
    String? contact,
    String? phone,
  }) async {
    await _ensureAuthed();
    final updates = <String, dynamic>{};
    if (name != null) updates['name'] = name;
    if (bin != null) updates['bin'] = bin;
    if (contact != null) updates['contact'] = contact;
    if (phone != null) updates['phone'] = phone;
    if (updates.isEmpty) return;
    updates['updated_at'] = DateTime.now().toUtc().toIso8601String();
    await _sb.from('suppliers').update(updates).eq('id', id);
    await fetchSuppliers();
  }

  /// Удаление поставщика по id.
  Future<void> deleteSupplier(String id) async {
    await _ensureAuthed();
    await _sb.from('suppliers').delete().eq('id', id);
    await fetchSuppliers();
  }
}
