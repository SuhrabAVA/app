import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'orders_provider.dart';
import 'order_model.dart';
import 'edit_order_screen.dart';
import 'view_order_screen.dart';
import 'order_timeline_dialog.dart';
import '../tasks/task_provider.dart';
import '../tasks/task_model.dart';
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

  // Переключатель вида (таблица или карточки)
  bool _asTable = false;
  // Параметры фильтрации: выбранные заказчики и типы продукта
  List<String> _filterCustomers = [];
  List<String> _filterProducts = [];
  DateTimeRange? _filterDateRange;

  /// Проверяет, полностью ли заполнены ключевые поля заказа для отправки
  /// в производство. Заказ считается «незавершённым», если не выбран
  /// шаблон очереди или не указаны значения для roll, widthB и length.
  bool _isIncomplete(OrderModel o) {
    final p = o.product;
    return (o.stageTemplateId == null || o.stageTemplateId!.isEmpty) ||
        p.roll == null || p.widthB == null || p.length == null;
  }
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
              child: Consumer2<OrdersProvider, TaskProvider>(
                builder: (context, ordersProvider, taskProvider, child) {
                  final orders = _filteredOrders(ordersProvider.orders);
                  final allTasks = taskProvider.tasks;
                  if (orders.isEmpty) {
                    return const Center(child: Text('Заказы не найдены'));
                  }
                  // Если выбран режим таблицы, отображаем DataTable, иначе карточки
                  if (_asTable) {
                    return SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      child: DataTable(
                        columns: const [
                          DataColumn(label: Text('№')),
                          DataColumn(label: Text('Заказчик')),
                          DataColumn(label: Text('ID заказа')),
                          DataColumn(label: Text('Дата заказа')),
                          DataColumn(label: Text('Срок')),
                          DataColumn(label: Text('Продукт')),
                          DataColumn(label: Text('Тираж')),
                          DataColumn(label: Text('Статус')),
                          DataColumn(label: Text('Действия')),
                        ],
                        rows: List<DataRow>.generate(
                          orders.length,
                          (index) {
                            final o = orders[index];
                            final product = o.product;
                            final totalQty = product.quantity;
                            final statusInfo = _computeStatus(o, allTasks);
                            final statusLabel = statusInfo.label;
                            final missing = _isIncomplete(o);
                            return DataRow(
                              color: MaterialStateProperty.resolveWith<Color?>((states) {
                                // Если заказ неполон, подсвечиваем строку серым
                                return missing ? Colors.grey.shade200 : null;
                              }),
                      cells: [
                        DataCell(Text('${index + 1}')),
                        DataCell(Text(o.customer)),
                        DataCell(Text(o.id)),
                        DataCell(Text(_formatDate(o.orderDate))),
                        DataCell(Text(_formatDate(o.dueDate))),
                        DataCell(Text(product.type)),
                        DataCell(Text(totalQty.toString())),
                        DataCell(Text(statusLabel)),
                        DataCell(Row(
                          children: [
                            IconButton(
                              icon: const Icon(Icons.remove_red_eye_outlined),
                              tooltip: 'Просмотр',
                              onPressed: () => _openViewOrder(o),
                            ),
                            IconButton(
                              icon: const Icon(Icons.history),
                              tooltip: 'Время',
                              onPressed: () => _showOrderTimeline(o),
                            ),
                            IconButton(
                              icon: const Icon(Icons.edit),
                              tooltip: 'Редактировать',
                              onPressed: () {
                                Navigator.push(
                                  context,
                                  MaterialPageRoute(builder: (_) => EditOrderScreen(order: o)),
                                );
                              },
                            ),
                          ],
                        )),
                      ],
                    );
                          },
                        ),
                      ),
                    );
                  } else {
                    return SingleChildScrollView(
                      child: Wrap(
                        spacing: 12,
                        runSpacing: 12,
                        children: orders.map((o) => _buildOrderCard(o, allTasks)).toList(),
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
        // Переключатель вида: таблица / карточки
        IconButton(
          icon: Icon(_asTable ? Icons.view_module : Icons.view_list),
          tooltip: _asTable ? 'Карточки' : 'Таблица',
          onPressed: () => setState(() => _asTable = !_asTable),
        ),
        // Фильтр
        IconButton(
          icon: const Icon(Icons.filter_alt_outlined),
          tooltip: 'Фильтр',
          onPressed: _openFilter,
        ),
        // Сортировка
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
    // Filter by selected customers
    if (_filterCustomers.isNotEmpty) {
      filtered = filtered.where((o) => _filterCustomers.contains(o.customer)).toList();
    }
    // Filter by selected product types
    if (_filterProducts.isNotEmpty) {
      filtered = filtered.where((o) => _filterProducts.contains(o.product.type)).toList();
    }
    // Filter by date range
    if (_filterDateRange != null) {
      final start = _filterDateRange!.start;
      final end = _filterDateRange!.end;
      filtered = filtered.where((o) {
        final d = o.orderDate;
        return (d.isAtSameMomentAs(start) || d.isAfter(start)) && (d.isAtSameMomentAs(end) || d.isBefore(end.add(const Duration(days: 1))));
      }).toList();
    }
    // Filter by status
    switch (_selectedFilter) {
      case 'new':
        filtered =
            filtered.where((o) => o.statusEnum == OrderStatus.newOrder).toList();
        break;
      case 'inWork':
        filtered =
            filtered.where((o) => o.statusEnum == OrderStatus.inWork).toList();
        break;
      case 'completed':
        filtered = filtered
            .where((o) => o.statusEnum == OrderStatus.completed)
            .toList();
        break;
      case 'all':
      default:
        break;
    }
    int totalQty(OrderModel o) => o.product.quantity;
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

  /// Открывает диалог фильтрации заказов. Позволяет выбрать заказчиков,
  /// типы продуктов и диапазон дат. При подтверждении фильтр применяется.
  void _openFilter() {
    final provider = context.read<OrdersProvider>();
    // Получаем уникальные заказчики и типы изделий из списка заказов
    final customers = provider.orders
        .map((o) => o.customer)
        .toSet()
        .toList()
      ..sort();
    final products = provider.orders
        .map((o) => o.product.type)
        .toSet()
        .toList()
      ..sort();
    // Локальные копии фильтра на время редактирования
    final selectedCustomers = List<String>.from(_filterCustomers);
    final selectedProducts = List<String>.from(_filterProducts);
    DateTimeRange? selectedRange = _filterDateRange;
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (context, setModalState) {
            return Padding(
              padding: EdgeInsets.only(
                bottom: MediaQuery.of(context).viewInsets.bottom + 16,
                left: 16,
                right: 16,
                top: 16,
              ),
              child: SingleChildScrollView(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        const Text('Фильтр', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
                        IconButton(
                          icon: const Icon(Icons.close),
                          onPressed: () => Navigator.pop(context),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    const Text('Заказчики', style: TextStyle(fontWeight: FontWeight.w600)),
                    Wrap(
                      spacing: 6,
                      children: customers
                          .map(
                            (c) => FilterChip(
                              label: Text(c),
                              selected: selectedCustomers.contains(c),
                              onSelected: (sel) {
                                setModalState(() {
                                  if (sel) {
                                    selectedCustomers.add(c);
                                  } else {
                                    selectedCustomers.remove(c);
                                  }
                                });
                              },
                            ),
                          )
                          .toList(),
                    ),
                    const SizedBox(height: 12),
                    const Text('Типы продуктов', style: TextStyle(fontWeight: FontWeight.w600)),
                    Wrap(
                      spacing: 6,
                      children: products
                          .map(
                            (p) => FilterChip(
                              label: Text(p),
                              selected: selectedProducts.contains(p),
                              onSelected: (sel) {
                                setModalState(() {
                                  if (sel) {
                                    selectedProducts.add(p);
                                  } else {
                                    selectedProducts.remove(p);
                                  }
                                });
                              },
                            ),
                          )
                          .toList(),
                    ),
                    const SizedBox(height: 12),
                    const Text('Диапазон дат', style: TextStyle(fontWeight: FontWeight.w600)),
                    const SizedBox(height: 6),
                    Row(
                      children: [
                        Expanded(
                          child: OutlinedButton(
                            onPressed: () async {
                              final now = DateTime.now();
                              final picked = await showDateRangePicker(
                                context: context,
                                firstDate: DateTime(now.year - 5),
                                lastDate: DateTime(now.year + 5),
                                initialDateRange: selectedRange,
                              );
                              if (picked != null) {
                                setModalState(() => selectedRange = picked);
                              }
                            },
                            child: Text(
                              selectedRange == null
                                  ? 'Выбрать период'
                                  : '${_formatDate(selectedRange!.start)} — ${_formatDate(selectedRange!.end)}',
                            ),
                          ),
                        ),
                        if (selectedRange != null)
                          IconButton(
                            icon: const Icon(Icons.clear),
                            onPressed: () => setModalState(() => selectedRange = null),
                          ),
                      ],
                    ),
                    const SizedBox(height: 16),
                    ElevatedButton(
                      onPressed: () {
                        setState(() {
                          _filterCustomers = List<String>.from(selectedCustomers);
                          _filterProducts = List<String>.from(selectedProducts);
                          _filterDateRange = selectedRange;
                        });
                        Navigator.pop(context);
                      },
                      child: const Text('Применить'),
                    ),
                    const SizedBox(height: 8),
                    TextButton(
                      onPressed: () {
                        setState(() {
                          _filterCustomers.clear();
                          _filterProducts.clear();
                          _filterDateRange = null;
                        });
                        Navigator.pop(context);
                      },
                      child: const Text('Сбросить'),
                    ),
                    const SizedBox(height: 16),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }

  /// Открывает экран просмотра заказа.
  void _openViewOrder(OrderModel order) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => ViewOrderScreen(order: order),
      ),
    );
  }

  /// Показывает диалог с хронологией изменений заказа.
  void _showOrderTimeline(OrderModel order) async {
    final provider = context.read<OrdersProvider>();
    final events = await provider.fetchOrderHistory(order.id);
    showDialog(
      context: context,
      builder: (_) => OrderTimelineDialog(order: order, events: events),
    );
  }

  /// Возвращает цвет и текст статуса для заказа с учётом связанных задач.
  _OrderStatusInfo _computeStatus(OrderModel order, List<TaskModel> allTasks) {
    final tasks = allTasks.where((t) => t.orderId == order.id).toList();
    if (tasks.isNotEmpty) {
      if (tasks.every((t) => t.status == TaskStatus.completed)) {
        return const _OrderStatusInfo(Colors.green, 'Завершено');
      }
      if (tasks.any((t) => t.status == TaskStatus.inProgress)) {
        return const _OrderStatusInfo(Colors.orange, 'В работе');
      }
      return const _OrderStatusInfo(Colors.blue, 'Новый');
    }
    switch (order.statusEnum) {
      case OrderStatus.inWork:
        return const _OrderStatusInfo(Colors.orange, 'В работе');
      case OrderStatus.completed:
        return const _OrderStatusInfo(Colors.green, 'Завершено');
      case OrderStatus.newOrder:
      default:
        return const _OrderStatusInfo(Colors.blue, 'Новый');
    }
  }

  /// Контейнер для информации о статусе заказа.
  class _OrderStatusInfo {
    final Color color;
    final String label;
    const _OrderStatusInfo(this.color, this.label);
  }
  /// Строит карточку заказа для отображения в списке.
  Widget _buildOrderCard(OrderModel order, List<TaskModel> allTasks) {
    // Определяем цвет и текст для статуса с учётом задач
    final statusInfo = _computeStatus(order, allTasks);
    final Color statusColor = statusInfo.color;
    final String statusLabel = statusInfo.label;
    final product = order.product;
    final totalQty = product.quantity;
    final missing = _isIncomplete(order);
    return SizedBox(
      width: 320,
      child: Card(
        color: missing ? Colors.grey.shade100 : null,
        elevation: 1,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // Первая строка: заказчик и статус
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Expanded(
                    child: Text(
                      order.customer,
                      style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 14),
                      overflow: TextOverflow.ellipsis,
                    ),
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
              const SizedBox(height: 4),
              // Вторая строка: ID заказа
              Text('ID: ${order.id}', style: const TextStyle(fontSize: 11, color: Colors.grey)),
              const SizedBox(height: 4),
              // Даты
              Row(
                children: [
                  Expanded(
                    child: Text('Дата заказа: ${_formatDate(order.orderDate)}', style: const TextStyle(fontSize: 11)),
                  ),
                  Expanded(
                    child: Text('Срок: ${_formatDate(order.dueDate)}', style: const TextStyle(fontSize: 11)),
                  ),
                ],
              ),
              const SizedBox(height: 6),
              // Информация о продукте
              Text('Изделие: ${product.type}', style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600)),
              const SizedBox(height: 2),
              Text('Тираж: $totalQty шт.', style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600)),
              const SizedBox(height: 6),
              // Статусы договора и оплаты
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
              // Кнопки действий
              Wrap(
                alignment: WrapAlignment.end,
                spacing: 4,
                runSpacing: 4,
                children: [
                  TextButton(
                    onPressed: () => _openViewOrder(order),
                    child: const Text('Просмотр'),
                  ),
                  const SizedBox(width: 4),
                  TextButton(
                    onPressed: () => _showOrderTimeline(order),
                    child: const Text('Время'),
                  ),
                  const SizedBox(width: 4),
                  TextButton(
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