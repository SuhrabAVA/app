import 'package:flutter/material.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:uuid/uuid.dart';
import 'tmc_model.dart';

class WarehouseProvider with ChangeNotifier {
  final DatabaseReference _db = FirebaseDatabase.instance.ref();

  List<TmcModel> _allTmc = [];
  List<TmcModel> get allTmc => _allTmc;

  /// Загрузка всех ТМЦ из Firebase
  Future<void> fetchTmc() async {
    final snapshot = await _db.child('tmc').get();
    if (snapshot.exists) {
      final data = Map<String, dynamic>.from(snapshot.value as Map);
      _allTmc = data.entries.map((e) {
        final item = Map<String, dynamic>.from(e.value);
        return TmcModel(
          id: item['id'],
          date: item['date'],
          supplier: item['supplier'],
          type: item['type'],
          description: item['description'],
          quantity: (item['quantity'] as num).toDouble(),
          unit: item['unit'],
          note: item['note'],
        );
      }).toList();
      notifyListeners();
    }
  }

  /// Получение всех ТМЦ определённого типа (например, "Бумага", "Канцелярия")
  List<TmcModel> getTmcByType(String type) {
    return _allTmc.where((e) => e.type == type).toList();
  }

  /// Добавление ТМЦ
  Future<void> addTmc({
    String? supplier,
    required String type,
    required String description,
    required double quantity,
    required String unit,
    String? note,
  }) async {
    final id = const Uuid().v4();
    final date = DateTime.now().toIso8601String();

    final data = {
      'id': id,
      'date': date,
      'supplier': supplier,
      'type': type,
      'description': description,
      'quantity': quantity,
      'unit': unit,
      'note': note,
    };

    await _db.child('tmc').child(id).set(data);
    await fetchTmc(); // обновляем локально
  }

  /// Обновление количества для существующего ТМЦ.
  ///
  /// Принимает идентификатор записи и новое значение количества,
  /// затем обновляет запись в базе данных Firebase и перезагружает
  /// локальный список ТМЦ. Если запись отсутствует, метод ничего не делает.
  Future<void> updateTmcQuantity({
    required String id,
    required double newQuantity,
  }) async {
    await _db.child('tmc').child(id).update({'quantity': newQuantity});
    await fetchTmc();
  }

  /// Удаление записи ТМЦ по идентификатору.
  ///
  /// Принимает [id], удаляет соответствующую запись из базы данных
  /// и обновляет локальный список ТМЦ. Если запись отсутствует, метод
  /// ничего не делает.
  Future<void> deleteTmc(String id) async {
    try {
      await _db.child('tmc').child(id).remove();
      await fetchTmc();
    } catch (_) {
      // Игнорируем ошибки при удалении, чтобы не прерывать работу UI
    }
  }

  /// Обновление полей для существующего ТМЦ.
  ///
  /// Позволяет обновить описание, единицу измерения, количество или
  /// поставщика. Любые поля, переданные как `null`, будут пропущены.
  Future<void> updateTmc({
    required String id,
    String? description,
    String? unit,
    double? quantity,
    String? supplier,
    String? note,
  }) async {
    final Map<String, dynamic> updates = {};
    if (description != null) updates['description'] = description;
    if (unit != null) updates['unit'] = unit;
    if (quantity != null) updates['quantity'] = quantity;
    if (supplier != null) updates['supplier'] = supplier;
    if (note != null) updates['note'] = note;
    if (updates.isEmpty) return;
    await _db.child('tmc').child(id).update(updates);
    await fetchTmc();
  }

  /// Отгрузка
  Future<void> registerShipment({
    required String receiver,
    required String product,
    required double quantity,
    required String document,
  }) async {
    final id = const Uuid().v4();
    final data = {
      'id': id,
      'date': DateTime.now().toIso8601String(),
      'receiver': receiver,
      'product': product,
      'quantity': quantity,
      'document': document,
    };

    await _db.child('shipments').child(id).set(data);
  }

  /// Возврат
  Future<void> registerReturn({
    required bool isToSupplier,
    required String partner,
    required String product,
    required double quantity,
    required String reason,
    required String note,
  }) async {
    final id = const Uuid().v4();
    final data = {
      'id': id,
      'date': DateTime.now().toIso8601String(),
      'direction': isToSupplier ? 'to_supplier' : 'from_client',
      'partner': partner,
      'product': product,
      'quantity': quantity,
      'reason': reason,
      'note': note,
    };

    await _db.child('returns').child(id).set(data);
  }
}
