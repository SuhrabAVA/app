import 'package:flutter/foundation.dart';
import 'package:postgrest/postgrest.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// Константы для таблицы и колонок логирования списаний ручек.
const String kHandlesWriteoffTable = 'handles_writeoffs';
const String kOrderIdColumn = 'order_id';
const String kPenTypeIdColumn = 'pen_type_id';
const String kColorIdColumn = 'color_id';
const String kQuantityPairsColumn = 'quantity_pairs';
const String kOccurredAtColumn = 'occurred_at';
const String kCommentColumn = 'comment';

/// Логирует списание ручек при переводе заказа в статус `completed`.
///
/// Создаёт запись в таблице списаний, если выбран тип ручек и фактическое
/// количество больше нуля. Запрос выполняется идемпотентно: при наличии записи
/// с тем же [orderId] повторная вставка не выполняется.
Future<void> logHandlesWriteoffOnOrderComplete({
  required String orderId,
  String? penTypeId,
  String? colorId,
  num? actualQuantityPairs,
  String? customerName,
  SupabaseClient? client,
}) async {
  final qty = actualQuantityPairs ?? 0;
  if (qty <= 0) {
    return;
  }

  if (penTypeId == null || penTypeId.isEmpty) {
    return;
  }

  final SupabaseClient sb = client ?? Supabase.instance.client;

  try {
    final existing = await sb
        .from(kHandlesWriteoffTable)
        .select(kOrderIdColumn)
        .eq(kOrderIdColumn, orderId)
        .limit(1)
        .maybeSingle();

    if (existing != null) {
      return;
    }

    final payload = <String, dynamic>{
      kOrderIdColumn: orderId,
      kPenTypeIdColumn: penTypeId,
      if (colorId != null && colorId.isNotEmpty) kColorIdColumn: colorId,
      kQuantityPairsColumn: qty,
      kOccurredAtColumn: DateTime.now().toUtc().toIso8601String(),
      kCommentColumn: customerName,
    };

    await sb.from(kHandlesWriteoffTable).insert(payload);
  } on PostgrestException catch (error, stackTrace) {
    debugPrint(
      'Не удалось записать списание ручек для заказа $orderId: ${error.message}',
    );
    debugPrintStack(stackTrace: stackTrace);
  } catch (error, stackTrace) {
    debugPrint(
      'Неизвестная ошибка при логировании списания ручек для заказа $orderId: $error',
    );
    debugPrintStack(stackTrace: stackTrace);
  }
}

/// Пример вызова после успешного сохранения заказа со статусом `completed`.
Future<void> exampleLogWriteoffAfterOrderSaved() async {
  await logHandlesWriteoffOnOrderComplete(
    orderId: 'order-uuid',
    penTypeId: 'handles-type-uuid',
    colorId: 'color-uuid',
    actualQuantityPairs: 12,
    customerName: 'ООО «Ручки и Ко»',
  );
}
