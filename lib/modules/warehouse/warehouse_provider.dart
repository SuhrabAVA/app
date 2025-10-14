import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:uuid/uuid.dart';

import 'tmc_model.dart';
import '../../utils/auth_helper.dart';
import '../../services/app_auth.dart';
import '../../utils/kostanay_time.dart';

class WarehouseProvider with ChangeNotifier {
  // ====== PENS DEDICATED TABLE RESOLUTION ======
  String? _resolvedPensTable; // e.g. 'handles', 'pens', 'warehouse_pens', etc.

  Future<String?> _resolvePensTable() async {
    if (_resolvedPensTable != null) {
      return _resolvedPensTable;
    }

    const candidates = <String>['warehouse_pens', 'pens', 'handles'];
    for (final table in candidates) {
      try {
        await _sb.from(table).select('id').limit(1);
        _resolvedPensTable = table;
        return _resolvedPensTable;
      } on PostgrestException catch (error) {
        if (_isMissingRelationError(error, table)) {
          continue;
        }
        _resolvedPensTable = table;
        return _resolvedPensTable;
      } catch (_) {
        continue;
      }
    }

    _resolvedPensTable = 'warehouse_stationery';
    return _resolvedPensTable;
  }

  bool get _pensUseStationeryFallback {
    final resolved = _resolvedPensTable;
    if (resolved == null) return false;
    return resolved.toLowerCase().contains('stationery');
  }

  final SupabaseClient _sb = Supabase.instance.client;

  /// Ключ подтаблицы канцтоваров (warehouse_stationery.table_key).
  /// Для экрана «Ручки» используем 'ручки'.
  String _stationeryKey = 'канцелярия';
  String get stationeryKey => _stationeryKey;

  void setStationeryKey(String key) {
    final k = key.trim();
    if (k.isEmpty || k == _stationeryKey) return;
    _stationeryKey = k;
    _resubscribeStationery();
    fetchTmc();
  }

  RealtimeChannel? _chanPaints;
  RealtimeChannel? _chanMaterials;
  RealtimeChannel? _chanPapers;
  RealtimeChannel? _chanStationery;

  final List<TmcModel> _allTmc = [];
  List<TmcModel> get allTmc => List.unmodifiable(_allTmc);

  final Map<String, List<Map<String, dynamic>>> _writeoffsByItem = {};
  final Map<String, List<Map<String, dynamic>>> _inventoriesByItem = {};
  List<Map<String, dynamic>> writeoffs(String itemId) =>
      List.unmodifiable(_writeoffsByItem[itemId] ?? const []);
  List<Map<String, dynamic>> inventories(String itemId) =>
      List.unmodifiable(_inventoriesByItem[itemId] ?? const []);

  static const Map<String, Map<String, String>> _arrMap = {
    'paint': {'table': 'paints_arrivals', 'fk': 'paint_id', 'qty': 'qty'},
    'material': {
      'table': 'materials_arrivals',
      'fk': 'material_id',
      'qty': 'qty'
    },
    'paper': {'table': 'papers_arrivals', 'fk': 'paper_id', 'qty': 'qty'},
    'stationery': {
      'table': 'warehouse_stationery_arrivals',
      'fk': 'item_id',
      'qty': 'qty'
    },
    'pens': {'table': 'warehouse_pens_arrivals', 'fk': 'item_id', 'qty': 'qty'},
  };

  static const Map<String, Map<String, String>> _invMap = {
    'paint': {
      'table': 'paints_inventories',
      'fk': 'paint_id',
      'qty': 'counted_qty',
      'note': 'note'
    },
    'material': {
      'table': 'materials_inventories',
      'fk': 'material_id',
      'qty': 'counted_qty',
      'note': 'note'
    },
    'paper': {
      'table': 'papers_inventories',
      'fk': 'paper_id',
      'qty': 'counted_qty',
      'note': 'note'
    },
    'stationery': {
      'table': 'warehouse_stationery_inventories',
      'fk': 'item_id',
      'qty': 'factual',
      'note': 'note'
    },
    'pens': {
      'table': 'warehouse_pens_inventories',
      'fk': 'item_id',
      'qty': 'counted_qty',
      'note': 'note'
    },
  };

  WarehouseProvider() {
    _init();
  }

  Future<void> _init() async {
    try {
      await _ensureAuthed();
      _listen();
      await fetchTmc();
    } catch (e) {
      debugPrint('❌ init warehouse: $e');
    }
  }

  Future<void> _ensureAuthed() async {
    await AppAuth.ensureSignedIn();
  }

  @override
  void dispose() {
    if (_chanPaints != null) _sb.removeChannel(_chanPaints!);
    if (_chanMaterials != null) _sb.removeChannel(_chanMaterials!);
    if (_chanPapers != null) _sb.removeChannel(_chanPapers!);
    if (_chanStationery != null) _sb.removeChannel(_chanStationery!);
    super.dispose();
  }

  // ===================== LIVE =====================
  void _listen() {
    _chanPaints = _sb
        .channel('wh:paints')
        .onPostgresChanges(
          event: PostgresChangeEvent.all,
          schema: 'public',
          table: 'paints',
          callback: (_) => fetchTmc(),
        )
        .subscribe();

    _chanMaterials = _sb
        .channel('wh:materials')
        .onPostgresChanges(
          event: PostgresChangeEvent.all,
          schema: 'public',
          table: 'materials',
          callback: (_) => fetchTmc(),
        )
        .subscribe();

    _chanPapers = _sb
        .channel('wh:papers')
        .onPostgresChanges(
          event: PostgresChangeEvent.all,
          schema: 'public',
          table: 'papers',
          callback: (_) => fetchTmc(),
        )
        .subscribe();

    _resubscribeStationery();
  }

  void _resubscribeStationery() {
    if (_chanStationery != null) {
      _sb.removeChannel(_chanStationery!);
      _chanStationery = null;
    }
    _chanStationery = _sb
        .channel('wh:stationery:${_stationeryKey}')
        .onPostgresChanges(
          event: PostgresChangeEvent.all,
          schema: 'public',
          table: 'warehouse_stationery',
          callback: (_) => fetchTmc(),
        )
        .subscribe();
  }

  // ===================== LOAD =====================
  Future<void> fetchTmc({bool factual = false}) async {
    try {
      await _ensureAuthed();

      final p = await _sb.from('paints').select().order('description');
      final m = await _sb.from('materials').select().order('description');
      final pr = await _sb.from('papers').select().order('description');

      // --- Stationery (with optional dedicated pens table) ---
      List s = [];
      try {
        final keyLc = (_stationeryKey).toLowerCase().trim();
        final isPens =
            keyLc == 'ручки' || keyLc == 'pens' || keyLc == 'handles';
        String? pensTable;
        if (isPens) {
          pensTable = await _resolvePensTable();
          final bool useFallback =
              pensTable == null || _pensUseStationeryFallback;
          if (!useFallback && pensTable != null) {
            // warehouse_pens обычно не имеет 'description' -> сортируем по created_at
            final pensRaw =
                await _sb.from(pensTable).select().order('created_at');
            s = (pensRaw as List)
                .map((e) => Map<String, dynamic>.from(e))
                .toList();
            s = s.map((row) {
              row['__force_type__'] = 'pens';
              return row;
            }).toList();
          } else {
            final pensKeys = _tableKeyCandidatesFor('pens')
                .map((k) => k.toLowerCase())
                .toSet();
            final sRaw = await _sb
                .from('warehouse_stationery')
                .select()
                .order('description');
            final filtered = (sRaw as List)
                .where((row) => pensKeys.contains(
                      (row['table_key'] ?? '').toString().toLowerCase().trim(),
                    ))
                .toList();
            s = filtered.map((e) {
              final mapped = Map<String, dynamic>.from(e);
              mapped['__force_type__'] = 'pens';
              return mapped;
            }).toList();
          }
        } else {
          final sRaw = await _sb
              .from('warehouse_stationery')
              .select()
              .order('description');
          final filtered = (sRaw as List)
              .where((row) =>
                  ((row['table_key'] ?? '').toString().toLowerCase().trim() ==
                      (_stationeryKey).toLowerCase().trim()))
              .toList();
          s = filtered.map((e) => Map<String, dynamic>.from(e)).toList();
        }
      } catch (e) {
        debugPrint('⚠️ load stationery/pens failed: $e');
        s = const [];
      }
      final List<TmcModel> merged = [];
      for (final e in p) {
        merged.add(_fromRow(type: 'paint', row: Map<String, dynamic>.from(e)));
      }
      for (final e in m) {
        merged
            .add(_fromRow(type: 'material', row: Map<String, dynamic>.from(e)));
      }
      for (final e in s) {
        final row = Map<String, dynamic>.from(e);
        final force = row['__force_type__'];
        merged.add(
            _fromRow(type: force == 'pens' ? 'pens' : 'stationery', row: row));
      }
      for (final e in pr) {
        merged.add(_fromRow(type: 'paper', row: Map<String, dynamic>.from(e)));
      }

      // Сортировка по названию (description) для удобства поиска в UI
      merged.sort((a, b) => (a.description ?? '')
          .toLowerCase()
          .compareTo((b.description ?? '').toLowerCase()));
      _allTmc
        ..clear()
        ..addAll(merged);
      notifyListeners();
    } catch (e) {
      debugPrint('❌ fetchTmc: $e');
      rethrow;
    }
  }

  List<TmcModel> getTmcByType(String type) {
    final normalized = _normalizeType(type) ?? type;
    return _allTmc.where((e) => e.type == normalized).toList(growable: false);
  }

  // ===================== ADD =====================
  Future<void> addTmc({
    String? id,
    String? supplier,
    String? type,
    required String description,
    required double quantity,
    required String unit,
    String? note,
    String? format,
    String? grammage,
    double? weight, // оставлено для совместимости вызовов
    double? lowThreshold,
    double? criticalThreshold,
    Uint8List? imageBytes,
    String imageContentType = 'image/jpeg',
    String? imageBase64,
    String? imageUrl,
  }) async {
    await _ensureAuthed();

    final newId = id ?? const Uuid().v4();
    final normalizedType = _normalizeType(type) ??
        _inferType(
          unit: unit,
          format: format,
          grammage: grammage,
          description: description,
        );

    final String? safeNote =
        note != null && note.trim().isNotEmpty ? note.trim() : null;
    String? resolvedImageUrl = imageUrl;
    String? resolvedBase64 = imageBase64;

    Future<void> prepareImage(String targetId) async {
      if (imageBytes != null && imageBytes.isNotEmpty) {
        resolvedImageUrl =
            await _uploadImage(targetId, imageBytes, imageContentType);
        resolvedBase64 ??= base64Encode(imageBytes);
        return;
      }
      if (resolvedImageUrl == null && resolvedBase64 != null) {
        try {
          final bytes = base64Decode(resolvedBase64!);
          if (bytes.isNotEmpty) {
            resolvedImageUrl =
                await _uploadImage(targetId, bytes, imageContentType);
          }
        } catch (_) {}
      }
    }

    if (normalizedType == 'paint') {
      final existing = await _findExistingPaint(description);
      if (existing != null) {
        final existingId = existing['id'] as String;
        await prepareImage(existingId);
        final updatePayload = <String, dynamic>{};
        if (safeNote != null) updatePayload['note'] = safeNote;
        if (lowThreshold != null) {
          updatePayload['low_threshold'] = lowThreshold;
        }
        if (criticalThreshold != null) {
          updatePayload['critical_threshold'] = criticalThreshold;
        }
        if (resolvedImageUrl != null) {
          updatePayload['image_url'] = resolvedImageUrl;
        }
        if (resolvedBase64 != null) {
          updatePayload['image_base64'] = resolvedBase64;
        }
        if (updatePayload.isNotEmpty) {
          await _sb.from('paints').update(updatePayload).eq('id', existingId);
        }
        if (quantity > 0) {
          await _logArrivalGeneric(
            typeKey: 'paint',
            itemId: existingId,
            qty: quantity,
            note: safeNote,
          );
        }
        await fetchTmc();
        return;
      }
    }

    if (normalizedType == 'stationery') {
      final existing = await _findExistingStationery(description);
      if (existing != null) {
        final existingId = existing['id'] as String;
        await prepareImage(existingId);
        final updatePayload = <String, dynamic>{
          'table_key': _stationeryKey,
        };
        final trimmedUnit = unit.trim();
        final currentUnit = (existing['unit'] ?? '').toString().trim();
        if (trimmedUnit.isNotEmpty && trimmedUnit != currentUnit) {
          updatePayload['unit'] = trimmedUnit;
        }
        if (safeNote != null) updatePayload['note'] = safeNote;
        if (lowThreshold != null) {
          updatePayload['low_threshold'] = lowThreshold;
        }
        if (criticalThreshold != null) {
          updatePayload['critical_threshold'] = criticalThreshold;
        }
        if (resolvedImageUrl != null) {
          updatePayload['image_url'] = resolvedImageUrl;
        }
        if (resolvedBase64 != null) {
          updatePayload['image_base64'] = resolvedBase64;
        }
        updatePayload.removeWhere((key, value) => value == null);
        if (updatePayload.isNotEmpty) {
          await _sb
              .from('warehouse_stationery')
              .update(updatePayload)
              .eq('id', existingId);
        }
        if (quantity > 0) {
          await _logArrivalGeneric(
            typeKey: 'stationery',
            itemId: existingId,
            qty: quantity,
            note: safeNote,
          );
        }
        await fetchTmc();
        return;
      }
    }

    await prepareImage(newId);

    // ----------- РУЧКИ (dedicated table) -----------
    if (normalizedType == 'pens') {
      final pensTable = await _resolvePensTable();
      final bool useFallback = pensTable == null || _pensUseStationeryFallback;
      // Expect description like "Вид • Цвет" or just name; try to split
      String raw = description;
      String name = raw;
      String color = '';
      if (raw.contains('•')) {
        final parts = raw.split('•');
        name = parts[0].trim();
        color = parts.sublist(1).join('•').trim();
      } else if (raw.contains('|')) {
        final parts = raw.split('|');
        name = parts[0].trim();
        color = parts.sublist(1).join('|').trim();
      }

      final unitValue = unit.isNotEmpty ? unit : 'пар';
      final String pensDescription =
          [name, color].where((e) => e.trim().isNotEmpty).join(' • ');

      Future<void> insertIntoPensTable(String tableName) async {
        final payload = <String, dynamic>{
          'id': newId,
          'date': nowInKostanayIsoString(),
          'supplier': supplier,
          'name': name,
          'color': color,
          'unit': unitValue,
          'quantity': 0,
          'note': safeNote,
          'low_threshold': lowThreshold ?? 0,
          'critical_threshold': criticalThreshold ?? 0,
          if (resolvedImageUrl != null) 'image_url': resolvedImageUrl,
          if (resolvedBase64 != null) 'image_base64': resolvedBase64,
        };
        await _sb.from(tableName).insert(payload);
      }

      Future<void> insertIntoStationeryFallback() async {
        final fallbackDescription =
            pensDescription.isEmpty ? description : pensDescription;
        final payload = <String, dynamic>{
          'id': newId,
          'date': nowInKostanayIsoString(),
          'supplier': supplier,
          'description': fallbackDescription,
          'unit': unitValue,
          'quantity': 0,
          'note': safeNote,
          'table_key': _stationeryKey.trim().isNotEmpty
              ? _stationeryKey.trim()
              : 'ручки',
          'low_threshold': lowThreshold ?? 0,
          'critical_threshold': criticalThreshold ?? 0,
          if (resolvedImageUrl != null) 'image_url': resolvedImageUrl,
          if (resolvedBase64 != null) 'image_base64': resolvedBase64,
        };
        await _sb.from('warehouse_stationery').insert(payload);
        _resolvedPensTable = 'warehouse_stationery';
      }

      if (!useFallback && pensTable != null) {
        try {
          await insertIntoPensTable(pensTable);
        } on PostgrestException catch (error) {
          if (_isMissingRelationError(error, pensTable)) {
            await insertIntoStationeryFallback();
          } else {
            rethrow;
          }
        }
      } else {
        await insertIntoStationeryFallback();
      }

      await _logArrivalGeneric(
        typeKey: 'pens',
        itemId: newId,
        qty: quantity,
        note: safeNote,
        extraPayload: await _resolvePenLogExtras(
          itemId: newId,
          name: name,
          color: color,
        ),
      );
      await fetchTmc();
      await _logTmcEvent(
        tmcId: newId,
        eventType: 'Приход (ручки)',
        quantityChange: quantity,
        note: safeNote ?? 'Добавление в склад ручек',
      );
      return;
    }

    // ----------- БУМАГА: только arrival_add -> триггер прибавит количество -----------
    if (normalizedType == 'paper') {
      if ((format == null || format.isEmpty) ||
          (grammage == null || grammage.isEmpty)) {
        throw Exception('Для бумаги нужно указать формат и грамаж.');
      }

      // Поиск существующей бумаги
      final existing = await _sb
          .from('papers')
          .select('id')
          .eq('description', description)
          .eq('format', format!)
          .eq('grammage', grammage!)
          .maybeSingle();

      String paperId = existing == null ? newId : existing['id'] as String;

      if (existing == null) {
        // создаём карточку бумаги с quantity = 0
        final body = <String, dynamic>{
          'id': paperId,
          'date': nowInKostanayIsoString(),
          'supplier': supplier,
          'description': description,
          'unit': unit.isNotEmpty ? unit : 'м',
          'quantity': 0,
          'note': safeNote,
          'low_threshold': lowThreshold ?? 0,
          'critical_threshold': criticalThreshold ?? 0,
          'format': format,
          'grammage': grammage,
          if (weight != null) 'weight': weight,
          if (resolvedImageUrl != null) 'image_url': resolvedImageUrl,
          if (resolvedBase64 != null) 'image_base64': resolvedBase64,
        };
        await _sb.from('papers').insert(body);
      }

      if (quantity > 0) {
        await _sb.rpc('arrival_add', params: {
          '_type': 'paper',
          '_item': paperId,
          '_qty': quantity,
          '_note': safeNote,
          '_by_name': (AuthHelper.currentUserName ?? '')
        });
      }

      await fetchTmc();
      return;
    }

    // ----------- Остальные типы -----------
    final bool adjustViaArrival =
        normalizedType == 'paint' || normalizedType == 'stationery';
    final double initialQuantity = adjustViaArrival ? 0 : quantity;

    final common = <String, dynamic>{
      'id': newId,
      'date': nowInKostanayIsoString(),
      'supplier': supplier,
      'description': description,
      'unit': unit,
      'quantity': initialQuantity,
      'note': safeNote,
      'low_threshold': lowThreshold ?? 0,
      'critical_threshold': criticalThreshold ?? 0,
      if (resolvedImageUrl != null) 'image_url': resolvedImageUrl,
      if (resolvedBase64 != null) 'image_base64': resolvedBase64,
    };

    try {
      if (normalizedType == 'paint') {
        await _sb.from('paints').insert(common);
        if (quantity > 0) {
          await _logArrivalGeneric(
            typeKey: 'paint',
            itemId: newId,
            qty: quantity,
            note: safeNote,
          );
        }
      } else if (normalizedType == 'material') {
        await _sb.from('materials').insert(common);
      } else if (normalizedType == 'stationery') {
        final body = {
          ...common,
          'table_key': _stationeryKey,
          'type': 'stationery',
        };
        await _sb.from('warehouse_stationery').insert(body);
        if (quantity > 0) {
          await _logArrivalGeneric(
            typeKey: 'stationery',
            itemId: newId,
            qty: quantity,
            note: safeNote,
          );
        }
      } else {
        throw Exception('Неизвестный type: $normalizedType');
      }

      await fetchTmc();
    } catch (e) {
      debugPrint('❌ addTmc error: $e');
      rethrow;
    }
  }

  /// Явное пополнение бумаги по ID бумаги.
  Future<void> addPaperArrival({
    required String paperId,
    required double qty,
    String? note,
  }) async {
    await _ensureAuthed();
    if (qty <= 0) return;
    await _sb.rpc('arrival_add', params: {
      '_type': 'paper',
      '_item': paperId,
      '_qty': qty,
      '_note': note,
      '_by_name': (AuthHelper.currentUserName ?? '')
    });
    await fetchTmc();
  }

  // ===================== UPDATE =====================
  Future<void> updateTmc({
    required String id,
    String? type,
    String? supplier,
    String? description,
    double? quantity,
    String? unit,
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
    await _ensureAuthed();

    String? resolvedType = _normalizeType(type);
    if (resolvedType == null) {
      resolvedType = await _detectTypeById(id) ?? 'material';
    }

    String? finalImageUrl = imageUrl;
    String? finalBase64 = imageBase64;
    if (imageBytes != null && imageBytes.isNotEmpty) {
      finalImageUrl = await _uploadImage(id, imageBytes, imageContentType);
      finalBase64 ??= base64Encode(imageBytes);
    }

    final patch = <String, dynamic>{
      if (supplier != null) 'supplier': supplier,
      if (description != null) 'description': description,
      if (quantity != null) 'quantity': quantity,
      if (unit != null) 'unit': unit,
      if (note != null) 'note': note,
      if (lowThreshold != null) 'low_threshold': lowThreshold,
      if (criticalThreshold != null) 'critical_threshold': criticalThreshold,
      if (finalImageUrl != null) 'image_url': finalImageUrl,
      if (finalBase64 != null) 'image_base64': finalBase64,
    };

    try {
      if (resolvedType == 'paper') {
        if (format != null) patch['format'] = format;
        if (grammage != null) patch['grammage'] = grammage;
        if (weight != null) patch['weight'] = weight;
      }

      final table = _tableByType(resolvedType);
      await _sb.from(table).update(patch).eq('id', id);

      await fetchTmc();
    } catch (e) {
      debugPrint('❌ updateTmc error: $e');
      rethrow;
    }
  }

  Future<void> updateTmcQuantity({
    required String id,
    String? type,
    double? delta,
    double? newQuantity,
  }) async {
    await _ensureAuthed();

    String? resolvedType = _normalizeType(type);
    if (resolvedType == null) {
      resolvedType = await _detectTypeById(id) ?? 'material';
    }
    final table = _tableByType(resolvedType);
    try {
      if (newQuantity != null) {
        await _sb.from(table).update(
            {'quantity': newQuantity < 0 ? 0 : newQuantity}).eq('id', id);
      } else {
        final row =
            await _sb.from(table).select('quantity').eq('id', id).single();
        final current = (row['quantity'] as num).toDouble();
        final next = (current + (delta ?? 0));
        await _sb
            .from(table)
            .update({'quantity': next < 0 ? 0 : next}).eq('id', id);
      }
      await fetchTmc();
    } catch (e) {
      debugPrint('❌ updateTmcQuantity: $e');
      rethrow;
    }
  }

  Future<void> registerShipment({
    required String id,
    required String type,
    required double qty,
    String? reason,
  }) async {
    await _ensureAuthed();
    try {
      final resolvedType = _normalizeType(type) ?? type;
      final table = _tableByType(resolvedType);
      final row =
          await _sb.from(table).select('quantity').eq('id', id).maybeSingle();
      double currentQty = 0;
      if (row != null && row is Map<String, dynamic>) {
        final q = row['quantity'];
        if (q is num) currentQty = q.toDouble();
      }
      if (qty > currentQty) {
        throw Exception('Недостаточно материала на складе');
      }
      await _sb.rpc('writeoff', params: {
        'type': resolvedType,
        'item': id,
        'qty': qty,
        'reason': reason,
        'by_name': (AuthHelper.currentUserName ?? '')
      });
      await fetchTmc();
    } catch (e) {
      debugPrint('❌ registerShipment (fallback writeOff): $e');
      if (e.toString().contains('Недостаточно')) rethrow;
      await writeOff(itemId: id, qty: qty, reason: reason);
    }
  }

  Future<void> registerReturn({
    required String id,
    required String type,
    required double qty,
    String? note,
  }) async {
    await _ensureAuthed();

    try {
      final resolvedType = _normalizeType(type) ?? type;
      final table = _tableByType(resolvedType);
      final row =
          await _sb.from(table).select('quantity').eq('id', id).single();
      final current = (row['quantity'] as num).toDouble();
      await _sb.from(table).update({'quantity': current + qty}).eq('id', id);
      await fetchTmc();
    } catch (e) {
      debugPrint('❌ registerReturn: $e');
      rethrow;
    }
  }

  Future<void> deleteTmc(String id, {String? type}) async {
    await _ensureAuthed();

    String? resolvedType = _normalizeType(type);
    if (resolvedType == null) {
      resolvedType = await _detectTypeById(id) ?? 'material';
    }
    final table = _tableByType(resolvedType);
    try {
      await _sb.from(table).delete().eq('id', id);
      _allTmc.removeWhere((e) => e.id == id && e.type == resolvedType);
      notifyListeners();
    } catch (e) {
      debugPrint('❌ deleteTmc failed: $e');
      rethrow;
    }
  }

  Future<void> deleteType(String type) async {
    await _ensureAuthed();

    final resolvedType = _normalizeType(type) ?? type;
    final table = _tableByType(resolvedType);
    try {
      if (resolvedType == 'stationery') {
        await _sb
            .from('warehouse_stationery')
            .delete()
            .eq('table_key', _stationeryKey);
        _allTmc.removeWhere((e) => e.type == 'stationery');
      } else {
        await _sb.from(table).delete().neq('id', '');
        _allTmc.removeWhere((e) => e.type == resolvedType);
      }
      notifyListeners();
    } catch (e) {
      debugPrint('❌ deleteType failed: $e');
      rethrow;
    }
  }

  // ===================== Канцтовары/Ручки: списание / инвентаризация =====================
  Future<void> writeOff({
    required String itemId,
    required double qty,
    String? reason,
    String? typeHint,
    double? currentQty,
  }) async {
    await _ensureAuthed();
    String itemType = _normalizeType(typeHint) ??
        (await _detectTypeById(itemId) ?? 'stationery');
    if (itemType == 'pens') {
      await _resolvePensTable();
    }
    final byName = (AuthHelper.currentUserName ?? '').trim().isEmpty
        ? (AuthHelper.isTechLeader ? 'Технический лидер' : '—')
        : AuthHelper.currentUserName!;

    Map<String, String> penExtras = const {};

    final payload = <String, dynamic>{
      'item_id': itemId,
      'qty': qty,
      if (reason != null && reason.isNotEmpty) 'reason': reason,
      'by_name': byName,
      'employee': byName,
    };
    if (itemType == 'pens') {
      penExtras = await _resolvePenLogExtras(itemId: itemId);
      payload.addAll(penExtras);
    }

    Future<bool> insertInto(String table, Map<String, dynamic> data) async {
      return _tryInsertWarehouseLog(table, data);
    }

    bool inserted = false;
    PostgrestException? initialError;
    final bool pensFallback = itemType == 'pens' && _pensUseStationeryFallback;
    final table = itemType == 'pens'
        ? (pensFallback
            ? 'warehouse_stationery_writeoffs'
            : 'warehouse_pens_writeoffs')
        : 'warehouse_stationery_writeoffs';
    try {
      inserted = await insertInto(table, payload);
    } on PostgrestException catch (e) {
      initialError = e;
    }

    if (!inserted) {
      final String tableName =
          (itemType == 'pens') ? 'warehouse_pens_writeoffs' : table;
      final code = (initialError?.code ?? '').toString().toLowerCase();
      final message = (initialError?.message ?? '').toLowerCase();
      if (itemType == 'pens' &&
          (initialError == null ||
              _isMissingRelationError(initialError, tableName) ||
              message.contains('warehouse_pens_writeoffs'))) {
        for (final key in _tableKeyCandidatesFor('pens')) {
          final fallback = Map<String, dynamic>.from(payload)
            ..['table_key'] = key;
          inserted =
              await insertInto('warehouse_stationery_writeoffs', fallback);
          if (inserted) break;
        }
        if (!inserted) {
          inserted = await insertInto(
            'warehouse_stationery_writeoffs',
            Map<String, dynamic>.from(payload),
          );
        }
      } else if (initialError != null &&
          !_isMissingRelationError(initialError, tableName)) {
        throw initialError!;
      }
    }

    if (!inserted) {
      throw Exception('Не удалось сохранить списание для $itemType');
    }

    final list = _writeoffsByItem.putIfAbsent(itemId, () => []);
    final writeoffEntry = {
      'item_id': itemId,
      'qty': qty,
      'reason': reason,
      'created_at': DateTime.now().toUtc().toIso8601String(),
      'by_name': byName,
    };
    if (itemType == 'pens') {
      writeoffEntry.addAll(penExtras);
    }
    list.insert(0, writeoffEntry);

    await fetchTmc();
  }

  Future<void> inventorySet({
    required String itemId,
    double? newQty,
    double? factual,
    String? note,
    String? typeHint,
  }) async {
    final double invValue = newQty ?? factual ?? 0;
    final rawNote = note?.trim() ?? '';
    final String? trimmedNote = rawNote.isEmpty ? null : rawNote;
    await _ensureAuthed();
    final itemType = _normalizeType(typeHint) ??
        (await _detectTypeById(itemId) ?? 'stationery');
    if (itemType == 'pens') {
      await _resolvePensTable();
    }
    final tables = _inventoryTables(itemType);
    final String? createdBy = _sb.auth.currentUser?.id;
    final fkCandidates = <String>{
      'item_id',
      'stationery_id',
      'paper_id',
      'paint_id',
      'material_id',
      'tmc_id',
      'fk_id',
      if (_invMap[itemType]?['fk'] != null) _invMap[itemType]!['fk']!,
    }.toList();
    final qtyColumns = <String>{
      'counted_qty',
      'quantity',
      'qty',
      'factual',
      if (_invMap[itemType]?['qty'] != null) _invMap[itemType]!['qty']!,
    }.toList();
    final noteColumns = <String>{
      'note',
      'comment',
      'reason',
      if (_invMap[itemType]?['note'] != null) _invMap[itemType]!['note']!,
    }.toList();
    final byName = (AuthHelper.currentUserName ?? '').trim().isEmpty
        ? (AuthHelper.isTechLeader ? 'Технический лидер' : '—')
        : AuthHelper.currentUserName!;
    final Map<String, String> penExtras = itemType == 'pens'
        ? await _resolvePenLogExtras(itemId: itemId)
        : const {};

    bool inserted = false;
    if (!inserted) {
      final rpcType = _inventoryRpcType(itemType);
      if (rpcType != null) {
        final params = <String, dynamic>{
          'type': rpcType,
          'item': itemId,
          'counted': invValue,
          'by_name': byName,
        };
        if (itemType == 'stationery' || itemType == 'pens') {
          params['table_key'] = _stationeryKey;
        }
        if (trimmedNote != null) {
          params['note'] = trimmedNote;
        }
        try {
          await _sb.rpc('inventory_set', params: params);
          inserted = true;
        } on PostgrestException catch (e) {
          String _lowercaseMessage(Object? value) =>
              (value is String ? value : value?.toString() ?? '').toLowerCase();
          final msg = _lowercaseMessage(e.message);
          final details = _lowercaseMessage(e.details);
          final hint = _lowercaseMessage(e.hint);
          if (msg.contains('by_name')) {
            final p2 = Map<String, dynamic>.from(params)..remove('by_name');
            try {
              await _sb.rpc('inventory_set', params: p2);
              inserted = true;
            } catch (_) {
              inserted = false;
            }
          } else if (msg.contains('function inventory_set') ||
              details.contains('function inventory_set') ||
              hint.contains('function inventory_set')) {
            inserted = false;
          }
        } catch (_) {
          inserted = false;
        }

        if (!inserted && itemType == 'pens') {
          final fallbackParams = Map<String, dynamic>.from(params)
            ..['type'] = 'stationery'
            ..['table_key'] = _stationeryKey;
          try {
            await _sb.rpc('inventory_set', params: fallbackParams);
            inserted = true;
          } catch (_) {
            inserted = false;
          }
        }
      }
    }
    if (!inserted) {
      for (final table in tables) {
        for (final fk in fkCandidates) {
          for (final qtyCol in qtyColumns) {
            final List<String?> keyCandidates =
                (itemType == 'stationery' || itemType == 'pens')
                    ? <String?>[
                        ..._tableKeyCandidatesFor(itemType),
                        null,
                      ]
                    : const <String?>[null];
            for (final String? noteCol in [...noteColumns, null]) {
              for (final String? tableKey in keyCandidates) {
                final payload = <String, dynamic>{
                  fk: itemId,
                  qtyCol: invValue,
                  'by_name': byName,
                  'employee': byName,
                  'type': itemType,
                  if (createdBy != null) 'created_by': createdBy,
                  'created_name': byName,
                };
                if (penExtras.isNotEmpty) {
                  payload.addAll(penExtras);
                }
                if (tableKey != null) {
                  payload['table_key'] = tableKey;
                }
                if (noteCol != null && trimmedNote != null) {
                  payload[noteCol] = trimmedNote;
                }

                final success = await _tryInsertWarehouseLog(table, payload);
                if (success) {
                  inserted = true;
                  break;
                } else {
                  final updatePayload = Map<String, dynamic>.from(payload)
                    ..remove(fk);
                  final dynamic tableKeyValue =
                      updatePayload.remove('table_key');
                  if (updatePayload.isNotEmpty) {
                    try {
                      var updateQuery =
                          _sb.from(table).update(updatePayload).eq(fk, itemId);
                      if (tableKeyValue != null) {
                        updateQuery = updateQuery.eq(
                            'table_key', tableKeyValue as Object);
                      }
                      await updateQuery;
                      inserted = true;
                      break;
                    } catch (_) {}
                  }
                }
              }
              if (inserted) break;
            }
            if (inserted) break;
          }
          if (inserted) break;
        }
        if (inserted) break;
      }
    }

    if (!inserted) {
      throw Exception('Не удалось сохранить инвентаризацию для $itemType');
    }

    final baseTable = _tableByType(itemType);
    try {
      var updateQuery = _sb
          .from(baseTable)
          .update({'quantity': invValue < 0 ? 0 : invValue}).eq('id', itemId);
      if (itemType == 'stationery') {
        updateQuery = updateQuery.eq('table_key', _stationeryKey);
      }
      await updateQuery;
    } catch (e) {
      debugPrint('⚠️ failed to update quantity after inventory: $e');
    }

    final list = _inventoriesByItem.putIfAbsent(itemId, () => []);
    final invEntry = {
      'item_id': itemId,
      'factual': invValue,
      'note': trimmedNote,
      'created_at': DateTime.now().toUtc().toIso8601String(),
      'by_name': byName,
      if (createdBy != null) 'created_by': createdBy,
      'created_name': byName,
    };
    if (penExtras.isNotEmpty) invEntry.addAll(penExtras);
    list.insert(0, invEntry);

    await fetchTmc();
  }

  List<String> _arrivalTables(String typeKey) {
    final hint = _arrMap[typeKey]?['table'];
    final resolved = _resolvedPensTable;
    final bool pensFallback =
        typeKey == 'pens' && (resolved == null || _pensUseStationeryFallback);
    final base = <String>[
      if (hint != null &&
          !(pensFallback && hint.toLowerCase().contains('pens')))
        hint,
      if (typeKey == 'stationery' || pensFallback)
        'warehouse_stationery_arrivals',
      if (typeKey == 'stationery' || pensFallback) 'stationery_arrivals',
      if (typeKey == 'pens' && !pensFallback) 'warehouse_pens_arrivals',
      if (typeKey == 'pens' && !pensFallback && resolved != null)
        '${resolved}_arrivals',
      if (typeKey == 'pens' && !pensFallback) 'warehouse_stationery_arrivals',
      if (typeKey == 'pens' && !pensFallback) 'stationery_arrivals',
      if (typeKey == 'paper') 'papers_arrivals',
      if (typeKey == 'paint') 'paints_arrivals',
      if (typeKey == 'material') 'materials_arrivals',
    ];
    final seen = <String>{};
    return base.where((e) => seen.add(e)).toList();
  }

  List<String> _inventoryTables(String typeKey) {
    final hint = _invMap[typeKey]?['table'];
    final resolved = _resolvedPensTable;
    final bool pensFallback =
        typeKey == 'pens' && (resolved == null || _pensUseStationeryFallback);
    final base = <String>[
      if (hint != null) hint,
      if (typeKey == 'stationery') 'warehouse_stationery_inventories',
      if (typeKey == 'pens' && !pensFallback) 'warehouse_pens_inventories',
      if (typeKey == 'pens' && !pensFallback && resolved != null)
        '${resolved}_inventories',
      if (typeKey == 'pens' && !pensFallback)
        'warehouse_stationery_inventories',
      if (typeKey == 'pens' && pensFallback) 'warehouse_stationery_inventories',
      if (typeKey == 'paper') 'papers_inventories',
      if (typeKey == 'paint') 'paints_inventories',
      if (typeKey == 'material') 'materials_inventories',
    ];
    final seen = <String>{};
    return base.where((e) => seen.add(e)).toList();
  }

  String? _inventoryRpcType(String type) {
    switch (type) {
      case 'paint':
        return 'paint';
      case 'material':
        return 'materials';
      case 'paper':
        return 'paper';
      case 'stationery':
        return 'stationery';
      case 'pens':
        return 'pens';
      default:
        return null;
    }
  }

  Future<Map<String, String>> _resolvePenLogExtras({
    String? itemId,
    String? name,
    String? color,
  }) async {
    String? resolvedName =
        name?.trim().isNotEmpty == true ? name!.trim() : null;
    String? resolvedColor =
        color?.trim().isNotEmpty == true ? color!.trim() : null;

    bool needsLookup =
        (resolvedName == null || resolvedColor == null) && (itemId != null);

    if (needsLookup) {
      try {
        TmcModel? tmc;
        try {
          tmc = _allTmc.firstWhere((e) => e.id == itemId && e.type == 'pens');
        } catch (_) {
          try {
            tmc = _allTmc.firstWhere((e) => e.id == itemId);
          } catch (_) {}
        }
        final desc = (tmc?.description ?? '').trim();
        if (desc.isNotEmpty) {
          final parts = desc.split('•');
          if (resolvedName == null && parts.isNotEmpty) {
            resolvedName = parts.first.trim();
          }
          if (resolvedColor == null && parts.length > 1) {
            resolvedColor = parts
                .sublist(1)
                .map((p) => p.trim())
                .where((p) => p.isNotEmpty)
                .join(' • ');
          }
        }
      } catch (_) {}
    }

    if ((resolvedName == null || resolvedColor == null) && itemId != null) {
      try {
        final row = await _sb
            .from(_tableByType('pens'))
            .select('name, color')
            .eq('id', itemId)
            .maybeSingle();
        if (row != null) {
          resolvedName ??= (row['name'] ?? '').toString().trim().isEmpty
              ? null
              : row['name'].toString().trim();
          resolvedColor ??= (row['color'] ?? '').toString().trim().isEmpty
              ? null
              : row['color'].toString().trim();
        }
      } catch (_) {}
    }

    final extras = <String, String>{};
    if (resolvedName != null && resolvedName.isNotEmpty) {
      extras['name'] = resolvedName;
    }
    if (resolvedColor != null && resolvedColor.isNotEmpty) {
      extras['color'] = resolvedColor;
    }
    return extras;
  }

  Future<void> _logArrivalGeneric({
    required String typeKey,
    required String itemId,
    required double qty,
    String? note,
    Map<String, dynamic>? extraPayload,
  }) async {
    if (qty <= 0) return;
    if (typeKey == 'pens') {
      await _resolvePensTable();
    }
    final tables = _arrivalTables(typeKey);
    final fkCandidates = <String>[
      'item_id',
      'stationery_id',
      'paper_id',
      'paint_id',
      'material_id',
      'tmc_id',
      'fk_id',
      if (_arrMap[typeKey]?['fk'] != null) _arrMap[typeKey]!['fk']!,
    ];
    final qtyCandidates = <String>[
      'qty',
      'quantity',
      'amount',
      'count',
      if (_arrMap[typeKey]?['qty'] != null) _arrMap[typeKey]!['qty']!,
    ];
    final noteCandidates = <String>['note', 'comment', 'reason'];
    final byName = (AuthHelper.currentUserName ?? '').trim().isEmpty
        ? (AuthHelper.isTechLeader ? 'Технический лидер' : '—')
        : AuthHelper.currentUserName!;

    for (final table in tables) {
      for (final fk in fkCandidates) {
        final basePayload = <String, dynamic>{
          fk: itemId,
          'by_name': byName,
          'employee': byName,
        };
        if (extraPayload != null && extraPayload.isNotEmpty) {
          basePayload.addAll(extraPayload);
        }
        bool qtySet = false;
        for (final q in qtyCandidates) {
          if (!qtySet) {
            basePayload[q] = qty;
            qtySet = true;
          }
        }
        if (note != null && note.trim().isNotEmpty) {
          for (final n in noteCandidates) {
            if (!basePayload.containsKey(n)) {
              basePayload[n] = note.trim();
              break;
            }
          }
        }

        final bool requiresKey = _tableRequiresStationeryKey(table);
        final List<String> keyCandidates =
            requiresKey ? _tableKeyCandidatesFor(typeKey) : const <String>[];

        if (requiresKey) {
          bool inserted = false;
          for (final key in keyCandidates) {
            final payload = Map<String, dynamic>.from(basePayload)
              ..['table_key'] = key;
            inserted = await _tryInsertWarehouseLog(table, payload);
            if (inserted) return;
          }
          if (!inserted) {
            if (await _tryInsertWarehouseLog(table, basePayload)) return;
          }
        } else {
          if (await _tryInsertWarehouseLog(table, basePayload)) return;
        }
      }
    }
  }

  // ===================== HELPERS =====================
  bool _tableRequiresStationeryKey(String table) {
    final lower = table.toLowerCase();
    return lower == 'warehouse_stationery' ||
        lower == 'stationery' ||
        lower == 'warehouse_stationeries';
  }

  List<String> _tableKeyCandidatesFor(String typeKey) {
    final Set<String> keys = <String>{};
    final String trimmed = _stationeryKey.trim();
    if (trimmed.isNotEmpty) keys.add(trimmed);
    switch (typeKey) {
      case 'pens':
        for (final candidate in const ['ручки', 'pens', 'handles']) {
          if (candidate.trim().isNotEmpty) {
            keys.add(candidate);
          }
        }
        break;
      case 'stationery':
        for (final candidate in const ['канцелярия', 'stationery']) {
          if (candidate.trim().isNotEmpty) {
            keys.add(candidate);
          }
        }
        break;
    }
    return keys
        .map((String e) => e.trim())
        .where((String e) => e.isNotEmpty)
        .toList();
  }

  Future<bool> _tryInsertWarehouseLog(
      String table, Map<String, dynamic> payload) async {
    final sanitized = _sanitizeWarehouseLogPayload(table, payload);
    try {
      await _sb.from(table).insert(sanitized);
      return true;
    } on PostgrestException catch (e) {
      String _lowercase(Object? value) =>
          (value is String ? value : value?.toString() ?? '').toLowerCase();
      final String code = _lowercase(e.code);
      final String message = _lowercase(e.message);
      final String details = _lowercase(e.details);

      bool matches(String column) =>
          column.isNotEmpty &&
          (message.contains(column.toLowerCase()) ||
              details.contains(column.toLowerCase()));

      if (sanitized.containsKey('by_name') &&
          (matches('by_name') || code == '42703')) {
        final next = Map<String, dynamic>.from(sanitized)..remove('by_name');
        return _tryInsertWarehouseLog(table, next);
      }

      if (sanitized.containsKey('employee') &&
          (matches('employee') || code == '42703')) {
        final next = Map<String, dynamic>.from(sanitized)..remove('employee');
        return _tryInsertWarehouseLog(table, next);
      }

      if (sanitized.containsKey('type') &&
          (matches('type') || code == '42703')) {
        final next = Map<String, dynamic>.from(sanitized)..remove('type');
        return _tryInsertWarehouseLog(table, next);
      }

      if (sanitized.containsKey('table_key') &&
          (matches('table_key') || code == '42703')) {
        return false;
      }

      if (_isMissingRelationError(e, table)) {
        return false;
      }

      if (code == '42703') {
        return false;
      }

      rethrow;
    }
  }

  Map<String, dynamic> _sanitizeWarehouseLogPayload(
      String table, Map<String, dynamic> payload) {
    final sanitized = Map<String, dynamic>.from(payload)
      ..removeWhere((key, value) => value == null);
    sanitized.remove('name');
    sanitized.remove('color');
    sanitized.remove('pen_name');
    sanitized.remove('pen_color');
    return sanitized;
  }

  bool _isMissingRelationError(PostgrestException? error, [String? relation]) {
    if (error == null) return false;
    final String code = (error.code?.toString() ?? '').toLowerCase();
    final String message = (error.message?.toString() ?? '').toLowerCase();
    final String details = (error.details?.toString() ?? '').toLowerCase();
    final String hint = (error.hint?.toString() ?? '').toLowerCase();
    final String? relationLower = relation?.toLowerCase();
    bool containsRelation(String value) {
      if (relationLower == null || relationLower.isEmpty) return false;
      return value.contains(relationLower);
    }

    if (code == '42p01' ||
        code == 'pgrst201' ||
        code == 'pgrst202' ||
        code == 'pgrst301' ||
        code == 'pgrst302') {
      return true;
    }

    if (containsRelation(message) &&
        (message.contains('does not exist') ||
            message.contains('could not find'))) {
      return true;
    }
    if (containsRelation(details) &&
        (details.contains('does not exist') ||
            details.contains('could not find'))) {
      return true;
    }
    if (containsRelation(hint) &&
        (hint.contains('does not exist') || hint.contains('could not find'))) {
      return true;
    }

    return false;
  }

  String? _normalizeType(String? type) {
    if (type == null) return null;
    final t = type.toLowerCase().trim();
    if (t == 'paint' || t == 'краска' || t == 'краски') return 'paint';
    if (t == 'paper' || t == 'бумага' || t == 'бумаги') return 'paper';
    if (t == 'stationery' ||
        t == 'канцтовары' ||
        t == 'канцтовар' ||
        t == 'канцелярия') return 'stationery';
    if (t == 'ручки' ||
        t == 'ручка' ||
        t == 'pens' ||
        t == 'pen' ||
        t == 'handles' ||
        t == 'handle') return 'pens';
    if (t == 'material' ||
        t == 'материал' ||
        t == 'материалы' ||
        t == 'рулон' ||
        t == 'форма') return 'material';
    if (t == 'списание') return '_op_writeoff';
    if (t == 'инвентаризация') return '_op_inventory';
    return null;
  }

  String _tableByType(String type) {
    switch (type) {
      case 'paint':
        return 'paints';
      case 'material':
        return 'materials';
      case 'paper':
        return 'papers';
      case 'pens':
        return _resolvedPensTable ?? 'warehouse_pens';
      case 'stationery':
        return 'warehouse_stationery';
      default:
        throw Exception('Неизвестный type: $type');
    }
  }

  Future<Map<String, dynamic>?> _findExistingPaint(String description) async {
    final normalized = description.trim();
    if (normalized.isEmpty) return null;
    final data = await _sb
        .from('paints')
        .select(
            'id, description, unit, note, low_threshold, critical_threshold, image_url, image_base64')
        .ilike('description', normalized)
        .limit(1)
        .maybeSingle();
    if (data == null) return null;
    final existingDescription =
        (data['description'] ?? '').toString().trim().toLowerCase();
    if (existingDescription != normalized.toLowerCase()) {
      return null;
    }
    return data;
  }

  Future<Map<String, dynamic>?> _findExistingStationery(
      String description) async {
    final normalized = description.trim();
    if (normalized.isEmpty) return null;
    final data = await _sb
        .from('warehouse_stationery')
        .select(
            'id, description, unit, note, low_threshold, critical_threshold, table_key, image_url, image_base64')
        .eq('table_key', _stationeryKey)
        .ilike('description', normalized)
        .limit(1)
        .maybeSingle();
    if (data == null) return null;
    final existingDescription =
        (data['description'] ?? '').toString().trim().toLowerCase();
    if (existingDescription != normalized.toLowerCase()) {
      return null;
    }
    return data;
  }

  String _inferType({
    required String unit,
    String? format,
    String? grammage,
    String? description,
  }) {
    if (format != null &&
        format.isNotEmpty &&
        grammage != null &&
        grammage.isNotEmpty) {
      return 'paper';
    }
    final u = unit.toLowerCase();
    if (u == 'ml' || u == 'l' || u == 'кг' || u == 'гр' || u == 'г') {
      return 'paint';
    }
    return 'material';
  }

  Future<String?> _detectTypeById(String id) async {
    try {
      final pensTable = await _resolvePensTable();
      final bool pensFallback =
          pensTable != null && pensTable.toLowerCase().contains('stationery');
      final p =
          await _sb.from('paints').select('id').eq('id', id).maybeSingle();
      if (p != null) return 'paint';
      final m =
          await _sb.from('materials').select('id').eq('id', id).maybeSingle();
      if (m != null) return 'material';
      final pr =
          await _sb.from('papers').select('id').eq('id', id).maybeSingle();
      if (pr != null) return 'paper';
      if (pensTable != null && !pensFallback) {
        final pe =
            await _sb.from(pensTable).select('id').eq('id', id).maybeSingle();
        if (pe != null) return 'pens';
      }
      final sNew = await _sb
          .from('warehouse_stationery')
          .select('id, table_key')
          .eq('id', id)
          .maybeSingle();
      if (sNew != null) {
        if (pensFallback) {
          final key = (sNew['table_key'] ?? '').toString().toLowerCase().trim();
          final pensKeys = _tableKeyCandidatesFor('pens')
              .map((k) => k.toLowerCase())
              .toSet();
          if (pensKeys.contains(key)) {
            return 'pens';
          }
        }
        return 'stationery';
      }
      final sOld =
          await _sb.from('stationery').select('id').eq('id', id).maybeSingle();
      if (sOld != null) return 'stationery';
      if (pensTable == null || pensFallback) {
        final pe = await _sb
            .from('warehouse_pens')
            .select('id')
            .eq('id', id)
            .maybeSingle();
        if (pe != null) return 'pens';
      }
    } catch (_) {}
    return null;
  }

  TmcModel _fromRow({required String type, required Map<String, dynamic> row}) {
    double _d(v) => (v is num) ? v.toDouble() : double.tryParse('$v') ?? 0.0;
    if (type == 'pens') {
      final name = (row['name'] ?? '').toString();
      final color = (row['color'] ?? '').toString();
      final desc = [name, color].where((s) => s.isNotEmpty).join(' • ');
      return TmcModel(
        id: row['id'] as String,
        date: (row['date'] as String?) ??
            DateTime.tryParse(row['created_at']?.toString() ?? '')
                ?.toIso8601String() ??
            '',
        supplier: row['supplier'] as String?,
        type: type,
        description:
            desc.isEmpty ? (row['description']?.toString() ?? '') : desc,
        quantity: _d(row['quantity']),
        unit: (row['unit'] as String?) ?? 'пар',
        note: row['note'] as String?,
        format: null,
        grammage: null,
        weight: null,
        imageUrl: row['image_url'] as String?,
        imageBase64: row['image_base64'] as String?,
        lowThreshold:
            row['low_threshold'] == null ? null : _d(row['low_threshold']),
        criticalThreshold: row['critical_threshold'] == null
            ? null
            : _d(row['critical_threshold']),
        createdAt: row['created_at']?.toString(),
        updatedAt: row['updated_at']?.toString(),
      );
    }
    return TmcModel(
      id: row['id'] as String,
      date: (row['date'] as String?) ??
          DateTime.tryParse(row['created_at']?.toString() ?? '')
              ?.toIso8601String() ??
          '',
      supplier: row['supplier'] as String?,
      type: type,
      description: (row['description'] ?? '').toString(),
      quantity: _d(row['quantity']),
      unit: (row['unit'] as String?) ?? '',
      note: row['note'] as String?,
      format: row['format'] as String?,
      grammage: row['grammage'] as String?,
      weight: row['weight'] == null ? null : _d(row['weight']),
      imageUrl: row['image_url'] as String?,
      imageBase64: row['image_base64'] as String?,
      lowThreshold:
          row['low_threshold'] == null ? null : _d(row['low_threshold']),
      criticalThreshold: row['critical_threshold'] == null
          ? null
          : _d(row['critical_threshold']),
      createdAt: row['created_at']?.toString(),
      updatedAt: row['updated_at']?.toString(),
    );
  }

  Future<String> _uploadImage(
      String id, Uint8List bytes, String contentType) async {
    final ext = contentType.split('/').last;
    final path = 'tmc/$id/${DateTime.now().millisecondsSinceEpoch}.$ext';
    await _sb.storage.from('tmc').uploadBinary(
          path,
          bytes,
          fileOptions: FileOptions(contentType: contentType, upsert: true),
        );
    return _sb.storage.from('tmc').getPublicUrl(path);
  }

  Future<void> _logTmcEvent({
    required String tmcId,
    required String eventType,
    double? quantityChange,
    String? note,
  }) async {
    try {
      await _sb.from('analytics').insert({
        'entity': 'warehouse',
        'entity_id': tmcId,
        'action': eventType,
        if (quantityChange != null) 'value_num': quantityChange,
        if (note != null) 'note': note,
      });
    } catch (_) {
      // analytics не обязательна
    }
  }

  // ======= FORMS (склад) =======

  Future<int> getNextFormNumber({String series = 'F'}) async {
    await _ensureAuthed();
    try {
      final last = await _sb
          .from('forms')
          .select('number')
          .eq('series', series)
          .order('number', ascending: false)
          .limit(1)
          .maybeSingle();
      final lastNum = (last != null && last['number'] != null)
          ? (last['number'] is num
              ? (last['number'] as num).toInt()
              : (int.tryParse(last['number'].toString()) ?? 0))
          : 0;
      return lastNum + 1;
    } catch (_) {
      return 1;
    }
  }

  Future<Map<String, dynamic>> createFormAndReturn({
    String series = 'F',
    int? number,
    String? title,
    String? description,
    Uint8List? imageBytes,
    String imageContentType = 'image/jpeg',
    String? formSize,
    String? formProductType,
    String? formColors,
    bool isEnabled = true,
    String? disabledComment,
  }) async {
    await _ensureAuthed();

    final next = number ?? await getGlobalNextFormNumber();
    final Map<String, dynamic> insertData = {
      'series': series,
      'number': next,
      if (title != null) 'title': title,
      if (description != null) 'description': description,
      if (formSize != null) 'size': formSize,
      if (formProductType != null) 'product_type': formProductType,
      if (formColors != null) 'colors': formColors,
      'status': 'in_stock',
      'is_enabled': isEnabled,
      if (disabledComment != null && disabledComment.trim().isNotEmpty)
        'disabled_comment': disabledComment.trim(),
    };
    final inserted =
        await _sb.from('forms').insert(insertData).select().single();

    if (imageBytes != null && imageBytes.isNotEmpty) {
      try {
        final String formId = (inserted['id'] ?? '').toString();
        final url = await _uploadImage(formId, imageBytes, imageContentType);
        await _sb.from('forms').update({'image_url': url}).eq('id', formId);
        (inserted as Map)['image_url'] = url;
      } catch (e) {
        debugPrint('❌ upload form image: $e');
      }
    }

    try {
      final fs = await _sb
          .from('forms_series')
          .select('id,last_number')
          .eq('series', series)
          .maybeSingle();
      if (fs == null) {
        await _sb.from('forms_series').insert({
          'series': series,
          'prefix': '',
          'suffix': '',
          'last_number': next,
        });
      } else {
        final cur = (fs['last_number'] as num?)?.toInt() ?? 0;
        if (next > cur) {
          await _sb
              .from('forms_series')
              .update({'last_number': next}).eq('id', fs['id'] as String);
        }
      }
    } catch (_) {}

    try {
      await fetchTmc();
    } catch (_) {}

    return Map<String, dynamic>.from(inserted as Map);
  }

  Future<List<Map<String, dynamic>>> searchForms({
    String? query,
    String? series,
    int limit = 50,
  }) async {
    await _ensureAuthed();

    dynamic sel = _sb.from('forms').select();

    if (series != null && series.isNotEmpty) {
      sel = sel.eq('series', series);
    }

    if (query != null && query.trim().isNotEmpty) {
      final q = query.trim();
      sel = sel.or('series.ilike.%' +
          q +
          '%,code.ilike.%' +
          q +
          '%,title.ilike.%' +
          q +
          '%,description.ilike.%' +
          q +
          '%,number::text.ilike.%' +
          q +
          '%');
    }

    final data = await sel.order('number', ascending: false).limit(limit);
    return (data as List)
        .map((e) => Map<String, dynamic>.from(e as Map))
        .toList();
  }

  Future<Map<String, dynamic>?> findFormBySeriesNumber({
    required String series,
    required int number,
  }) async {
    await _ensureAuthed();
    final row = await _sb
        .from('forms')
        .select()
        .eq('series', series)
        .eq('number', number)
        .maybeSingle();
    return row == null ? null : Map<String, dynamic>.from(row);
  }

  Future<void> updateForm({
    required String id,
    String? series,
    int? number,
    String? title,
    String? description,
    Uint8List? imageBytes,
    String imageContentType = 'image/jpeg',
    String? formSize,
    String? formProductType,
    String? formColors,
    bool? isEnabled,
    String? disabledComment,
    String? status,
  }) async {
    await _ensureAuthed();
    final updates = <String, dynamic>{};
    if (series != null) updates['series'] = series;
    if (number != null) updates['number'] = number;
    if (title != null) updates['title'] = title;
    if (description != null) updates['description'] = description;
    if (formSize != null) updates['size'] = formSize;
    if (formProductType != null) updates['product_type'] = formProductType;
    if (formColors != null) updates['colors'] = formColors;
    if (isEnabled != null) updates['is_enabled'] = isEnabled;
    if (disabledComment != null) {
      updates['disabled_comment'] =
          disabledComment.trim().isEmpty ? null : disabledComment.trim();
    } else if (isEnabled == true) {
      updates['disabled_comment'] = null;
    }
    if (status != null) updates['status'] = status;

    if (imageBytes != null && imageBytes.isNotEmpty) {
      try {
        final url = await _uploadImage(id, imageBytes, imageContentType);
        updates['image_url'] = url;
      } catch (e) {
        debugPrint('❌ upload form image: $e');
      }
    }

    if (updates.isEmpty) return;

    await _sb.from('forms').update(updates).eq('id', id);

    if (series != null || number != null) {
      try {
        final newSeries = series;
        final newNumber = number;
        if (newSeries != null && newNumber != null) {
          final fs = await _sb
              .from('forms_series')
              .select('id,last_number')
              .eq('series', newSeries)
              .maybeSingle();
          final cur = (fs?['last_number'] as num?)?.toInt() ?? 0;
          if (newNumber > cur) {
            if (fs == null) {
              await _sb.from('forms_series').insert({
                'series': newSeries,
                'prefix': '',
                'suffix': '',
                'last_number': newNumber,
              });
            } else {
              await _sb.from('forms_series').update(
                  {'last_number': newNumber}).eq('id', fs['id'] as String);
            }
          }
        }
      } catch (_) {}
    }
    try {
      await fetchTmc();
    } catch (_) {}
  }

  Future<void> deleteForm({String? id, String? series, int? number}) async {
    await _ensureAuthed();

    if ((id == null || id.isEmpty) && (series == null || number == null)) {
      throw ArgumentError('Передай id или series+number для удаления формы');
    }

    if (id != null && id.isNotEmpty) {
      dynamic q = _sb.from('forms').delete();
      q = q.eq('id', id);
      await q;
      return;
    }

    dynamic q = _sb.from('forms').delete();
    q = q.eq('series', series).eq('number', number);
    await q;
  }

  Future<List<Map<String, dynamic>>> getFormsSeriesWithFallback() async {
    await _ensureAuthed();
    final out = <Map<String, dynamic>>[];

    try {
      final res = await _sb
          .from('forms_series')
          .select()
          .order('series', ascending: true);
      final list = (res as List);
      if (list.isNotEmpty) {
        for (final row in list) {
          final r = Map<String, dynamic>.from(row as Map);
          final series = (r['series'] ?? '').toString();
          final last = (r['last_number'] as num?)?.toInt() ?? 0;
          String? label;
          try {
            final ord = await _sb
                .from('orders')
                .select('id, title, name, customer, new_form_no, created_at')
                .eq('new_form_no', last)
                .order('created_at', ascending: false)
                .limit(1)
                .maybeSingle();
            if (ord != null) {
              final ro = Map<String, dynamic>.from(ord as Map);
              label = (ro['title'] ?? ro['name'] ?? ro['customer'])?.toString();
            }
          } catch (_) {}
          out.add({
            'series': series,
            'last_number': last,
            'label': (label != null && label.isNotEmpty) ? label : series,
          });
        }
        return out;
      }
    } catch (_) {}

    final forms = await _sb.from('forms').select();
    final maxBySeries = <String, int>{};
    final lastTitleBySeries = <String, String>{};
    for (final row in (forms as List)) {
      final r = Map<String, dynamic>.from(row as Map);
      final s = (r['series'] ?? '').toString();
      final n = (r['number'] as num?)?.toInt() ?? 0;
      final title = (r['title'] ?? '').toString();
      if (s.isEmpty) continue;
      if (!maxBySeries.containsKey(s) || n > maxBySeries[s]!) {
        maxBySeries[s] = n;
        lastTitleBySeries[s] = title;
      }
    }
    final keys = maxBySeries.keys.toList()..sort();
    for (final k in keys) {
      final last = maxBySeries[k] ?? 0;
      String? label = lastTitleBySeries[k];
      if (label == null || label.isEmpty) {
        try {
          final ord = await _sb
              .from('orders')
              .select('id, title, name, customer, new_form_no, created_at')
              .eq('new_form_no', last)
              .order('created_at', ascending: false)
              .limit(1)
              .maybeSingle();
          if (ord != null) {
            final ro = Map<String, dynamic>.from(ord as Map);
            label = (ro['title'] ?? ro['name'] ?? ro['customer'])?.toString();
          }
        } catch (_) {}
      }
      out.add({'series': k, 'last_number': last, 'label': label ?? k});
    }
    return out;
  }

  /// Возвращает запись краски по точному имени (без учёта регистра).
  TmcModel? getPaintByName(String name) {
    final n = name.trim().toLowerCase();
    try {
      return _allTmc.firstWhere((p) =>
          (p.type == 'paint') &&
          (p.description ?? '').trim().toLowerCase() == n);
    } catch (_) {
      return null;
    }
  }

  /// Глобальный следующий номер формы = (максимальный number по всей таблице) + 1
  Future<int> getGlobalNextFormNumber() async {
    await _ensureAuthed();
    try {
      final last = await _sb
          .from('forms')
          .select('number')
          .order('number', ascending: false)
          .limit(1)
          .maybeSingle();
      final lastNum = (last != null && last['number'] != null)
          ? (last['number'] is num
              ? (last['number'] as num).toInt()
              : (int.tryParse(last['number'].toString()) ?? 0))
          : 0;
      return lastNum + 1;
    } catch (_) {
      return 1;
    }
  }

  double _parseMetersLocalized(String s) {
    final normalized = s.replaceAll(',', '.').trim();
    return double.tryParse(normalized) ?? 0.0;
  }

  Future<void> receivePaperByName({
    required String name,
    required String format,
    required String grammage,
    required String metersText,
    String? note,
  }) async {
    await _ensureAuthed();
    final qty = _parseMetersLocalized(metersText);
    if (qty <= 0) throw Exception('Метры должны быть > 0');

    final existing = await _sb
        .from('papers')
        .select('id')
        .eq('description', name)
        .eq('format', format)
        .eq('grammage', grammage)
        .maybeSingle();

    String paperId =
        existing != null ? (existing['id'] as String) : const Uuid().v4();

    if (existing == null) {
      await _sb.from('papers').insert({
        'id': paperId,
        'date': nowInKostanayIsoString(),
        'supplier': null,
        'description': name,
        'unit': 'м',
        'quantity': 0,
        'note': note,
        'format': format,
        'grammage': grammage,
      });
    }

    await _sb.rpc('arrival_add', params: {
      '_type': 'paper',
      '_item': paperId,
      '_qty': qty,
      '_note': note ?? 'Приход',
      '_by_name': (AuthHelper.currentUserName ?? '')
    });

    await fetchTmc();
  }

  Future<void> consumePaperByName({
    required String name,
    required String format,
    required String grammage,
    required String metersText,
    String? orderId,
    String? reason,
  }) async {
    await _ensureAuthed();
    final qty = _parseMetersLocalized(metersText);
    if (qty <= 0) throw Exception('Метры должны быть > 0');

    final existing = await _sb
        .from('papers')
        .select('id, quantity')
        .eq('description', name)
        .eq('format', format)
        .eq('grammage', grammage)
        .maybeSingle();

    if (existing == null) {
      throw Exception(
          'Такой бумаги (номенклатура/формат/грамаж) нет на складе');
    }
    final paperId = existing['id'] as String;

    try {
      await _sb.rpc('writeoff', params: {
        'type': 'paper',
        'item': paperId,
        'qty': qty,
        'reason': reason ?? 'Списание (заказ)',
        'by_name': (AuthHelper.currentUserName ?? '')
      });
    } catch (e) {
      rethrow;
    }

    await fetchTmc();
  }
}
