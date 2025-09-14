import 'package:flutter/material.dart';
import 'package:uuid/uuid.dart';

import '../../services/doc_db.dart';
import 'supplier_model.dart';

/// Провайдер для управления данными поставщиков.
///
/// Данные поставщиков хранятся в таблице `suppliers` Supabase. Провайдер
/// предоставляет методы для загрузки, добавления, обновления и удаления
/// записей, а также уведомляет слушателей о изменениях.
class SupplierProvider with ChangeNotifier {
  /// Универсальный DocDB для работы с таблицей `documents`.
  final DocDB _db = DocDB();

  List<SupplierModel> _suppliers = [];
  List<SupplierModel> get suppliers => _suppliers;

  /// Загружает список поставщиков из коллекции `suppliers` в documents.
  Future<void> fetchSuppliers() async {
    final rows = await _db.list('suppliers');
    _suppliers = rows.map((row) {
      // Объединяем данные документа и id для создания модели
      final Map<String, dynamic> data =
          Map<String, dynamic>.from(row['data'] as Map<String, dynamic>);
      data['id'] = row['id'];
      return SupplierModel.fromMap(data);
    }).toList();
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
    // сохраняем данные в documents и используем id как id документа
    await _db.insert('suppliers', data, explicitId: id);
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
    await _db.patchById(id, updates);
    await fetchSuppliers();
  }

  /// Удаление поставщика по id.
  Future<void> deleteSupplier(String id) async {
    await _db.deleteById(id);
    await fetchSuppliers();
  }
}