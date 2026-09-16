import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// Backwards-compatible entry point for order-completion pen write-offs.
///
/// The database RPC derives the item and quantity from the completed order and
/// owns idempotency. Keeping the write atomic avoids the former SELECT/INSERT
/// race when two devices observe the same completion.
Future<void> logHandlesWriteoffOnOrderComplete({
  required String orderId,
  String? penTypeId,
  String? colorId,
  num? actualQuantityPairs,
  String? customerName,
  DateTime? occurredAt,
  SupabaseClient? client,
}) async {
  final normalizedOrderId = orderId.trim();
  if (normalizedOrderId.isEmpty) return;
  if ((actualQuantityPairs ?? 0) <= 0) return;
  if ((penTypeId ?? '').trim().isEmpty) return;

  final sb = client ?? Supabase.instance.client;
  try {
    await sb.rpc(
      'record_order_pens_completion_writeoff',
      params: {'p_order_id': normalizedOrderId, 'p_actor': null},
    );
  } on PostgrestException catch (error, stackTrace) {
    debugPrint(
      'Unable to record pens write-off for order $normalizedOrderId: '
      '${error.message}',
    );
    debugPrintStack(stackTrace: stackTrace);
  } catch (error, stackTrace) {
    debugPrint(
      'Unexpected pens write-off error for order $normalizedOrderId: $error',
    );
    debugPrintStack(stackTrace: stackTrace);
  }
}
