import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:uuid/uuid.dart';

import 'supplier_model.dart';

/// Провайдер для управления данными поставщиков.
///
/// Данные хранятся в Firebase Realtime Database по пути `suppliers`.
/// Предоставляет методы для загрузки, добавления, обновления и удаления
/// поставщиков, а также уведомляет слушателей о изменениях.
class SupplierProvider with ChangeNotifier {
  final SupabaseClient _supabase = Supabase.instance.client;

  List<SupplierModel> _suppliers = [];
  List<SupplierModel> get suppliers => _suppliers;

  /// Загрузка списка поставщиков из Firebase.
  Future<void> fetchSuppliers() async {
    final rows = await _supabase.from('suppliers').select();
    _suppliers = rows
        .map((e) => SupplierModel.fromMap(Map<String, dynamic>.from(e)))
        .toList();
    notifyListeners();
  }

  /// Добавление нового поставщика.
  Future<void> addSupplier({
    required String name,
    required String bin,
    required String contact,
    required String phone,
  }) async {
    final id = const Uuid().v4();
    final data = {
      'id': id,
      'name': name,
      'bin': bin,
      'contact': contact,
      'phone': phone,
    };
    await _supabase.from('suppliers').insert(data);
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
    final Map<String, dynamic> updates = {};
    if (name != null) updates['name'] = name;
    if (bin != null) updates['bin'] = bin;
    if (contact != null) updates['contact'] = contact;
    if (phone != null) updates['phone'] = phone;
    if (updates.isEmpty) return;
    await _supabase.from('suppliers').update(updates).eq('id', id);
    await fetchSuppliers();
  }

  /// Удаление поставщика по id.
  Future<void> deleteSupplier(String id) async {
    await _supabase.from('suppliers').delete().eq('id', id);
    await fetchSuppliers();
  }
}