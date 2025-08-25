import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'orders_provider.dart';
import 'order_model.dart';
import 'product_model.dart';
import 'edit_order_screen.dart';

/// Экран архива заказов. Показывает завершённые заказы с поиском и
/// возможностью переключения вида (список/карточки). Из архива можно
/// возобновить заказ — при этом открывается форма создания нового заказа
/// с заполненными данными, но некоторые поля обнуляются.
class ArchiveOrdersScreen extends StatefulWidget {
  const ArchiveOrdersScreen({super.key});
  @override
  State<ArchiveOrdersScreen> createState() => _ArchiveOrdersScreenState();
}

class _ArchiveOrdersScreenState extends State<ArchiveOrdersScreen> {
  final TextEditingController _searchController = TextEditingController();
  bool _asTable = false;

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  List<OrderModel> _filtered(List<OrderModel> orders) {
    final query = _searchController.text.toLowerCase();
    return orders.where((o) {
      if (o.statusEnum != OrderStatus.completed) return false;
      if (query.isEmpty) return true;
      return o.customer.toLowerCase().contains(query) ||
          o.id.toLowerCase().contains(query) ||
          o.product.type.toLowerCase().contains(query);
    }).toList();
  }

  void _resumeOrder(BuildContext context, OrderModel order) {
    final p = order.product;
    final template = OrderModel(
      id: order.id,
      customer: order.customer,
      orderDate: DateTime.now(),
      dueDate: order.dueDate,
      product: ProductModel(
        id: p.id,
        type: p.type,
        quantity: p.quantity,
        width: p.width,
        height: p.height,
        depth: p.depth,
        parameters: p.parameters,
        roll: null,
        widthB: null,
        length: null,
        leftover: p.leftover,
      ),
      additionalParams: List<String>.from(order.additionalParams),
      handle: order.handle,
      cardboard: order.cardboard,
      material: order.material,
      makeready: order.makeready,
      val: order.val,
      pdfUrl: order.pdfUrl,
      stageTemplateId: null, // очередь очищаем
      contractSigned: order.contractSigned,
      paymentDone: order.paymentDone,
      comments: '',
    );

    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => EditOrderScreen(initialOrder: template),
      ),
    );
  }

  Widget _buildCard(BuildContext context, OrderModel o) {
    final product = o.product;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Заказ ${o.id}', style: const TextStyle(fontWeight: FontWeight.bold)),
            const SizedBox(height: 4),
            Text('Заказчик: ${o.customer}'),
            Text('Продукт: ${product.type}'),
            const SizedBox(height: 8),
            Align(
              alignment: Alignment.centerRight,
              child: TextButton.icon(
                onPressed: () => _resumeOrder(context, o),
                icon: const Icon(Icons.refresh),
                label: const Text('Возобновить'),
              ),
            ),
          ],
        ),
      ),
    );
  }


  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Архив заказов'),
      ),
      body: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          children: [
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _searchController,
                    decoration: InputDecoration(
                      hintText: 'Поиск…',
                      prefixIcon: const Icon(Icons.search),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
                    onChanged: (_) => setState(() {}),
                  ),
                ),
                const SizedBox(width: 12),
                IconButton(
                  icon: Icon(_asTable ? Icons.view_module : Icons.view_list),
                  tooltip: _asTable ? 'Карточки' : 'Таблица',
                  onPressed: () => setState(() => _asTable = !_asTable),
                ),
              ],
            ),
            const SizedBox(height: 16),
            Expanded(
              child: Consumer<OrdersProvider>(
                builder: (context, provider, child) {
                  final orders = _filtered(provider.orders);
                  if (orders.isEmpty) {
                    return const Center(
                      child: Text('Архив заказов пока пуст'),
                    );
                  }
                  if (_asTable) {
                    return ListView.builder(
                      itemCount: orders.length,
                      itemBuilder: (_, i) {
                        final o = orders[i];
                        final product = o.product.type;
                        return ListTile(
                          title: Text(o.customer),
                          subtitle: Text(product),
                          leading: Text(o.id),
                          trailing: TextButton(
                            onPressed: () => _resumeOrder(context, o),
                            child: const Text('Возобновить'),
                          ),
                        );
                      },
                    );
                  } else {
                    return SingleChildScrollView(
                      child: Wrap(
                        spacing: 12,
                        runSpacing: 12,
                        children:
                            orders.map((o) => _buildCard(context, o)).toList(),
                      ),
                    );
                  }
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}