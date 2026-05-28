import 'package:supabase_flutter/supabase_flutter.dart';

import '../models/claim_model.dart';

class ClaimsRepository {
  ClaimsRepository({SupabaseClient? client})
      : _client = client ?? Supabase.instance.client;

  final SupabaseClient _client;

  /// Все претензии за месяц.
  Future<List<ClaimModel>> listForMonth(DateTime month) async {
    final firstDay = DateTime(month.year, month.month, 1);
    final lastDay = DateTime(month.year, month.month + 1, 0, 23, 59, 59);
    final List<dynamic> rows = await _client
        .from('claims')
        .select(
            'id, order_id, comment_id, employee_id, workplace_id, description, created_by, created_at')
        .gte('created_at', firstDay.toUtc().toIso8601String())
        .lte('created_at', lastDay.toUtc().toIso8601String());
    return rows
        .whereType<Map>()
        .map((m) => ClaimModel.fromMap(Map<String, dynamic>.from(m)))
        .toList();
  }

  Future<ClaimModel> create({
    required String orderId,
    required String employeeId,
    String? commentId,
    String? workplaceId,
    String? description,
    String? createdBy,
  }) async {
    final result = await _client
        .from('claims')
        .insert({
          'order_id': orderId,
          'employee_id': employeeId,
          'comment_id': commentId,
          'workplace_id': workplaceId,
          'description': description,
          'created_by': createdBy,
        })
        .select()
        .single();
    return ClaimModel.fromMap(Map<String, dynamic>.from(result));
  }
}
