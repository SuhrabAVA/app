import 'package:flutter/material.dart';
import 'order_model.dart';

/// Displays the details of a single order. This is a very basic
/// implementation that simply lays out a few fields from the order. You can
/// extend this screen with more information and actions as needed.
class ViewOrderScreen extends StatelessWidget {
  final OrderModel order;

  const ViewOrderScreen({super.key, required this.order});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('Заказ ${order.id}'),
      ),
      body: Padding(
        padding: const EdgeInsets.all(16.0),
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Клиент: ${order.customer}'),
              const SizedBox(height: 8),
              Text('Дата заказа: ${order.orderDate.toIso8601String()}'),
              const SizedBox(height: 8),
              Text('Срок: ${order.dueDate.toIso8601String()}'),
              const SizedBox(height: 8),
              // ProductModel uses `type` as a name/description field
              Text('Продукт: ${order.product.type}'),
              const SizedBox(height: 8),
              Text('Количество доп. параметров: ${order.additionalParams.length}'),
              const SizedBox(height: 8),
              Text('Материал: ${order.material?.name ?? '—'}'),
              // You can continue to display other fields if needed
            ],
          ),
        ),
      ),
    );
  }
}