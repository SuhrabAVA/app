/// Действия склада бумаги и краски через журнал.
///
/// Зачем файл: раньше экраны склада меняли `papers.quantity` /
/// `paints.quantity` сами — читали остаток, прибавляли или вычитали и писали
/// число обратно. Возврат не оставлял записи прихода, отмена списания только
/// дописывала «[ОТМЕНЕНО]» в причину, отмена инвентаризации остаток не
/// возвращала вовсе. На 14.09 у 32 бумаг и 36 красок остаток разошёлся с
/// журналом.
///
/// Теперь каждое действие — одна серверная функция: остаток меняет журнал в
/// той же транзакции, запись несёт автора. Прямая правка остатка база больше
/// не теряет (пишет её в журнал сама), но и приложение ей не пользуется.
library;

import 'package:supabase_flutter/supabase_flutter.dart';

/// Типы склада, у которых остаток ведётся только через журнал.
const Set<String> kJournaledStockTypes = <String>{'paper', 'paint'};

/// Остаток типа [type] меняется только через журнал ([StockJournalRepository]).
bool isJournaledStockType(String? type) =>
    kJournaledStockTypes.contains((type ?? '').trim());

/// Движение журнала, которое можно отменить.
enum StockMovement { writeoff, arrival, inventory }

/// Вид записи инвентаризации.
enum StockCountKind {
  /// Пересчёт на складе.
  count,

  /// Правка остатка без пересчёта (исправление ошибки ввода).
  correction,
}

class StockJournalRepository {
  StockJournalRepository(this._sb);

  final SupabaseClient _sb;

  /// Пересчёт или правка остатка. Возвращает остаток после записи.
  Future<double> setQuantity({
    required String type,
    required String itemId,
    required double quantity,
    StockCountKind kind = StockCountKind.count,
    String? note,
    String? actor,
  }) async {
    _requireJournaled(type);
    final result = await _sb.rpc('stock_set_quantity', params: {
      'p_type': type,
      'p_item': itemId,
      'p_qty': quantity,
      'p_kind': kind.name,
      'p_note': note,
      'p_actor': actor,
    });
    return result is num ? result.toDouble() : quantity;
  }

  /// Возврат на склад — приход с источником «возврат».
  Future<void> registerReturn({
    required String type,
    required String itemId,
    required double quantity,
    String? note,
    String? actor,
  }) async {
    _requireJournaled(type);
    await _sb.rpc('stock_register_return', params: {
      'p_type': type,
      'p_item': itemId,
      'p_qty': quantity,
      'p_note': note,
      'p_actor': actor,
    });
  }

  /// Отмена прихода, ручного списания или инвентаризации. Повторная отмена
  /// ничего не делает. Списания по заказам сервер отменить не даст.
  Future<void> cancelMovement({
    required String type,
    required StockMovement movement,
    required String movementId,
    String? actor,
  }) async {
    _requireJournaled(type);
    await _sb.rpc('stock_cancel_movement', params: {
      'p_type': type,
      'p_movement': movement.name,
      'p_id': movementId,
      'p_actor': actor,
    });
  }

  void _requireJournaled(String type) {
    if (!isJournaledStockType(type)) {
      throw ArgumentError.value(
          type, 'type', 'Журнал склада ведётся только для бумаги и краски');
    }
  }
}
