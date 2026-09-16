/// Drop-in extension for WarehouseProvider to load Write-offs & Inventories
/// НЕ МЕНЯЕТ существующий файл провайдера. Просто положи этот файл рядом
/// с `warehouse_provider.dart` и импортируй где нужно.
/// Путь проекта: lib/modules/warehouse/warehouse_provider_woinv.dart
library warehouse_provider_woinv;

import 'package:supabase_flutter/supabase_flutter.dart';
import 'warehouse_provider.dart';

/// Расширение добавляет методы:
/// - loadWriteoffs(type: ..., itemId: ...)
/// - loadInventories(type: ..., itemId: ...)
extension WarehouseProviderWoInv on WarehouseProvider {
  // Карта соответствий: тип -> таблица списаний и имя FK
  static const Map<String, Map<String, String>> _woMap = {
    'paint': {'table': 'paints_writeoffs', 'fk': 'paint_id'},
    'material': {'table': 'materials_writeoffs', 'fk': 'material_id'},
    'paper': {'table': 'papers_writeoffs', 'fk': 'paper_id'},
    'stationery': {'table': 'warehouse_stationery_writeoffs', 'fk': 'item_id'},
  };

  // Карта соответствий: тип -> таблица инвентаризаций и имя FK
  static const Map<String, Map<String, String>> _invMap = {
    'paint': {'table': 'paints_inventories', 'fk': 'paint_id'},
    'material': {'table': 'materials_inventories', 'fk': 'material_id'},
    'paper': {'table': 'papers_inventories', 'fk': 'paper_id'},
    'stationery': {
      'table': 'warehouse_stationery_inventories',
      'fk': 'item_id'
    },
  };

  // Нормализация ключей типа (рус/англ)
  String _normalizeType(String raw) {
    final t = raw.trim().toLowerCase();
    if (t.startsWith('краск')) return 'paint';
    if (t.startsWith('матер')) return 'material';
    if (t.startsWith('бума')) return 'paper';
    if (t.startsWith('канц')) return 'stationery';
    if (_woMap.containsKey(t) || _invMap.containsKey(t)) return t;
    return t;
  }

  /// Загрузить списания для конкретной позиции.
  Future<List<Map<String, dynamic>>> loadWriteoffs({
    required String type,
    required String itemId,
  }) async {
    final key = _normalizeType(type);
    final m = _woMap[key];
    if (m == null) return <Map<String, dynamic>>[];

    final s = Supabase.instance.client;
    final data = await s
        .from(m['table']!)
        .select()
        .eq(m['fk']!, itemId)
        .order('created_at', ascending: false);

    return (data as List).cast<Map<String, dynamic>>();
  }

  /// Загрузить инвентаризации для конкретной позиции.
  Future<List<Map<String, dynamic>>> loadInventories({
    required String type,
    required String itemId,
  }) async {
    final key = _normalizeType(type);
    final m = _invMap[key];
    if (m == null) return <Map<String, dynamic>>[];

    final s = Supabase.instance.client;
    final data = await s
        .from(m['table']!)
        .select()
        .eq(m['fk']!, itemId)
        .order('created_at', ascending: false);

    return (data as List).cast<Map<String, dynamic>>();
  }
}
