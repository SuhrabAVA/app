import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'orders_provider.dart';
import 'order_model.dart';
import 'edit_order_screen.dart';
enum SortOption {
  orderDateAsc,
  orderDateDesc,
  dueDateAsc,
  dueDateDesc,
  quantityAsc,
  quantityDesc,
}

enum SortOption {
  orderDateAsc,
  orderDateDesc,
  dueDateAsc,
  dueDateDesc,
  quantityAsc,
  quantityDesc,
}

/// Главный экран модуля оформления заказа. Показывает список заказов с
/// возможностью фильтрации по статусам, поиска и создания нового заказа.
class OrdersScreen extends StatefulWidget {
  const OrdersScreen({super.key});

  @override
  State<OrdersScreen> createState() => _OrdersScreenState();
}

class _OrdersScreenState extends State<OrdersScreen> {
  final TextEditingController _searchController = TextEditingController();
  String _selectedFilter = 'all';
  SortOption _sortOption = SortOption.orderDateDesc;

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Модуль оформления заказа'),
        actions: [
          TextButton.icon(
            onPressed: () {
              // История заказов — пока просто snackbar
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('Раздел "История" в разработке')),
              );
            },
            icon: const Icon(Icons.history, color: Colors.white),
            label: const Text('История', style: TextStyle(color: Colors.white)),
          ),
          const SizedBox(width: 8),
          ElevatedButton.icon(
            onPressed: () {
              Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => const EditOrderScreen()),
              );
            },
            icon: const Icon(Icons.add),
            label: const Text('Новый заказ'),
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.black,
              foregroundColor: Colors.white,
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            ),
          ),
          const SizedBox(width: 12),
        ],
      ),
      body: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _buildSearchAndControls(),
            const SizedBox(height: 16),
            _buildStatusTabs(),
            const SizedBox(height: 12),
            Expanded(
              child: Consumer<OrdersProvider>(
                builder: (context, provider, child) {
                  final orders = _filteredOrders(provider.orders);
                  if (orders.isEmpty) {
                    return const Center(child: Text('Заказы не найдены'));
                  }
                  return SingleChildScrollView(
                    child: Wrap(
                      spacing: 12,
                      runSpacing: 12,
                      children: orders.map(_buildOrderCard).toList(),
                    ),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// Строит строку поиска и кнопки сортировки/фильтра.
  Widget _buildSearchAndControls() {
    return Row(
      children: [
        // Поиск
        Expanded(
          child: TextField(
            controller: _searchController,
            decoration: InputDecoration(
              hintText: 'Поиск заказов…',
              prefixIcon: const Icon(Icons.search),
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
              contentPadding: const EdgeInsets.symmetric(vertical: 0, horizontal: 12),
            ),
            onChanged: (_) => setState(() {}),
          ),
        ),
        const SizedBox(width: 12),
        // Фильтр (пока заглушка)
        IconButton(
          icon: const Icon(Icons.filter_alt_outlined),
          onPressed: () {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('Фильтр в разработке')),
            );
          },
        ),

        IconButton(
          icon: const Icon(Icons.sort),
          onPressed: _showSortOptions,
        ),
        
      ],
    );
  }

  /// Строит сегменты для выбора статуса заказа.
  Widget _buildStatusTabs() {
    final tabs = [
      {'key': 'all', 'label': 'Все заказы'},
      {'key': 'new', 'label': 'Новые'},
      {'key': 'inWork', 'label': 'В работе'},
      {'key': 'completed', 'label': 'Завершенные'},
    ];
    return Row(
      mainAxisAlignment: MainAxisAlignment.start,
      children: tabs.map((tab) {
        final key = tab['key'] as String;
        final selected = _selectedFilter == key;
        return Padding(
          padding: const EdgeInsets.only(right: 8.0),
          child: ChoiceChip(
            label: Text(tab['label'] as String),
            selected: selected,
            onSelected: (_) => setState(() => _selectedFilter = key),
            selectedColor: Colors.black,
            labelStyle: TextStyle(
              color: selected ? Colors.white : Colors.black,
              fontWeight: FontWeight.w500,
            ),
            backgroundColor: Colors.grey.shade200,
          ),
        );
      }).toList(),
    );
  }

  List<OrderModel> _filteredOrders(List<OrderModel> all) {
    // Filter by search query
    final query = _searchController.text.toLowerCase();
    List<OrderModel> filtered = all.where((order) {
      final matchesSearch = query.isEmpty || order.id.toLowerCase().contains(query) || order.customer.toLowerCase().contains(query);
      return matchesSearch;
    }).toList();
    // Filter by status
    switch (_selectedFilter) {
      case 'new':
        filtered = filtered.where((o) => o.status == OrderStatus.newOrder).toList();
        break;
      case 'inWork':
        filtered = filtered.where((o) => o.status == OrderStatus.inWork).toList();
        break;
      case 'completed':
        filtered = filtered.where((o) => o.status == OrderStatus.completed).toList();
        break;
      case 'all':
      default:
        break;
    }
    int totalQty(OrderModel o) =>
        o.products.fold<int>(0, (sum, p) => sum + p.quantity);
    switch (_sortOption) {
      case SortOption.orderDateAsc:
        filtered.sort((a, b) => a.orderDate.compareTo(b.orderDate));
        break;
      case SortOption.orderDateDesc:
        filtered.sort((a, b) => b.orderDate.compareTo(a.orderDate));
        break;
      case SortOption.dueDateAsc:
        filtered.sort((a, b) => a.dueDate.compareTo(b.dueDate));
        break;
      case SortOption.dueDateDesc:
        filtered.sort((a, b) => b.dueDate.compareTo(a.dueDate));
        break;
      case SortOption.quantityAsc:
        filtered.sort((a, b) => totalQty(a).compareTo(totalQty(b)));
        break;
      case SortOption.quantityDesc:
        filtered.sort((a, b) => totalQty(b).compareTo(totalQty(a)));
        break;
    }
    return filtered;
  }

void _showSortOptions() {

    showModalBottomSheet(
      context: context,
      builder: (context) {
        return Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            RadioListTile<SortOption>(
              title: const Text('По дате (новые сначала)'),
              value: SortOption.orderDateDesc,
              groupValue: _sortOption,
              onChanged: (value) {
                setState(() => _sortOption = value!);
                Navigator.pop(context);
              },
            ),
            RadioListTile<SortOption>(
              title: const Text('По дате (старые сначала)'),
              value: SortOption.orderDateAsc,
              groupValue: _sortOption,
              onChanged: (value) {
                setState(() => _sortOption = value!);
                Navigator.pop(context);
              },
            ),
            RadioListTile<SortOption>(
              title: const Text('По сроку (раньше)'),
              value: SortOption.dueDateAsc,
              groupValue: _sortOption,
              onChanged: (value) {
                setState(() => _sortOption = value!);
                Navigator.pop(context);
              },
            ),
            RadioListTile<SortOption>(
              title: const Text('По сроку (позже)'),
              value: SortOption.dueDateDesc,
              groupValue: _sortOption,
              onChanged: (value) {
                setState(() => _sortOption = value!);
                Navigator.pop(context);
              },
            ),
            RadioListTile<SortOption>(
              title: const Text('По тиражу (меньше)'),
              value: SortOption.quantityAsc,
              groupValue: _sortOption,
              onChanged: (value) {
                setState(() => _sortOption = value!);
                Navigator.pop(context);
              },
            ),
            RadioListTile<SortOption>(
              title: const Text('По тиражу (больше)'),
              value: SortOption.quantityDesc,
              groupValue: _sortOption,
              onChanged: (value) {
                setState(() => _sortOption = value!);
                Navigator.pop(context);
              },
            ),
          ],
        );
      },
    );
  }

  /// Строит карточку заказа для отображения в списке.
  Widget _buildOrderCard(OrderModel order) {
    // Определяем цвет для статуса
    Color statusColor;
    String statusLabel;
    switch (order.status) {
      case OrderStatus.inWork:
        statusColor = Colors.orange;
        statusLabel = 'В работе';
        break;
      case OrderStatus.completed:
        statusColor = Colors.green;
        statusLabel = 'Завершен';
        break;
      case OrderStatus.newOrder:
      default:
        statusColor = Colors.blue;
        statusLabel = 'Новый';
        break;
    }
    // Вычисляем общий тираж
    final totalQty = order.products.fold<int>(0, (sum, p) => sum + p.quantity);
    return SizedBox(
      width: 320,
      child: Card(
        elevation: 1,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    order.id,
                    style: const TextStyle(fontWeight: FontWeight.w700),
                  ),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                    decoration: BoxDecoration(
                      color: statusColor.withOpacity(0.1),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Text(
                      statusLabel,
                      style: TextStyle(color: statusColor, fontSize: 12),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 6),
              Text('Заказчик: ${order.customer}', style: const TextStyle(fontSize: 12)),
              const SizedBox(height: 4),
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Дата заказа: ${_formatDate(order.orderDate)}', style: const TextStyle(fontSize: 12)),
                  const SizedBox(height: 2),
                  Text('Срок выполнения: ${_formatDate(order.dueDate)}', style: const TextStyle(fontSize: 12)),
                ],
              ),

              const SizedBox(height: 6),
              // Перечень продуктов
              if (order.products.isNotEmpty)
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Продукты (${order.products.length}):', style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600)),
                    ...order.products.map((p) => Text('• ${p.type} (${p.quantity})', style: const TextStyle(fontSize: 12))).toList(),
                  ],
                ),
              const SizedBox(height: 6),
              Text('Общий тираж: $totalQty шт.', style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600)),
              const SizedBox(height: 6),
              Row(
                children: [
                  Row(
                    children: [
                      Icon(order.contractSigned ? Icons.check_circle_outline : Icons.error_outline, size: 16, color: order.contractSigned ? Colors.green : Colors.red),
                      const SizedBox(width: 4),
                      Text(order.contractSigned ? 'Договор подписан' : 'Договор не подписан', style: TextStyle(fontSize: 11, color: order.contractSigned ? Colors.green : Colors.red)),
                    ],
                  ),
                  const SizedBox(width: 8),
                  Row(
                    children: [
                      Icon(order.paymentDone ? Icons.check_circle_outline : Icons.error_outline, size: 16, color: order.paymentDone ? Colors.green : Colors.red),
                      const SizedBox(width: 4),
                      Text(order.paymentDone ? 'Оплачено' : 'Не оплачено', style: TextStyle(fontSize: 11, color: order.paymentDone ? Colors.green : Colors.red)),
                    ],
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  OutlinedButton(
                    onPressed: () {
                      Navigator.push(
                        context,
                        MaterialPageRoute(builder: (_) => EditOrderScreen(order: order)),
                      );
                    },
                    child: const Text('Редактировать'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  String _formatDate(DateTime date) {
    return '${date.day.toString().padLeft(2, '0')}.${date.month.toString().padLeft(2, '0')}.${date.year}';
  }
}