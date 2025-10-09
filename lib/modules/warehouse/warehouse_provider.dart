import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:uuid/uuid.dart';

import 'tmc_model.dart';
import '../../utils/auth_helper.dart';
import '../../services/app_auth.dart';

class WarehouseProvider with ChangeNotifier {
  // ====== PENS DEDICATED TABLE RESOLUTION ======
  String? _resolvedPensTable; // e.g. 'handles', 'pens', 'warehouse_pens', etc.

  Future<String?> _resolvePensTable() async {
    _resolvedPensTable = 'warehouse_pens';
    return _resolvedPensTable;
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
        }
        if (isPens && pensTable != null) {
          // warehouse_pens обычно не имеет 'description' -> сортируем по created_at
          final pensRaw =
              await _sb.from(pensTable).select().order('created_at');
          s = (pensRaw as List)
              .map((e) => Map<String, dynamic>.from(e))
              .toList();
          // Mark as pens
          s = s.map((row) {
            row['__force_type__'] = 'pens';
            return row;
          }).toList();
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

    String? finalImageUrl = imageUrl;
    String? finalBase64 = imageBase64;

    if (imageBytes != null && imageBytes.isNotEmpty) {
      finalImageUrl = await _uploadImage(newId, imageBytes, imageContentType);
      finalBase64 ??= base64Encode(imageBytes);
    }
    if (finalImageUrl == null && finalBase64 != null) {
      try {
        final _bytes = base64Decode(finalBase64);
        if (_bytes.isNotEmpty) {
          finalImageUrl = await _uploadImage(newId, _bytes, imageContentType);
        }
      } catch (_) {}
    }

    // ----------- РУЧКИ (dedicated table) -----------
    if (normalizedType == 'pens') {
      final table = _tableByType('pens'); // usually 'warehouse_pens'
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
      final body = <String, dynamic>{
        'id': newId,
        'date': DateTime.now().toIso8601String(),
        'supplier': supplier,
        'name': name,
        'color': color,
        'unit': unit.isNotEmpty ? unit : 'пар',
        'quantity': quantity,
        'note': note,
        'low_threshold': lowThreshold ?? 0,
        'critical_threshold': criticalThreshold ?? 0,
      };
      await _sb.from(table).insert(body);
      await fetchTmc();
      await _logTmcEvent(
        tmcId: newId,
        eventType: 'Приход (ручки)',
        quantityChange: quantity,
        note: note ?? 'Добавление в склад ручек',
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
          'date': DateTime.now().toIso8601String(),
          'supplier': supplier,
          'description': description,
          'unit': unit.isNotEmpty ? unit : 'м',
          'quantity': 0,
          'note': note,
          'low_threshold': lowThreshold ?? 0,
          'critical_threshold': criticalThreshold ?? 0,
          'format': format,
          'grammage': grammage,
          if (weight != null) 'weight': weight,
          if (finalImageUrl != null) 'image_url': finalImageUrl,
          if (finalBase64 != null) 'image_base64': finalBase64,
        };
        await _sb.from('papers').insert(body);
      }

      if (quantity > 0) {
        await _sb.rpc('arrival_add', params: {
          '_type': 'paper',
          '_item': paperId,
          '_qty': quantity,
          '_note': note,
          '_by_name': (AuthHelper.currentUserName ?? '')
        });
      }

      await fetchTmc();
      return;
    }

    // ----------- Остальные типы -----------
    final common = <String, dynamic>{
      'id': newId,
      'date': DateTime.now().toIso8601String(),
      'supplier': supplier,
      'description': description,
      'unit': unit,
      'quantity': quantity,
      'note': note,
      'low_threshold': lowThreshold ?? 0,
      'critical_threshold': criticalThreshold ?? 0,
      if (finalImageUrl != null) 'image_url': finalImageUrl,
      if (finalBase64 != null) 'image_base64': finalBase64,
    };

    try {
      if (normalizedType == 'paint') {
        await _sb.from('paints').insert(common);
      } else if (normalizedType == 'material') {
        await _sb.from('materials').insert(common);
      } else if (normalizedType == 'stationery') {
        final body = {
          ...common,
          'table_key': _stationeryKey,
          'type': 'stationery',
        };
        await _sb.from('warehouse_stationery').insert(body);
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
    final table = (itemType == 'pens')
        ? 'warehouse_pens_writeoffs'
        : 'warehouse_stationery_writeoffs';
    await _sb.from(table).insert({
      'item_id': itemId,
      'qty': qty,
      if (reason != null && reason.isNotEmpty) 'reason': reason,
    });

    final list = _writeoffsByItem.putIfAbsent(itemId, () => []);
    list.insert(0, {
      'item_id': itemId,
      'qty': qty,
      'reason': reason,
      'created_at': DateTime.now().toIso8601String(),
    });

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
    await _ensureAuthed();
    String itemType = _normalizeType(typeHint) ??
        (await _detectTypeById(itemId) ?? 'stationery');
    final table = (itemType == 'pens')
        ? 'warehouse_pens_inventories'
        : 'warehouse_stationery_inventories';
    await _sb.from(table).insert({
      'item_id': itemId,
      'factual': invValue,
      if (note != null && note.isNotEmpty) 'note': note,
    });

    final list = _inventoriesByItem.putIfAbsent(itemId, () => []);
    list.insert(0, {
      'item_id': itemId,
      'factual': invValue,
      'note': note,
      'created_at': DateTime.now().toIso8601String(),
    });

    await fetchTmc();
  }

  // ===================== HELPERS =====================
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
      final p =
          await _sb.from('paints').select('id').eq('id', id).maybeSingle();
      if (p != null) return 'paint';
      final m =
          await _sb.from('materials').select('id').eq('id', id).maybeSingle();
      if (m != null) return 'material';
      final sNew = await _sb
          .from('warehouse_stationery')
          .select('id')
          .eq('id', id)
          .maybeSingle();
      if (sNew != null) return 'stationery';
      final sOld =
          await _sb.from('stationery').select('id').eq('id', id).maybeSingle();
      if (sOld != null) return 'stationery';
      final pr =
          await _sb.from('papers').select('id').eq('id', id).maybeSingle();
      if (pr != null) return 'paper';
      final pe = await _sb
          .from(_resolvedPensTable ?? 'warehouse_pens')
          .select('id')
          .eq('id', id)
          .maybeSingle();
      if (pe != null) return 'pens';
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
        'date': DateTime.now().toIso8601String(),
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
