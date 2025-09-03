import 'package:flutter/material.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:uuid/uuid.dart';

import 'supplier_model.dart';

/// Провайдер для управления данными поставщиков.
///
/// Данные хранятся в Firebase Realtime Database по пути `suppliers`.
/// Предоставляет методы для загрузки, добавления, обновления и удаления
/// поставщиков, а также уведомляет слушателей о изменениях.
class SupplierProvider with ChangeNotifier {
  final DatabaseReference _db = FirebaseDatabase.instance.ref();

  List<SupplierModel> _suppliers = [];
  List<SupplierModel> get suppliers => _suppliers;

  /// Загрузка списка поставщиков из Firebase.
  Future<void> fetchSuppliers() async {
    final snapshot = await _db.child('suppliers').get();
    if (snapshot.exists) {
      final data = Map<String, dynamic>.from(snapshot.value as Map);
      _suppliers = data.entries.map((e) {
        final item = Map<String, dynamic>.from(e.value);
        return SupplierModel.fromMap(item);
      }).toList();
    } else {
      _suppliers = [];
    }
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
    await _db.child('suppliers').child(id).set(data);
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
    await _db.child('suppliers').child(id).update(updates);
    await fetchSuppliers();
  }

  /// Удаление поставщика по id.
  Future<void> deleteSupplier(String id) async {
    await _db.child('suppliers').child(id).remove();
    await fetchSuppliers();
  }
}