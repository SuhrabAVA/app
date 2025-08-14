import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:uuid/uuid.dart';
import 'tmc_model.dart';

class WarehouseProvider with ChangeNotifier {
  final SupabaseClient _supabase = Supabase.instance.client;

  List<TmcModel> _allTmc = [];
  List<TmcModel> get allTmc => _allTmc;

  /// Загрузка всех ТМЦ из Supabase
  Future<void> fetchTmc() async {
    final rows = await _supabase.from('tmc').select();
    _allTmc = rows.map((e) {
      final item = Map<String, dynamic>.from(e);
      return TmcModel(
        id: item['id'],
        date: item['date'],
        supplier: item['supplier'],
        type: item['type'],
        description: item['description'],
        quantity: (item['quantity'] as num).toDouble(),
        unit: item['unit'],
        note: item['note'],
        imageUrl: item['imageUrl'],
        imageBase64: item['imageBase64'],
      );
    }).toList();
    notifyListeners();
  }

  /// Получение всех ТМЦ определённого типа (например, "Бумага", "Канцелярия")
  List<TmcModel> getTmcByType(String type) {
    return _allTmc.where((e) => e.type == type).toList();
  }

  /// Добавление ТМЦ
  Future<void> addTmc({
    String? id,
    String? supplier,
    required String type,
    required String description,
    required double quantity,
    required String unit,
    String? note,
    String? imageUrl,
    String? imageBase64,
  }) async {
    // Позволяем передать идентификатор извне (например, для загрузки фото перед записью).
    final String newId = id ?? const Uuid().v4();
    final date = DateTime.now().toIso8601String();

    final data = <String, dynamic>{
      'id': newId,
      'date': date,
      'supplier': supplier,
      'type': type,
      'description': description,
      'quantity': quantity,
      'unit': unit,
      'note': note,
    };
    if (imageUrl != null) {
      data['imageUrl'] = imageUrl;
    }
    if (imageBase64 != null) {
      data['imageBase64'] = imageBase64;
    }

    await _supabase.from('tmc').insert(data);
    await fetchTmc();
  }

  /// Обновление количества для существующего ТМЦ.
  ///
  /// Принимает идентификатор записи и новое значение количества,
  /// затем обновляет запись в базе данных Supabase и перезагружает
  /// локальный список ТМЦ. Если запись отсутствует, метод ничего не делает.
  Future<void> updateTmcQuantity({
    required String id,
    required double newQuantity,
  }) async {
    await _supabase.from('tmc').update({'quantity': newQuantity}).eq('id', id);
    await fetchTmc();
  }

  /// Удаление записи ТМЦ по идентификатору.
  ///
  /// Принимает [id], удаляет соответствующую запись из базы данных
  /// и обновляет локальный список ТМЦ. Если запись отсутствует, метод
  /// ничего не делает.
  Future<void> deleteTmc(String id) async {
    try {
      await _supabase.from('tmc').delete().eq('id', id);
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
    String? imageUrl,
    String? imageBase64,
  }) async {
    final Map<String, dynamic> updates = {};
    if (description != null) updates['description'] = description;
    if (unit != null) updates['unit'] = unit;
    if (quantity != null) updates['quantity'] = quantity;
    if (supplier != null) updates['supplier'] = supplier;
    if (note != null) updates['note'] = note;
    if (imageUrl != null) updates['imageUrl'] = imageUrl;
    if (imageBase64 != null) updates['imageBase64'] = imageBase64;
    if (updates.isEmpty) return;
    await _supabase.from('tmc').update(updates).eq('id', id);
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

    await _supabase.from('shipments').insert(data);
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

    await _supabase.from('returns').insert(data);
  }
}
