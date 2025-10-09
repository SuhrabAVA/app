// lib/modules/orders/id_format.dart
import 'order_model.dart';

/// Полный человекочитаемый номер заказа:
/// пример: "ЗК-2025.09.23-2". Если assignmentId ещё не присвоен — вернёт "—".
String orderDisplayId(OrderModel o) {
  final a = o.assignmentId;
  if (a != null && a.trim().isNotEmpty) return a;
  return '—';
}

/// Короткий бейдж для карточки: берём хвостовую цифру из assignmentId ("...-2" -> "2").
/// Если assignmentId простой, без дефисов — показываем как есть. Если нет номера — "—".
String orderBadge(OrderModel o) {
  final a = o.assignmentId?.trim() ?? '';
  if (a.isEmpty) return '—';
  final parts = a.split('-');
  if (parts.isEmpty) return a;
  final tail = parts.last;
  return tail.isEmpty ? a : tail;
}
