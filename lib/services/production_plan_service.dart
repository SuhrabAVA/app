// lib/services/production_plan_service.dart
import 'package:supabase_flutter/supabase_flutter.dart';

class ProductionPlanService {
  final SupabaseClient _sb;
  ProductionPlanService(this._sb);

  /// Assign a template to an order and let the DB trigger build the plan+stages.
  Future<void> setTemplateForOrder({
    required String orderId,
    required String templateId,
  }) async {
    await _sb.from('orders').update({'prod_template_id': templateId}).eq('id', orderId);
    // DB trigger trg_orders_sync_prod_plan_upd will copy stages automatically.
  }

  /// Optional: call the SQL function directly (not required if trigger is installed).
  Future<String?> createPlanNow({
    required String orderId,
    required String templateId,
  }) async {
    final res = await _sb.rpc('copy_template_to_plan', params: {
      'p_order_id': orderId,
      'p_template_id': templateId,
    });
    // Returns plan_id (String) or null
    if (res == null) return null;
    return res as String;
  }
}
