import 'package:flutter/material.dart';
import 'order_model.dart';

/// A dialog that displays the history (timeline) of events associated with an
/// order. It expects a list of event maps, where each map should contain
/// at least `timestamp`, `event_type`, `quantity_change`, and `note` keys.
class OrderTimelineDialog extends StatelessWidget {
  final OrderModel order;
  final List<Map<String, dynamic>> events;

  const OrderTimelineDialog({
    super.key,
    required this.order,
    required this.events,
  });

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text('История заказа ${order.id}'),
      content: SizedBox(
        width: double.maxFinite,
        child: events.isEmpty
            ? const Text('История пуста')
            : ListView.builder(
                shrinkWrap: true,
                itemCount: events.length,
                itemBuilder: (_, index) {
                  final event = events[index];
                  final time = (event['timestamp'] ?? '').toString();
                  final type = (event['event_type'] ?? '').toString();
                  final qtyChange = (event['quantity_change'] ?? '').toString();
                  final note = (event['note'] ?? '').toString();
                  return ListTile(
                    title: Text(type.isNotEmpty ? type : 'Событие'),
                    subtitle: Text(
                      'Время: $time\nКол-во: $qtyChange\nПримечание: $note',
                    ),
                  );
                },
              ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Закрыть'),
        ),
      ],
    );
  }
}