import 'dart:async';
import 'package:supabase_flutter/supabase_flutter.dart';

/// Idempotent write-off helper.
/// Stores per-order per-item snapshots to ensure write-offs happen only once,
/// and on edit we write off only the positive delta.
class ConsumptionService {
  final SupabaseClient _sb = Supabase.instance.client;

  /// Apply delta for paper (meters/weight), idempotently.
  /// Any numeric args can be null; only non-null fields will be considered.
  Future<void> applyPaperDelta({
    required String orderId,
    String? tmcId,
    String? paperKey,
    double? meters,
    double? weight,
    double? quantity,
    // Synonyms accepted from various call sites
    double? newMeters,
    double? newWeight,
    double? newQuantity,
    double? value,
    double? valueMeters,
    String? unit,
  }) async {
    // Minimal no-op if nothing to write
    final mm = meters ?? newMeters ?? valueMeters ?? value;
    final ww = weight ?? newWeight;
    final qq = quantity ?? newQuantity;

    final values = <String, double>{};
    if (mm != null) values['meters'] = mm.toDouble();
    if (ww != null) values['weight'] = ww.toDouble();
    if (qq != null) values['quantity'] = qq.toDouble();
    if (values.isEmpty) return;

    // Try to load snapshot row; create if missing.
    final snapKey = paperKey ?? tmcId ?? 'paper';
    final snapshot =
        await _ensureSnapshot(orderId: orderId, itemKey: 'paper:$snapKey');

    // Compute delta per field (only positive deltas are written off).
    final deltas = <String, double>{};
    values.forEach((k, newVal) {
      final already = (snapshot[k] as num?)?.toDouble() ?? 0.0;
      final delta = (newVal - already);
      if (delta > 0) deltas[k] = delta;
    });

    if (deltas.isEmpty) return;

    // 1) Write-off to inventory logs (placeholder; adapt to your tables if needed)
    await _writeOffInventory(
        orderId: orderId,
        itemKey: 'paper:$snapKey',
        fields: deltas,
        unit: unit);

    // 2) Update snapshot so next edit uses new baseline
    final updated = Map<String, dynamic>.from(snapshot)
      ..addAll({
        for (final e in values.entries) e.key: e.value,
        'updated_at': DateTime.now().toIso8601String(),
      });
    await _sb
        .from('order_consumption_snapshots')
        .update(updated)
        .eq('order_id', orderId)
        .eq('item_key', 'paper:$snapKey');
  }

  /// Generic order consumption (paints, pens, materials) by itemKey; idempotent delta.
  Future<void> applyOrderConsumption({
    required String orderId,
    required String itemKey,
    double? quantity,
    double? weight,
    Map<String, double>? components, // e.g., {'C':10, 'M':5}
    String? unit,
  }) async {
    final numeric = <String, double>{};
    if (quantity != null) numeric['quantity'] = quantity;
    if (weight != null) numeric['weight'] = weight;
    if (components != null) {
      for (final e in components.entries) {
        numeric['comp_${e.key}'] = e.value;
      }
    }
    if (numeric.isEmpty) return;

    final snapshot = await _ensureSnapshot(orderId: orderId, itemKey: itemKey);

    final deltas = <String, double>{};
    numeric.forEach((k, newVal) {
      final already = (snapshot[k] as num?)?.toDouble() ?? 0.0;
      final delta = newVal - already;
      if (delta > 0) deltas[k] = delta;
    });
    if (deltas.isEmpty) return;

    await _writeOffInventory(
        orderId: orderId, itemKey: itemKey, fields: deltas, unit: unit);

    final updated = Map<String, dynamic>.from(snapshot)
      ..addAll({
        for (final e in numeric.entries) e.key: e.value,
        'updated_at': DateTime.now().toIso8601String(),
      });
    await _sb
        .from('order_consumption_snapshots')
        .update(updated)
        .eq('order_id', orderId)
        .eq('item_key', itemKey);
  }

  Future<Map<String, dynamic>> _ensureSnapshot({
    required String orderId,
    required String itemKey,
  }) async {
    final q = await _sb
        .from('order_consumption_snapshots')
        .select()
        .eq('order_id', orderId)
        .eq('item_key', itemKey)
        .maybeSingle();

    if (q != null) return q as Map<String, dynamic>;

    final payload = {
      'order_id': orderId,
      'item_key': itemKey,
      'created_at': DateTime.now().toIso8601String(),
      'updated_at': DateTime.now().toIso8601String(),
    };
    await _sb.from('order_consumption_snapshots').insert(payload);
    return payload;
  }

  Future<void> _writeOffInventory({
    required String orderId,
    required String itemKey,
    required Map<String, double> fields,
    String? unit,
  }) async {
    // This is a minimal placeholder. Replace 'inventory_writeoffs' with your table names if needed.
    final payload = {
      'order_id': orderId,
      'item_key': itemKey,
      'unit': unit,
      'fields_json': fields, // JSONB in Postgres
      'created_at': DateTime.now().toIso8601String(),
    };
    try {
      await _sb.from('inventory_writeoffs').insert(payload);
    } catch (_) {
      // If such table doesn't exist, just no-op to avoid crashes.
    }
  }
}
