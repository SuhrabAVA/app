import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../tasks/task_provider.dart';
import '../tasks/task_model.dart';
import '../warehouse/warehouse_table_styles.dart';
import '../personnel/personnel_provider.dart';
import 'orders_provider.dart';
import 'order_model.dart';
import 'product_model.dart';
import 'edit_order_screen.dart';
import 'view_order_screen.dart';
import 'order_timeline_dialog.dart';
import 'id_format.dart';

enum SortOption {
  orderDateAsc,
  orderDateDesc,
  dueDateAsc,
  dueDateDesc,
  quantityAsc,
  quantityDesc,
}

enum ShipmentQuantityMode { tirage, custom, actual }

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
  final Set<String> _shippingInProgress = <String>{};

  /// Проверяет, полностью ли заполнены ключевые поля заказа для отправки
  /// в производство. Заказ считается «незавершённым», если не выбран
  /// шаблон очереди или не указаны значения для roll, widthB и length.
  bool _isIncomplete(OrderModel o) {
    final p = o.product;
    return (o.stageTemplateId == null || o.stageTemplateId!.isEmpty) ||
        p.roll == null ||
        p.widthB == null ||
        p.length == null;
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
              child: Consumer3<OrdersProvider, TaskProvider,
                  PersonnelProvider>(
                builder:
                    (context, ordersProvider, taskProvider, personnel, child) {
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
                        showCheckboxColumn: false,
                        columns: const [
                          DataColumn(label: Text('Номер заказа')),
                          DataColumn(label: Text('Дата')),
                          DataColumn(label: Text('Заказчик')),
                          DataColumn(label: Text('Продукт')),
                          DataColumn(label: Text('Размер')),
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
                            final productSize = _formatProductSize(product);
                            final statusInfo = _computeStatus(o, allTasks);
                            final statusLabel = statusInfo.label;
                            final missing = _isIncomplete(o);
                            final stageName =
                                _currentStageName(o, allTasks, personnel);
                            return DataRow(
                              onSelectChanged: (_) => _openViewOrder(o),
                              color: MaterialStateProperty.resolveWith<Color?>(
                                  (states) {
                                final hoverColor =
                                    warehouseRowHoverColor.resolve(states);
                                if (hoverColor != null) return hoverColor;
                                // Если заказ неполон, подсвечиваем строку серым
                                return missing ? Colors.grey.shade200 : null;
                              }),
                              cells: [
                                DataCell(Text(orderDisplayId(o))),
                                DataCell(Text(_formatDate(o.orderDate))),
                                DataCell(Text(o.customer)),
                                DataCell(Text(product.type)),
                                DataCell(Text(productSize)),
                                DataCell(Text(totalQty.toString())),
                                DataCell(
                                  statusLabel == 'В работе' && stageName != null
                                      ? Tooltip(
                                          message:
                                              'Текущий этап: $stageName',
                                          child: _StatusBadge(
                                              color: statusInfo.color,
                                              label: statusLabel),
                                        )
                                      : _StatusBadge(
                                          color: statusInfo.color,
                                          label: statusLabel,
                                        ),
                                ),
                                DataCell(Row(
                                  children: [
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
                                          MaterialPageRoute(
                                              builder: (_) =>
                                                  EditOrderScreen(order: o)),
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
                    final Map<String, List<OrderModel>> ordersByCustomer = {};
                    for (final o in orders) {
                      ordersByCustomer.putIfAbsent(o.customer, () => []).add(o);
                    }
                    return SingleChildScrollView(
                      child: Wrap(
                        spacing: 10,
                        runSpacing: 10,
                        children: orders
                            .map((o) =>
                                _buildOrderCard(o, allTasks, personnel))
                            .toList(),
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
              border:
                  OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
              contentPadding:
                  const EdgeInsets.symmetric(vertical: 0, horizontal: 12),
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
      if (order.isShipped) return false;
      final matchesSearch = query.isEmpty ||
          order.id.toLowerCase().contains(query) ||
          order.customer.toLowerCase().contains(query);
      return matchesSearch;
    }).toList();
    // Filter by selected customers
    if (_filterCustomers.isNotEmpty) {
      filtered =
          filtered.where((o) => _filterCustomers.contains(o.customer)).toList();
    }
    // Filter by selected product types
    if (_filterProducts.isNotEmpty) {
      filtered = filtered
          .where((o) => _filterProducts.contains(o.product.type))
          .toList();
    }
    // Filter by date range
    if (_filterDateRange != null) {
      final start = _filterDateRange!.start;
      final end = _filterDateRange!.end;
      filtered = filtered.where((o) {
        final d = o.orderDate;
        return (d.isAtSameMomentAs(start) || d.isAfter(start)) &&
            (d.isAtSameMomentAs(end) ||
                d.isBefore(end.add(const Duration(days: 1))));
      }).toList();
    }
    // Filter by status
    switch (_selectedFilter) {
      case 'new':
        filtered = filtered
            .where((o) => o.statusEnum == OrderStatus.newOrder)
            .toList();
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
        filtered.sort((a, b) => (a.dueDate ?? DateTime(2100))
            .compareTo(b.dueDate ?? DateTime(2100)));
        break;
      case SortOption.dueDateDesc:
        filtered.sort((a, b) => (b.dueDate ?? DateTime(2100))
            .compareTo(a.dueDate ?? DateTime(2100)));
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

  String _formatQuantity(num value) {
    final doubleVal = value.toDouble();
    if (doubleVal == doubleVal.roundToDouble()) {
      return doubleVal.toInt().toString();
    }
    return doubleVal.toStringAsFixed(2);
  }

  String _formatProductSize(ProductModel product) {
    String? formatDimension(double? value) {
      if (value == null || value <= 0) return null;
      final rounded = value.toDouble();
      if (rounded == rounded.roundToDouble()) {
        return rounded.toInt().toString();
      }
      return rounded.toStringAsFixed(2);
    }

    final dims = <String>[];
    final width = formatDimension(product.width);
    final height = formatDimension(product.height);
    final depth = formatDimension(product.depth);
    if (width != null) dims.add(width);
    if (height != null) dims.add(height);
    if (depth != null) dims.add(depth);

    var result = dims.join('×');

    final extras = <String>[];
    final roll = formatDimension(product.roll);
    if (roll != null) extras.add('Рулон $roll');
    final widthB = formatDimension(product.widthB);
    if (widthB != null) extras.add('Б $widthB');
    final blQty = product.blQuantity;
    if (blQty != null && blQty.isNotEmpty) extras.add('Кол-во $blQty');
    final length = formatDimension(product.length);
    if (length != null) extras.add('L $length');

    if (extras.isNotEmpty) {
      final extraText = extras.join(', ');
      result = result.isEmpty ? extraText : '$result ($extraText)';
    }

    return result.isEmpty ? '—' : result;
  }

  Future<void> _confirmShipment(OrderModel order) async {
    final double plannedQty = order.product.quantity.toDouble();
    final double actualQty = order.actualQty ?? plannedQty;
    final double safeActual = actualQty < 0 ? 0 : actualQty;
    double? warehouseExtraQty;
    String? warehouseExtraSize;
    try {
      final snapshot =
          await context.read<OrdersProvider>().loadCategoryItemSnapshot(order);
      if (snapshot != null) {
        final dynamic qv = snapshot['quantity'];
        if (qv is num) {
          warehouseExtraQty = qv.toDouble();
        } else if (qv is String) {
          final normalized = qv.replaceAll(',', '.');
          final parsed = double.tryParse(normalized);
          if (parsed != null) {
            warehouseExtraQty = parsed;
          }
        }
        final String sizeRaw = (snapshot['size'] ?? '').toString().trim();
        if (sizeRaw.isNotEmpty) {
          warehouseExtraSize = sizeRaw;
        }
      }
    } catch (e, st) {
      debugPrint('⚠️ shipment leftover snapshot error: $e\n$st');
    }

    double customQty = plannedQty;
    ShipmentQuantityMode mode = ShipmentQuantityMode.tirage;
    final TextEditingController customController =
        TextEditingController(text: _formatQuantity(customQty));
    bool updatingCustomText = false;

    double sliderMax = math.max(plannedQty, safeActual);
    if (warehouseExtraQty != null) {
      sliderMax = math.max(sliderMax, warehouseExtraQty);
    }
    final bool sliderEnabled = sliderMax > 0;
    if (!sliderEnabled) {
      sliderMax = 1;
    }

    final double? selectedWriteoff = await showDialog<double>(
      context: context,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (context, setDialogState) {
            final double effectiveCustom = sliderEnabled
                ? math.max(0, math.min(customQty, sliderMax))
                : math.max(0, customQty);
            double currentWriteoff;
            switch (mode) {
              case ShipmentQuantityMode.tirage:
                currentWriteoff = plannedQty;
                break;
              case ShipmentQuantityMode.actual:
                currentWriteoff = safeActual;
                break;
              case ShipmentQuantityMode.custom:
                currentWriteoff = effectiveCustom;
                break;
            }
            if (currentWriteoff < 0) currentWriteoff = 0;
            final double leftoverQty =
                safeActual > currentWriteoff ? (safeActual - currentWriteoff) : 0;

            return AlertDialog(
              title: const Text('Подтвердить отгрузку?'),
              content: SingleChildScrollView(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text('Заказчик: ${order.customer}'),
                    const SizedBox(height: 8),
                    Text('Тираж: ${_formatQuantity(plannedQty)}'),
                    Text('Факт: ${_formatQuantity(safeActual)}'),
                    if (order.product.leftover != null &&
                        order.product.leftover! > 0)
                      Text(
                        'Запланировано как лишнее: '
                        '${_formatQuantity(order.product.leftover!)}',
                      ),
                    if (warehouseExtraQty != null)
                      Text(
                        'Сейчас на складе: '
                        '${_formatQuantity(warehouseExtraQty!)}',
                      ),
                    if (warehouseExtraSize != null)
                      Text('Размер: $warehouseExtraSize'),
                    const SizedBox(height: 12),
                    RadioListTile<ShipmentQuantityMode>(
                      title: Text(
                          'Списать тираж (${_formatQuantity(plannedQty)})'),
                      value: ShipmentQuantityMode.tirage,
                      groupValue: mode,
                      onChanged: (value) {
                        if (value == null) return;
                        setDialogState(() {
                          mode = value;
                        });
                      },
                    ),
                    RadioListTile<ShipmentQuantityMode>(
                      title: Text(
                          'Списать фактическое (${_formatQuantity(safeActual)})'),
                      value: ShipmentQuantityMode.actual,
                      groupValue: mode,
                      onChanged: (value) {
                        if (value == null) return;
                        setDialogState(() {
                          mode = value;
                        });
                      },
                    ),
                    RadioListTile<ShipmentQuantityMode>(
                      title: const Text('Указать количество'),
                      value: ShipmentQuantityMode.custom,
                      groupValue: mode,
                      onChanged: (value) {
                        if (value == null) return;
                        setDialogState(() {
                          mode = value;
                        });
                      },
                    ),
                    if (mode == ShipmentQuantityMode.custom) ...[
                      TextField(
                        controller: customController,
                        keyboardType: const TextInputType.numberWithOptions(
                            decimal: true),
                        decoration: const InputDecoration(
                          labelText: 'Количество к списанию',
                          border: OutlineInputBorder(),
                        ),
                        onChanged: (value) {
                          if (updatingCustomText) return;
                          final normalized = value.replaceAll(',', '.');
                          final parsed = double.tryParse(normalized);
                          setDialogState(() {
                            customQty =
                                parsed != null && parsed >= 0 ? parsed : 0;
                          });
                        },
                      ),
                      const SizedBox(height: 8),
                      Slider(
                        value: sliderEnabled ? effectiveCustom : 0,
                        min: 0,
                        max: sliderEnabled ? sliderMax : 1,
                        divisions: sliderEnabled
                            ? math
                                .max(
                                    1,
                                    math.min(200,
                                        (sliderMax * 10).round()))
                                .toInt()
                            : null,
                        label: _formatQuantity(
                            sliderEnabled ? effectiveCustom : 0),
                        onChanged: sliderEnabled
                            ? (val) {
                                setDialogState(() {
                                  customQty = val;
                                  updatingCustomText = true;
                                  final text = _formatQuantity(val);
                                  customController.value = TextEditingValue(
                                    text: text,
                                    selection: TextSelection.collapsed(
                                        offset: text.length),
                                  );
                                  updatingCustomText = false;
                                });
                              }
                            : null,
                      ),
                    ],
                    const Divider(),
                    Text('К списанию: ${_formatQuantity(currentWriteoff)}'),
                    Text('Остаток после отгрузки: ${_formatQuantity(leftoverQty)}'),
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(ctx, null),
                  child: const Text('Отмена'),
                ),
                ElevatedButton(
                  onPressed: () => Navigator.pop(ctx, currentWriteoff),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.red,
                    foregroundColor: Colors.white,
                  ),
                  child: const Text('Отгрузить'),
                ),
              ],
            );
          },
        );
      },
    );

    customController.dispose();

    if (selectedWriteoff == null) {
      return;
    }

    setState(() => _shippingInProgress.add(order.id));
    try {
      await context
          .read<OrdersProvider>()
          .shipOrder(order, writeoffOverride: selectedWriteoff);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Заказ отправлен в архив')),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Не удалось выполнить отгрузку: $e')),
      );
    } finally {
      if (mounted) {
        setState(() => _shippingInProgress.remove(order.id));
      }
    }
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
    final customers = provider.orders.map((o) => o.customer).toSet().toList()
      ..sort();
    final products = provider.orders.map((o) => o.product.type).toSet().toList()
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
                        const Text('Фильтр',
                            style: TextStyle(
                                fontSize: 16, fontWeight: FontWeight.w600)),
                        IconButton(
                          icon: const Icon(Icons.close),
                          onPressed: () => Navigator.pop(context),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    const Text('Заказчики',
                        style: TextStyle(fontWeight: FontWeight.w600)),
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
                    const Text('Типы продуктов',
                        style: TextStyle(fontWeight: FontWeight.w600)),
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
                    const Text('Диапазон дат',
                        style: TextStyle(fontWeight: FontWeight.w600)),
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
                            onPressed: () =>
                                setModalState(() => selectedRange = null),
                          ),
                      ],
                    ),
                    const SizedBox(height: 16),
                    ElevatedButton(
                      onPressed: () {
                        setState(() {
                          _filterCustomers =
                              List<String>.from(selectedCustomers);
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
    final executionEvents = events
        .where((event) => (event['source'] ?? '') == 'task_comment')
        .toList();

    showDialog(
      context: context,
      builder: (_) =>
          OrderTimelineDialog(order: order, events: executionEvents),
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

  String? _currentStageName(OrderModel order, List<TaskModel> allTasks,
      PersonnelProvider personnel) {
    final activeTasks = allTasks
        .where((t) =>
            t.orderId == order.id && t.status == TaskStatus.inProgress)
        .toList()
      ..sort((a, b) => (a.startedAt ?? 0).compareTo(b.startedAt ?? 0));
    if (activeTasks.isEmpty) return null;
    final stageId = activeTasks.first.stageId;
    if (stageId.isEmpty) return null;
    try {
      final wp =
          personnel.workplaces.firstWhere((w) => w.id == stageId);
      if (wp.name.trim().isNotEmpty) return wp.name.trim();
    } catch (_) {}
    return stageId;
  }

  /// Строит карточку заказа для отображения в списке.
  Widget _buildOrderCard(OrderModel order, List<TaskModel> allTasks,
      PersonnelProvider personnel) {
    // Определяем цвет и текст для статуса с учётом задач
    final statusInfo = _computeStatus(order, allTasks);
    final Color statusColor = statusInfo.color;
    final String statusLabel = statusInfo.label;
    final product = order.product;
    final totalQty = product.quantity;
    final productSize = _formatProductSize(product);
    final missing = _isIncomplete(order);
    final bool isCompleted = statusLabel == 'Завершено';
    final bool isShipping = _shippingInProgress.contains(order.id);
    final String? stageName =
        _currentStageName(order, allTasks, personnel);
    return SizedBox(
      width: 240,
      child: Card(
        color: missing ? Colors.grey.shade100 : null,
        elevation: 1,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: () => _openViewOrder(order),
          child: Padding(
            padding: const EdgeInsets.all(8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // Номер и статус заказа
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(
                      '№ ${orderDisplayId(order)}',
                      style: const TextStyle(
                        fontWeight: FontWeight.w700,
                        fontSize: 13,
                      ),
                    ),
                    statusLabel == 'В работе' && stageName != null
                        ? Tooltip(
                            message: 'Текущий этап: $stageName',
                            child: _StatusBadge(
                                color: statusColor, label: statusLabel),
                          )
                        : _StatusBadge(color: statusColor, label: statusLabel),
                  ],
                ),
                const SizedBox(height: 4),
                // Заказчик
                Text(
                  order.customer,
                  style: const TextStyle(
                      fontWeight: FontWeight.w600, fontSize: 12),
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 4),
                // Дата заказа
                Text('Дата заказа: ${_formatDate(order.orderDate)}',
                    style: const TextStyle(fontSize: 10, color: Colors.grey)),
                const SizedBox(height: 6),
                // Информация о продукте
                Text('Изделие: ${product.type}',
                    style: const TextStyle(
                        fontSize: 11, fontWeight: FontWeight.w600)),
                const SizedBox(height: 2),
                Text('Размер: $productSize',
                    style: const TextStyle(fontSize: 11)),
                const SizedBox(height: 2),
                Text('Тираж: $totalQty шт.',
                    style: const TextStyle(
                        fontSize: 11, fontWeight: FontWeight.w600)),
                if (isCompleted)
                  Padding(
                    padding: const EdgeInsets.only(top: 4.0),
                    child: Text(
                      'Факт: ${order.actualQty != null ? _formatQuantity(order.actualQty!) : '—'} шт.',
                      style: const TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                const SizedBox(height: 8),
                // Кнопки действий
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Row(
                      children: [
                        IconButton(
                          onPressed: () => _showOrderTimeline(order),
                          icon: const Icon(Icons.schedule),
                          tooltip: 'Время',
                        ),
                        IconButton(
                          onPressed: () {
                            Navigator.push(
                              context,
                              MaterialPageRoute(
                                  builder: (_) =>
                                      EditOrderScreen(order: order)),
                            );
                          },
                          icon: const Icon(Icons.edit_outlined),
                          tooltip: 'Редактировать',
                        ),
                      ],
                    ),
                    if (isCompleted && !order.isShipped)
                      ElevatedButton(
                        onPressed:
                            isShipping ? null : () => _confirmShipment(order),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: Colors.red,
                          foregroundColor: Colors.white,
                        ),
                        child: isShipping
                            ? const SizedBox(
                                width: 18,
                                height: 18,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                  valueColor:
                                      AlwaysStoppedAnimation<Color>(Colors.white),
                                ),
                              )
                            : const Text('Отгрузить'),
                      ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  String _formatDate(DateTime? date) {
    if (date == null) return '—';
    if (date == null) return '—';
    return '${date.day.toString().padLeft(2, '0')}.${date.month.toString().padLeft(2, '0')}.${date.year}';
  }
}

class _OrderStatusInfo {
  final Color color;
  final String label;
  const _OrderStatusInfo(this.color, this.label);
}

class _StatusBadge extends StatelessWidget {
  const _StatusBadge({required this.color, required this.label});

  final Color color;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: color.withOpacity(0.1),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(
        label,
        style: TextStyle(color: color, fontSize: 12),
      ),
    );
  }
}
