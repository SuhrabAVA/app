import 'dart:async';
import 'dart:typed_data';
import 'dart:convert'; // base64Decode
import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../../services/doc_db.dart';
import 'package:uuid/uuid.dart';

import 'tmc_model.dart';

class WarehouseProvider with ChangeNotifier {
  /// Supabase client is retained only for Storage operations and auth access.
  final SupabaseClient _supabase = Supabase.instance.client;

  /// DocDB instance to interact with the universal `documents` table.
  final DocDB _db = DocDB();

  /// All TMC items cached in memory.
  final List<TmcModel> _allTmc = [];

  /// Realtime channel subscription for `tmc` collection.
  RealtimeChannel? _channel;

  List<TmcModel> get allTmc => List.unmodifiable(_allTmc);

  WarehouseProvider() {
    _listenTmc();
  }

  // =========================================================
  // SAFE INSERT into public.documents (collection, data, [explicitId])
  // - добавляет created_by, если есть сессия
  // - не трогает created_at/updated_at (их ставят дефолты/триггеры в БД)
  // - возвращает всю строку (id, collection, data, created_by, created_at, updated_at)
  // =========================================================
  Future<Map<String, dynamic>> _insertDocSafe({
    required String collection,
    required Map<String, dynamic> data,
    String? explicitId,
  }) async {
    final uid = _supabase.auth.currentUser?.id;

    final payload = <String, dynamic>{
      'collection': collection,
      'data': data,
      if (explicitId != null) 'id': explicitId, // ДОЛЖЕН быть UUID, если указываешь
      if (uid != null) 'created_by': uid,       // иначе триггер в БД подставит системный
    };

    final row = await _supabase
        .from('documents')
        .insert(payload)
        .select('id, collection, data, created_by, created_at, updated_at')
        .single();

    return Map<String, dynamic>.from(row);
  }

  /// Создаёт запись в истории изменений ТМЦ.
  Future<void> _logTmcEvent({
    required String tmcId,
    required String eventType,
    required double quantityChange,
    String? note,
  }) async {
    try {
      final userId = _supabase.auth.currentUser?.id;
      final data = <String, dynamic>{
        'tmc_id': tmcId,
        'event_type': eventType,
        'quantity_change': quantityChange,
        if (note != null) 'note': note,
        'timestamp': DateTime.now().toIso8601String(),
        if (userId != null) 'user_id': userId,
      };
      // вставляем напрямую (без DocDB), чтобы гарантированно не падало по created_by
      await _insertDocSafe(collection: 'tmc_history', data: data);
    } catch (e) {
      debugPrint('⚠️ tmc_history insert error: $e');
    }
  }

  /// История по типу ТМЦ.
  Future<List<Map<String, dynamic>>> fetchHistoryByType(String type) async {
    final ids = _allTmc.where((e) => e.type == type).map((e) => e.id).toList();
    if (ids.isEmpty) return [];
    final rows = await _db.list('tmc_history');
    return rows
        .where((e) => ids.contains((e['data'] as Map<String, dynamic>)['tmc_id']))
        .map((e) => Map<String, dynamic>.from(e['data'] as Map<String, dynamic>))
        .toList();
  }

  /// История по конкретному ТМЦ.
  Future<List<Map<String, dynamic>>> fetchHistoryForItem(String tmcId) async {
    final rows = await _db.list('tmc_history');
    return rows
        .where((e) => (e['data'] as Map<String, dynamic>)['tmc_id'] == tmcId)
        .map((e) => Map<String, dynamic>.from(e['data'] as Map<String, dynamic>))
        .toList()
      ..sort((a, b) {
        final at = DateTime.tryParse(a['timestamp'] ?? '');
        final bt = DateTime.tryParse(b['timestamp'] ?? '');
        if (at == null || bt == null) return 0;
        return at.compareTo(bt);
      });
  }

  // ------ live-стрим из DocDB ------
  void _listenTmc() {
    if (_channel != null) {
      _supabase.removeChannel(_channel!);
      _channel = null;
    }
    fetchTmc();
    _channel = _db.listenCollection('tmc', (row, eventType) async {
      await fetchTmc();
    });
  }

  @override
  void dispose() {
    if (_channel != null) {
      _supabase.removeChannel(_channel!);
    }
    super.dispose();
  }

  // ------ маппинг строки БД в модель ------
  TmcModel _rowToTmc(Map<String, dynamic> m) => TmcModel(
        id: m['id'] as String,
        date: (m['date'] as String?) ?? DateTime.now().toIso8601String(),
        supplier: m['supplier'] as String?,
        type: m['type'] as String,
        description: m['description'] as String,
        quantity: (m['quantity'] as num?)?.toDouble() ?? 0.0,
        unit: m['unit'] as String,
        format: m['format'] as String?,
        grammage: m['grammage'] as String?,
        weight: (m['weight'] as num?)?.toDouble(),
        note: m['note'] as String?,
        imageUrl: m['imageUrl'] as String?,
        imageBase64: m['imageBase64'] as String?,
        lowThreshold: (m['low_threshold'] ?? m['lowThreshold']) is num
            ? (m['low_threshold'] ?? m['lowThreshold']).toDouble()
            : null,
        criticalThreshold: (m['critical_threshold'] ?? m['criticalThreshold']) is num
            ? (m['critical_threshold'] ?? m['criticalThreshold']).toDouble()
            : null,
        createdAt: m['created_at'] as String? ?? m['createdAt'] as String?,
        updatedAt: m['updated_at'] as String? ?? m['updatedAt'] as String?,
      );

  // ------ ручная подгрузка ------
  Future<void> fetchTmc() async {
    final rows = await _db.list('tmc');
    _allTmc
      ..clear()
      ..addAll(rows.map((e) {
        final data = Map<String, dynamic>.from(e['data'] as Map);
        // переносим системные поля, если DocDB их возвращает
        if (e.containsKey('created_at')) data['created_at'] = e['created_at'];
        if (e.containsKey('updated_at')) data['updated_at'] = e['updated_at'];
        data['id'] = e['id']; // id из documents
        return _rowToTmc(data);
      }));
    notifyListeners();
  }

  List<TmcModel> getTmcByType(String type) =>
      _allTmc.where((e) => e.type == type).toList();

  // =========================================================
  // СОЗДАНИЕ
  // =========================================================
  Future<void> addTmc({
    String? id,
    String? supplier,
    required String type,
    required String description,
    required double quantity,
    required String unit,
    String? note,
    String? format,
    String? grammage,
    double? weight,
    double? lowThreshold,
    double? criticalThreshold,
    Uint8List? imageBytes,
    String imageContentType = 'image/jpeg',
    String? imageBase64,
    String? imageUrl,
  }) async {
    final newId = id ?? const Uuid().v4();

    String? finalBase64;
    if (imageBytes != null && imageBytes.isNotEmpty) {
      finalBase64 = base64Encode(imageBytes);
    } else if (imageBase64 != null && imageBase64.isNotEmpty) {
      finalBase64 = imageBase64;
    }

    String? finalImageUrl = imageUrl;
    if (finalImageUrl == null) {
      Uint8List? bytes;
      if (imageBytes != null && imageBytes.isNotEmpty) {
        bytes = imageBytes;
      } else if (imageBase64 != null && imageBase64.isNotEmpty) {
        try {
          bytes = base64Decode(imageBase64);
        } catch (e) {
          debugPrint('⚠️ imageBase64 decode failed: $e');
        }
      }
      if (bytes != null && bytes.isNotEmpty) {
        finalImageUrl = await _uploadImage(newId, bytes, imageContentType);
      }
    }

    final data = <String, dynamic>{
      'id': newId, // храним для удобства маппинга
      'date': DateTime.now().toIso8601String(),
      'supplier': supplier,
      'type': type,
      'description': description,
      'quantity': quantity,
      'unit': unit,
      if (format != null) 'format': format,
      if (grammage != null) 'grammage': grammage,
      if (weight != null) 'weight': weight,
      'note': note,
      if (finalBase64 != null) 'imageBase64': finalBase64,
      if (finalImageUrl != null) 'imageUrl': finalImageUrl,
      if (lowThreshold != null) 'low_threshold': lowThreshold,
      if (criticalThreshold != null) 'critical_threshold': criticalThreshold,
    };

    try {
      // ❗ Важно: вставляем напрямую через Supabase, чтобы created_by не был NULL.
      final inserted = await _insertDocSafe(
        collection: 'tmc',
        data: data,
        explicitId: newId, // uuid из Uuid().v4()
      );

      final map = Map<String, dynamic>.from(inserted['data'] as Map);
      map['id'] = inserted['id'];
      // перенос системных полей, если понадобятся в UI
      if (inserted.containsKey('created_at')) map['created_at'] = inserted['created_at'];
      if (inserted.containsKey('updated_at')) map['updated_at'] = inserted['updated_at'];

      _allTmc.add(_rowToTmc(map));
      notifyListeners();

      await _logTmcEvent(
        tmcId: inserted['id'] as String,
        eventType: 'add',
        quantityChange: quantity,
        note: note,
      );
    } catch (e) {
      debugPrint('❌ addTmc error: $e');
      rethrow;
    }
  }

  // =========================================================
  // ОБНОВЛЕНИЕ
  // =========================================================
  Future<void> updateTmc({
    required String id,
    String? description,
    String? unit,
    double? quantity,
    String? supplier,
    String? note,
    String? format,
    String? grammage,
    double? weight,
    double? lowThreshold,
    double? criticalThreshold,
    Uint8List? imageBytes,
    String imageContentType = 'image/jpeg',
    String? imageBase64,
    String? imageUrl,
  }) async {
    final updates = <String, dynamic>{};
    if (description != null) updates['description'] = description;
    if (unit != null) updates['unit'] = unit;
    if (quantity != null) updates['quantity'] = quantity;
    if (supplier != null) updates['supplier'] = supplier;
    if (note != null) updates['note'] = note;
    if (format != null) updates['format'] = format;
    if (grammage != null) updates['grammage'] = grammage;
    if (weight != null) updates['weight'] = weight;
    if (lowThreshold != null) updates['low_threshold'] = lowThreshold;
    if (criticalThreshold != null) updates['critical_threshold'] = criticalThreshold;

    String? finalBase64;
    if (imageBytes != null && imageBytes.isNotEmpty) {
      finalBase64 = base64Encode(imageBytes);
    } else if (imageBase64 != null && imageBase64.isNotEmpty) {
      finalBase64 = imageBase64;
    }

    String? finalImageUrl = imageUrl;
    if (finalImageUrl == null) {
      Uint8List? bytes;
      if (imageBytes != null && imageBytes.isNotEmpty) {
        bytes = imageBytes;
      } else if (imageBase64 != null && imageBase64.isNotEmpty) {
        try {
          bytes = base64Decode(imageBase64);
        } catch (e) {
          debugPrint('⚠️ imageBase64 decode failed: $e');
        }
      }
      if (bytes != null && bytes.isNotEmpty) {
        finalImageUrl = await _uploadImage(id, bytes, imageContentType);
      }
    }

    if (finalBase64 != null) updates['imageBase64'] = finalBase64;
    if (finalImageUrl != null) updates['imageUrl'] = finalImageUrl;

    if (updates.isEmpty) return;

    final idx = _allTmc.indexWhere((e) => e.id == id);
    TmcModel? prev;
    if (idx != -1) {
      prev = _allTmc[idx];
      final patched = TmcModel(
        id: prev.id,
        date: prev.date,
        supplier: updates['supplier'] ?? prev.supplier,
        type: prev.type,
        description: updates['description'] ?? prev.description,
        quantity: (updates['quantity'] as double?) ?? prev.quantity,
        unit: updates['unit'] ?? prev.unit,
        format: updates['format'] ?? prev.format,
        grammage: updates['grammage'] ?? prev.grammage,
        weight: (updates['weight'] as double?) ?? prev.weight,
        note: updates['note'] ?? prev.note,
        imageUrl: updates['imageUrl'] ?? prev.imageUrl,
        imageBase64: updates['imageBase64'] ?? prev.imageBase64,
        lowThreshold: (updates['low_threshold'] as double?) ?? prev.lowThreshold,
        criticalThreshold: (updates['critical_threshold'] as double?) ?? prev.criticalThreshold,
        createdAt: prev.createdAt,
        updatedAt: prev.updatedAt,
      );
      _allTmc[idx] = patched;
      notifyListeners();
    }

    try {
      await _db.patchById(id, updates);

      if (prev != null && updates.containsKey('quantity')) {
        final double oldQty = prev.quantity;
        final double newQty = updates['quantity'] as double? ?? oldQty;
        final diff = newQty - oldQty;
        if (diff != 0) {
          final eventType = diff > 0 ? 'increase' : 'decrease';
          await _logTmcEvent(
            tmcId: id,
            eventType: eventType,
            quantityChange: diff,
            note: updates['note'] as String?,
          );
        }
      }

      final fresh = await _db.getById(id);
      if (fresh != null) {
        final map = Map<String, dynamic>.from(fresh['data'] as Map);
        map['id'] = fresh['id'];
        if (fresh.containsKey('created_at')) map['created_at'] = fresh['created_at'];
        if (fresh.containsKey('updated_at')) map['updated_at'] = fresh['updated_at'];
        if (idx != -1) {
          _allTmc[idx] = _rowToTmc(map);
          notifyListeners();
        } else {
          await fetchTmc();
        }
      }
    } catch (e) {
      if (idx != -1 && prev != null) {
        _allTmc[idx] = prev;
        notifyListeners();
      }
      debugPrint('❌ updateTmc error: $e');
      rethrow;
    }
  }

  Future<void> updateTmcQuantity({
    required String id,
    required double newQuantity,
  }) async {
    await updateTmc(id: id, quantity: newQuantity);
  }

  // ------ удаление ------
  Future<void> deleteTmc(String id) async {
    final idx = _allTmc.indexWhere((e) => e.id == id);
    if (idx == -1) return;

    final removed = _allTmc.removeAt(idx);
    notifyListeners();

    try {
      await _db.deleteById(id);
      await _logTmcEvent(
        tmcId: id,
        eventType: 'delete',
        quantityChange: -removed.quantity,
        note: removed.note,
      );
    } catch (e) {
      _allTmc.insert(idx, removed);
      notifyListeners();
      debugPrint('❌ deleteTmc error: $e');
      rethrow;
    }
  }

  // ------ документы ------
  Future<void> registerShipment({
    required String receiver,
    required String product,
    required double quantity,
    required String document,
  }) async {
    final data = {
      'receiver': receiver,
      'product': product,
      'quantity': quantity,
      'document': document,
      'date': DateTime.now().toIso8601String(),
    };
    await _insertDocSafe(collection: 'shipments', data: data);
  }

  Future<void> registerReturn({
    required bool isToSupplier,
    required String partner,
    required String product,
    required double quantity,
    required String reason,
    required String note,
  }) async {
    final data = {
      'direction': isToSupplier ? 'to_supplier' : 'from_client',
      'partner': partner,
      'product': product,
      'quantity': quantity,
      'reason': reason,
      'note': note,
      'date': DateTime.now().toIso8601String(),
    };
    await _insertDocSafe(collection: 'returns', data: data);
  }

  // =========================================================
  // ЗАГРУЗКА ФОТО В STORAGE (bucket: 'tmc')
  // =========================================================
  Future<String> _uploadImage(String id, Uint8List bytes, String contentType) async {
    final ext = contentType.split('/').last; // jpeg | png | webp
    final path = 'tmc/$id/${DateTime.now().millisecondsSinceEpoch}.$ext';

    await _supabase.storage.from('tmc').uploadBinary(
      path,
      bytes,
      fileOptions: FileOptions(
        contentType: contentType,
        upsert: true,
      ),
    );

    return _supabase.storage.from('tmc').getPublicUrl(path);
  }

  /// Удаляет всю таблицу (тип) со склада: удаляет все записи tmc с данным [type].
  Future<void> deleteType(String type) async {
    try {
      final rows = await _db.list('tmc');
      for (final row in rows) {
        final data = row['data'] as Map<String, dynamic>;
        final rid = row['id'] as String;
        if (data['type'] == type) {
          await _db.deleteById(rid);
        }
      }
      _allTmc.removeWhere((e) => e.type == type);
      notifyListeners();
    } catch (e) {
      debugPrint('❌ deleteType failed: $e');
      rethrow;
    }
  }
}
