import 'dart:async';
import 'dart:typed_data';
import 'dart:convert'; // base64Decode
import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:uuid/uuid.dart';

import 'tmc_model.dart';

class WarehouseProvider with ChangeNotifier {
  final SupabaseClient _supabase = Supabase.instance.client;

  final List<TmcModel> _allTmc = [];
  StreamSubscription<List<Map<String, dynamic>>>? _tmcSub;

  List<TmcModel> get allTmc => List.unmodifiable(_allTmc);

  WarehouseProvider() {
    _listenTmc();
  }

  /// Создаёт запись в истории изменений ТМЦ. Используется для
  /// отслеживания всех операций со склада: добавление, изменение,
  /// списание и удаление. В таблице `tmc_history` хранится id
  /// операции, ссылка на исходную запись `tmc_id`, тип события,
  /// величина изменения (положительная при приходе, отрицательная
  /// при списании), комментарий (если есть), пользователь и метка
  /// времени.
  Future<void> _logTmcEvent({
    required String tmcId,
    required String eventType,
    required double quantityChange,
    String? note,
  }) async {
    try {
      final userId = Supabase.instance.client.auth.currentUser?.id;
      final data = <String, dynamic>{
        'id': const Uuid().v4(),
        'tmc_id': tmcId,
        'event_type': eventType,
        'quantity_change': quantityChange,
        if (note != null) 'note': note,
        'timestamp': DateTime.now().toIso8601String(),
        if (userId != null) 'user_id': userId,
      };
      await _supabase.from('tmc_history').insert(data);
    } catch (e) {
      // Логирование ошибок не должно останавливать основной поток
      debugPrint('⚠️ tmc_history insert error: $e');
    }
  }

  /// Возвращает список событий для всех ТМЦ указанного типа. Используется для отображения
  /// истории в интерфейсе склада. Если записей нет — возвращает пустой список.
  Future<List<Map<String, dynamic>>> fetchHistoryByType(String type) async {
    final ids = _allTmc.where((e) => e.type == type).map((e) => e.id).toList();
    if (ids.isEmpty) return [];
    final rows = await _supabase
        .from('tmc_history')
        .select()
        .inFilter('tmc_id', ids);
    return (rows as List?)?.map((e) => Map<String, dynamic>.from(e)).toList() ?? [];
  }

  /// Возвращает историю операций для конкретной записи склада [tmcId].
  Future<List<Map<String, dynamic>>> fetchHistoryForItem(String tmcId) async {
    final rows = await _supabase
        .from('tmc_history')
        .select()
        .eq('tmc_id', tmcId)
        .order('timestamp');
    return (rows as List?)?.map((e) => Map<String, dynamic>.from(e)).toList() ?? [];
  }

  // ------ live-стрим из Supabase ------
  void _listenTmc() {
    _tmcSub?.cancel();
    _tmcSub = _supabase
        .from('tmc')
        .stream(primaryKey: ['id'])
        .listen((rows) {
      _allTmc
        ..clear()
        ..addAll(rows.map((r) => _rowToTmc(Map<String, dynamic>.from(r))));
      notifyListeners();
    });
  }

  @override
  void dispose() {
    _tmcSub?.cancel();
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
        // поле в модели оставлено для обратной совместимости
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

  // ------ ручная подгрузка (если нужно) ------
  Future<void> fetchTmc() async {
    final rows = await _supabase.from('tmc').select();
    _allTmc
      ..clear()
      ..addAll((rows as List).map((e) => _rowToTmc(Map<String, dynamic>.from(e))));
    notifyListeners();
  }

  List<TmcModel> getTmcByType(String type) =>
      _allTmc.where((e) => e.type == type).toList();

  // =========================================================
  // СОЗДАНИЕ
  // Поддерживаем три способа:
  // 1) imageBytes (+ imageContentType) — РЕКОМЕНДУЕМЫЙ (загрузка в Storage)
  // 2) imageBase64 (строка) — декодируем и грузим в Storage
  // 3) imageUrl — просто пишем в БД (без загрузки)
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
    // добавляем пороговые значения. если null — колонка не заполняется
    double? lowThreshold,
    double? criticalThreshold,

    Uint8List? imageBytes,
    String imageContentType = 'image/jpeg',

    String? imageBase64, // для совместимости со старым кодом
    String? imageUrl,    // для совместимости со старым кодом
  }) async {
    final newId = id ?? const Uuid().v4();

    // Сохраним base64‑строку изображения, чтобы иметь локальный превью без загрузки
    String? finalBase64;
    if (imageBytes != null && imageBytes.isNotEmpty) {
      finalBase64 = base64Encode(imageBytes);
    } else if (imageBase64 != null && imageBase64.isNotEmpty) {
      finalBase64 = imageBase64;
    }

    // 1) Определяем imageUrl: либо прямо пришёл, либо заливаем картинку
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
        // Загружаем изображение в Storage, но не блокируем отображение превью
        finalImageUrl = await _uploadImage(newId, bytes, imageContentType);
      }
    }

    // 2) Пишем запись в tmc. Теперь сохраняем и imageBase64, и imageUrl,
    // чтобы таблица красок могла отобразить превью сразу без скачивания.
    final data = <String, dynamic>{
      'id': newId,
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
      final inserted = await _supabase
          .from('tmc')
          .insert(data)
          .select()
          .single() as Map<String, dynamic>;
      _allTmc.add(_rowToTmc(inserted));
      notifyListeners();

      // Записываем событие добавления в историю склада. Количество всегда
      // положительное, т.к. происходит приход.
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
  // Поддерживаем:
  // - imageBytes (приоритет) -> загрузка в Storage
  // - imageBase64 -> загрузка в Storage
  // - imageUrl -> установить напрямую
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
    // пороговые значения. если null — не изменяем
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

    // Подготовим base64‑строку для обновления (если передано фото)
    String? finalBase64;
    if (imageBytes != null && imageBytes.isNotEmpty) {
      finalBase64 = base64Encode(imageBytes);
    } else if (imageBase64 != null && imageBase64.isNotEmpty) {
      finalBase64 = imageBase64;
    }

    // Вычисляем новый imageUrl (если что-то из картинки передали)
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

    if (finalBase64 != null) {
      updates['imageBase64'] = finalBase64;
    }
    if (finalImageUrl != null) {
      updates['imageUrl'] = finalImageUrl;
    }

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
      final updated = await _supabase
          .from('tmc')
          .update(updates)
          .eq('id', id)
          .select()
          .single() as Map<String, dynamic>;

      // Если количество изменилось, вычисляем разницу и логируем событие
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

      if (idx != -1) {
        _allTmc[idx] = _rowToTmc(updated);
        notifyListeners();
      } else {
        await fetchTmc();
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
      await _supabase.from('tmc').delete().eq('id', id);
      // Логируем удаление: количество записываем как отрицательное целое значение
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
      'id': const Uuid().v4(),
      'date': DateTime.now().toIso8601String(),
      'receiver': receiver,
      'product': product,
      'quantity': quantity,
      'document': document,
    };
    await _supabase.from('shipments').insert(data).select().single();
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
      'id': const Uuid().v4(),
      'date': DateTime.now().toIso8601String(),
      'direction': isToSupplier ? 'to_supplier' : 'from_client',
      'partner': partner,
      'product': product,
      'quantity': quantity,
      'reason': reason,
      'note': note,
    };
    await _supabase.from('returns').insert(data).select().single();
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
      await _supabase.from('tmc').delete().eq('type', type);
      _allTmc.removeWhere((e) => e.type == type);
      notifyListeners();
    } catch (e) {
      debugPrint('❌ deleteType failed: $e');
      rethrow;
    }
  }
}
