import 'dart:async';
import 'dart:math' as math;
import 'package:supabase_flutter/supabase_flutter.dart';
import 'order_edit_lease.dart';
import 'order_editing_frame.dart';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../tasks/task_provider.dart';
import '../tasks/task_model.dart';
import '../tasks/task_completion_rules.dart';
import '../warehouse/add_entry_dialog.dart';
import '../warehouse/paint_stock_rules.dart';
import '../warehouse/warehouse_provider.dart';
import '../personnel/personnel_provider.dart';
import 'orders_provider.dart';
import 'order_model.dart';
import 'material_shortage_lines.dart';
import 'order_deadline_countdown.dart';
import 'order_deadline_timer.dart';
import 'order_form_design.dart';
import 'product_model.dart';
import 'edit_order_screen.dart';
import 'view_order_screen.dart';
import 'id_format.dart';
import 'order_launch_rules.dart';
import 'order_shipment_rules.dart';
import 'order_shipments_table.dart';

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
  Timer? _editPoll;
  bool _editPollBusy = false;
  Map<String, String> _editors = {};

  Future<void> _refreshEdits() async {
    // Пока миграция блокировок не применена, функции в базе нет. Без этой
    // проверки список заказов дёргал бы несуществующий RPC каждые две секунды.
    if (_editPollBusy || !OrderEditLockSupport.installed) return;
    _editPollBusy = true;
    try {
      final rows = await Supabase.instance.client.rpc('active_order_edits')
          .timeout(const Duration(seconds: 8));
      final next = <String, String>{
        for (final row in rows as List) row['order_id'] as String: row['editor_name'] as String,
      };
      if (mounted && (next.length != _editors.length ||
          next.entries.any((e) => _editors[e.key] != e.value))) {
        setState(() => _editors = next);
      }
    } catch (error) {
      // Функций нет или нет входа — показывать нечего и спрашивать некого.
      if (OrderEditLockSupport.isNotInstalled(error) ||
          OrderEditLockSupport.isNotPermitted(error)) {
        if (OrderEditLockSupport.isNotInstalled(error)) {
          OrderEditLockSupport.installed = false;
        }
        _editPoll?.cancel();
        if (mounted && _editors.isNotEmpty) setState(() => _editors = {});
      }
      // Keep known locks on a network error. Acquisition is always server checked.
    } finally {
      _editPollBusy = false;
    }
  }

  final TextEditingController _searchController = TextEditingController();
  String _selectedFilter = 'all';
  SortOption _sortOption = SortOption.orderDateDesc;

  // Переключатель вида (таблица или карточки)
  bool _asTable = false;
  // Параметры фильтрации: выбранные заказчики и типы продукта
  // Фильтр по менеджеру заказа, а не по заказчику: заказчиков в базе под
  // две сотни, и список чипов занимал весь экран, тогда как менеджеров семь.
  List<String> _filterManagers = [];
  List<String> _filterProducts = [];
  DateTimeRange? _filterDateRange;
  final Set<String> _shippingInProgress = <String>{};
  final Set<String> _launchingInProgress = <String>{};
  final ScrollController _tableHorizontalController = ScrollController();
  final ScrollController _tableVerticalController = ScrollController();
  final ScrollController _cardsScrollController = ScrollController();

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
  void initState() {
    super.initState();
    _refreshEdits();
    _editPoll = Timer.periodic(const Duration(seconds: 2), (_) => _refreshEdits());
    // Пересчёт обеспеченности при открытии списка.
    //
    // Статус заказа меняет только тот, кто пересчитал остаток, а пересчёт
    // запускается из StockAvailabilityRecheckCoordinator — то есть на
    // устройстве, где прошёл приход. Realtime приносит менеджеру уже готовый
    // статус и сам ничего не считает. Если приход прошёл там, где пересчёт не
    // случился (старая версия приложения, оборванная сеть, ошибка в пересчёте),
    // заказ так и висел бы в «Ожидании материалов» при полном складе — и
    // поднять его было бы нечем: кнопки «перепроверить» на экране нет.
    //
    // Открытие списка — естественный момент проверить это заново.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      unawaited(
        context.read<OrdersProvider>().recheckMaterialAvailability(),
      );
    });
  }

  @override
  void dispose() {
    _editPoll?.cancel();
    _searchController.dispose();
    _tableHorizontalController.dispose();
    _tableVerticalController.dispose();
    _cardsScrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Оформление общее с формой заказа и карточкой задания: экраны модуля
    // открываются один из другого, разный вид читался бы как разные окна.
    return Scaffold(
      backgroundColor: OrderFormColors.background,
      appBar: AppBar(
        backgroundColor: OrderFormColors.surface,
        surfaceTintColor: OrderFormColors.surface,
        elevation: 0,
        scrolledUnderElevation: 0,
        shape: const Border(
          bottom: BorderSide(color: OrderFormColors.border),
        ),
        titleTextStyle: const TextStyle(
          fontSize: 15,
          fontWeight: FontWeight.w600,
          color: OrderFormColors.text,
        ),
        iconTheme: const IconThemeData(color: OrderFormColors.muted),
        title: const Text('Модуль оформления заказа'),
        actions: [
          Padding(
            padding: const EdgeInsets.fromLTRB(4, 8, 12, 8),
            child: FilledButton.icon(
              onPressed: () {
                Navigator.push(
                  context,
                  MaterialPageRoute(builder: (_) => const EditOrderScreen()),
                );
              },
              icon: const Icon(Icons.add, size: 15),
              label: const Text('Новый заказ'),
              style: FilledButton.styleFrom(
                visualDensity: VisualDensity.compact,
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                padding:
                    const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                backgroundColor: OrderFormColors.accent,
                foregroundColor: Colors.white,
                textStyle:
                    const TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
            ),
          ),
        ],
      ),
      body: Padding(
        padding: const EdgeInsets.fromLTRB(12, 12, 12, 0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _buildSearchAndControls(),
            const SizedBox(height: 10),
            _buildStatusTabs(),
            const SizedBox(height: 10),
            Expanded(
              child: Consumer4<OrdersProvider, TaskProvider, PersonnelProvider,
                  WarehouseProvider>(
                builder: (context, ordersProvider, taskProvider, personnel,
                    warehouse, child) {
                  final orders = _filteredOrders(ordersProvider.orders);
                  final allTasks = taskProvider.tasks;
                  if (orders.isEmpty) {
                    return const Center(
                      child: Text(
                        'Заказы не найдены',
                        style: TextStyle(
                          fontSize: 13,
                          color: OrderFormColors.placeholder,
                        ),
                      ),
                    );
                  }
                  if (_asTable) {
                    return _buildOrdersTable(
                        orders, allTasks, personnel, warehouse);
                  }
                  return Scrollbar(
                    controller: _cardsScrollController,
                    thumbVisibility: true,
                    child: SingleChildScrollView(
                      controller: _cardsScrollController,
                      padding: const EdgeInsets.only(bottom: 24),
                      child: Wrap(
                        spacing: 10,
                        runSpacing: 10,
                        children: orders
                            .map((o) => _buildOrderCard(
                                o, allTasks, personnel, warehouse))
                            .toList(),
                      ),
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

  // Номера заказа в таблице нет: в списке по нему не ищут и не сверяются —
  // он остался в карточке заказа и в поиске. Освободившееся место занял срок,
  // ради которого список и открывают.
  static const double _colDate = 110;
  static const double _colTimer = 140;
  static const double _colCustomer = 170;
  static const double _colProduct = 150;
  static const double _colSize = 130;
  static const double _colQty = 90;
  static const double _colStatus = 150;
  static const double _colActions = 180;
  static const double _tableMinWidth = _colTimer +
      _colDate +
      _colCustomer +
      _colProduct +
      _colSize +
      _colQty +
      _colStatus +
      _colActions +
      24;

  Widget _buildOrdersTable(
    List<OrderModel> orders,
    List<TaskModel> allTasks,
    PersonnelProvider personnel,
    WarehouseProvider warehouse,
  ) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final tableWidth = math.max(constraints.maxWidth, _tableMinWidth);
        return Scrollbar(
          controller: _tableHorizontalController,
          thumbVisibility: true,
          child: SingleChildScrollView(
            controller: _tableHorizontalController,
            scrollDirection: Axis.horizontal,
            child: SizedBox(
              width: tableWidth,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _buildTableHeader(),
                  const SizedBox(height: 6),
                  Expanded(
                    child: Scrollbar(
                      controller: _tableVerticalController,
                      thumbVisibility: true,
                      child: ListView.builder(
                        controller: _tableVerticalController,
                        padding: const EdgeInsets.only(bottom: 24),
                        itemCount: orders.length,
                        itemBuilder: (context, index) => _buildTableRow(
                          orders[index],
                          allTasks,
                          personnel,
                          warehouse,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildTableHeader() {
    const headerStyle = TextStyle(
      fontSize: 10.5,
      fontWeight: FontWeight.w700,
      letterSpacing: 1.1,
      color: OrderFormColors.label,
    );
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: OrderFormColors.surface,
        borderRadius: BorderRadius.circular(OrderFormMetrics.cardRadius),
        border: Border.all(color: OrderFormColors.border),
      ),
      child: const Row(
        children: [
          SizedBox(width: _colDate, child: Text('ДАТА', style: headerStyle)),
          SizedBox(width: _colTimer, child: Text('ОСТАЛОСЬ', style: headerStyle)),
          SizedBox(width: _colCustomer, child: Text('ЗАКАЗЧИК', style: headerStyle)),
          SizedBox(width: _colProduct, child: Text('ПРОДУКТ', style: headerStyle)),
          SizedBox(width: _colSize, child: Text('РАЗМЕР', style: headerStyle)),
          SizedBox(width: _colQty, child: Text('ТИРАЖ', style: headerStyle)),
          Expanded(child: Text('СТАТУС', style: headerStyle)),
          SizedBox(
            width: _colActions,
            child: Align(
              alignment: Alignment.centerRight,
              child: Text('ДЕЙСТВИЯ', style: headerStyle),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildTableRow(
    OrderModel order,
    List<TaskModel> allTasks,
    PersonnelProvider personnel,
    WarehouseProvider warehouse,
  ) {
    final product = order.product;
    final statusInfo = _computeStatus(order, allTasks);
    final missing = _isIncomplete(order);
    final isMaterialBlocked =
        order.statusEnum == OrderStatus.waiting_materials;
    final stageName = _currentStageName(order, allTasks, personnel);
    final canLaunch = _canLaunchOrder(order, warehouse);
    final isLaunching = _launchingInProgress.contains(order.id);
    final isCompleted = statusInfo.label == 'Завершено';
    final isShipping = _shippingInProgress.contains(order.id);

    final statusBadge = _StatusBadge(
      color: statusInfo.color,
      label: statusInfo.label,
    );

    return OrderEditingFrame(
      editorName: _editors[order.id],
      child: Container(
      margin: const EdgeInsets.only(bottom: 6),
      decoration: BoxDecoration(
        color: isMaterialBlocked
            ? const Color(0xFFFEF2F2)
            : (missing ? OrderFormColors.fieldFill : OrderFormColors.surface),
        borderRadius: BorderRadius.circular(OrderFormMetrics.cardRadius),
        border: Border.all(
          color: isMaterialBlocked
              ? const Color(0xFFFCA5A5)
              : OrderFormColors.border,
        ),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(OrderFormMetrics.cardRadius),
        onTap: () => _openViewOrder(order),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: DefaultTextStyle.merge(
            style: const TextStyle(fontSize: 12, color: OrderFormColors.muted),
            child: Row(
              children: [
                SizedBox(
                  width: _colDate,
                  child: Text(
                    _formatDate(order.orderDate),
                    style: const TextStyle(
                      fontSize: 12.5,
                      fontWeight: FontWeight.w600,
                      color: OrderFormColors.text,
                    ),
                  ),
                ),
                SizedBox(
                  width: _colTimer,
                  child: OrderDeadlineTimer(order: order, fontSize: 12.5),
                ),
                SizedBox(
                  width: _colCustomer,
                  child: Text(
                    order.customer.isEmpty ? '—' : order.customer,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 12,
                      color: OrderFormColors.text,
                    ),
                  ),
                ),
                SizedBox(
                  width: _colProduct,
                  child: Text(
                    product.type,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                SizedBox(
                  width: _colSize,
                  child: Text(
                    _formatProductSize(product),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                SizedBox(
                  width: _colQty,
                  child: Text(
                    product.quantity.toString(),
                    style: const TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: OrderFormColors.text,
                    ),
                  ),
                ),
                Expanded(
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: statusInfo.label == 'В производстве' &&
                            stageName != null
                        ? Tooltip(
                            message: 'Текущий этап: $stageName',
                            child: statusBadge,
                          )
                        : statusBadge,
                  ),
                ),
                SizedBox(
                  width: _colActions,
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      IconButton(
                        icon: Icon(_editors.containsKey(order.id) ? Icons.lock_outline : Icons.edit_outlined, size: 17),
                        color: OrderFormColors.muted,
                        tooltip: _editors.containsKey(order.id) ? 'Редактирует: ${_editors[order.id]}' : 'Редактировать',
                        visualDensity: VisualDensity.compact,
                        onPressed: _editors.containsKey(order.id) ? null : () {
                          Navigator.push(
                            context,
                            MaterialPageRoute(
                              builder: (_) => EditOrderScreen(order: order),
                            ),
                          );
                        },
                      ),
                      if (canLaunch)
                        _rowActionButton(
                          label: 'Запустить',
                          busy: isLaunching,
                          background: OrderFormColors.accent,
                          onPressed: () => _launchOrder(order),
                        )
                      // Отгрузка была доступна только в карточках: в таблице
                      // завершённый заказ было нечем закрыть.
                      else if (isCompleted && !order.isShipped)
                        _rowActionButton(
                          label: 'Отгрузить',
                          busy: isShipping,
                          background: const Color(0xFFDC2626),
                          onPressed: () => _confirmShipment(order),
                        ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    ));
  }

  Widget _rowActionButton({
    required String label,
    required bool busy,
    required Color background,
    required VoidCallback onPressed,
  }) {
    return FilledButton(
      onPressed: busy ? null : onPressed,
      style: FilledButton.styleFrom(
        visualDensity: VisualDensity.compact,
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        backgroundColor: background,
        foregroundColor: Colors.white,
        textStyle: const TextStyle(fontSize: 11, fontWeight: FontWeight.w600),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(OrderFormMetrics.fieldRadius),
        ),
      ),
      child: busy
          ? const SizedBox(
              width: 14,
              height: 14,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                valueColor: AlwaysStoppedAnimation<Color>(Colors.white),
              ),
            )
          : Text(label),
    );
  }

  /// Строит строку поиска и кнопки сортировки/фильтра.
  Widget _buildSearchAndControls() {
    final filterActive = _filterManagers.isNotEmpty ||
        _filterProducts.isNotEmpty ||
        _filterDateRange != null;
    return Row(
      children: [
        Expanded(
          child: TextField(
            controller: _searchController,
            style: const TextStyle(fontSize: 12),
            decoration: orderFieldDecoration(
              hintText: 'Поиск заказов…',
              prefixIcon: const Icon(Icons.search, size: 18),
            ),
            onChanged: (_) => setState(() {}),
          ),
        ),
        const SizedBox(width: 10),
        OutlinedButton.icon(
          onPressed: () => setState(() => _asTable = !_asTable),
          style: _controlStyle(active: _asTable),
          icon: Icon(_asTable ? Icons.view_module : Icons.view_list, size: 16),
          label: Text(_asTable ? 'Карточки' : 'Таблица'),
        ),
        const SizedBox(width: 10),
        OutlinedButton.icon(
          onPressed: _openFilter,
          style: _controlStyle(active: filterActive),
          icon: const Icon(Icons.filter_list, size: 16),
          label: const Text('Фильтр'),
        ),
        const SizedBox(width: 10),
        OutlinedButton.icon(
          onPressed: _showSortOptions,
          style: _controlStyle(active: false),
          icon: const Icon(Icons.sort, size: 16),
          label: const Text('Сортировка'),
        ),
      ],
    );
  }

  /// Кнопки-управления в шапке: ровно та же высота и радиус, что у поиска.
  static ButtonStyle _controlStyle({required bool active}) =>
      OutlinedButton.styleFrom(
        minimumSize: const Size(0, 38),
        padding: const EdgeInsets.symmetric(horizontal: 12),
        foregroundColor:
            active ? OrderFormColors.accent : OrderFormColors.muted,
        backgroundColor:
            active ? OrderFormColors.accentSoft : OrderFormColors.fieldFill,
        textStyle: const TextStyle(fontSize: 12, fontWeight: FontWeight.w500),
        side: BorderSide(
          color: active ? OrderFormColors.accentBorder : OrderFormColors.border,
        ),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(OrderFormMetrics.fieldRadius),
        ),
      );

  /// Строит сегменты для выбора статуса заказа.
  Widget _buildStatusTabs() {
    const tabs = [
      {'key': 'all', 'label': 'Все заказы'},
      {'key': 'draft', 'label': 'Черновики'},
      {'key': 'waiting_materials', 'label': 'Ожидание материалов'},
      {'key': 'ready_to_start', 'label': 'Готовы к запуску'},
      {'key': 'in_production', 'label': 'В производстве'},
      {'key': 'completed', 'label': 'Завершенные'},
      // «Отмеченные» — заказы, которым цех назначил свой срок завершения. В
      // списке они видны белыми цифрами в цветной плашке; вкладка отвечает на
      // вопрос «что уже пообещали», ради которого отметку и ставят. Назначить
      // срок отсюда нельзя — это делают в МУПЗ.
      {'key': 'promised', 'label': 'Отмеченные'},
    ];
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        children: tabs.map((tab) {
          final key = tab['key']!;
          final selected = _selectedFilter == key;
          return Padding(
            padding: const EdgeInsets.only(right: 8),
            child: Material(
              color: selected
                  ? OrderFormColors.accentSoft
                  : OrderFormColors.surface,
              borderRadius: BorderRadius.circular(999),
              child: InkWell(
                borderRadius: BorderRadius.circular(999),
                onTap: () => setState(() => _selectedFilter = key),
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 14,
                    vertical: 8,
                  ),
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(999),
                    border: Border.all(
                      color: selected
                          ? OrderFormColors.accentBorder
                          : OrderFormColors.border,
                    ),
                  ),
                  child: Text(
                    tab['label']!,
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight:
                          selected ? FontWeight.w600 : FontWeight.w500,
                      color: selected
                          ? OrderFormColors.accent
                          : OrderFormColors.muted,
                    ),
                  ),
                ),
              ),
            ),
          );
        }).toList(),
      ),
    );
  }

  List<OrderModel> _filteredOrders(List<OrderModel> all) {
    // Filter by search query
    final query = _searchController.text.toLowerCase();
    // Отгруженный заказ уехал к заказчику — в этом модуле его больше нет.
    // Всё, что о нём спрашивают потом (кто, когда и сколько отгрузил, что
    // осталось), живёт в архиве заказов.
    List<OrderModel> filtered = all.where((order) {
      if (order.isShipped) return false;
      // Номер «ЗК-…» ищется наравне с uuid и заказчиком: в поиск вводят
      // именно его — на карточке и в документах виден он, а не id.
      final matchesSearch = query.isEmpty ||
          order.id.toLowerCase().contains(query) ||
          orderDisplayId(order).toLowerCase().contains(query) ||
          order.customer.toLowerCase().contains(query);
      return matchesSearch;
    }).toList();
    // Filter by selected managers
    if (_filterManagers.isNotEmpty) {
      filtered = filtered
          .where((o) => _filterManagers.contains(o.manager.trim()))
          .toList();
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
      case 'draft':
        filtered = filtered
            .where((o) => o.statusEnum == OrderStatus.draft)
            .toList();
        break;
      case 'waiting_materials':
        filtered = filtered
            .where((o) => o.statusEnum == OrderStatus.waiting_materials)
            .toList();
        break;
      case 'ready_to_start':
        filtered = filtered
            .where((o) => o.statusEnum == OrderStatus.ready_to_start)
            .toList();
        break;
      case 'in_production':
        filtered =
            filtered.where((o) => o.statusEnum == OrderStatus.in_production).toList();
        break;
      case 'completed':
        filtered = filtered
            .where((o) => o.statusEnum == OrderStatus.completed)
            .toList();
        break;
      case 'promised':
        filtered = filtered.where(hasManualDeadline).toList();
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
    final blQty = product.blQuantity;
    if (blQty != null && blQty.isNotEmpty) extras.add('');

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

    // Прошлые партии: по ним считается остаток и строится таблица отгрузок.
    final shipments = await context
        .read<OrdersProvider>()
        .fetchOrderShipments(order.id);
    final double alreadyShipped = shippedTotal(shipments);
    final double remaining =
        remainingToShip(actualQty: safeActual, shipments: shipments);

    // Режим по умолчанию: если часть уже уехала, спрашивать «разом» поздно —
    // заказ и так отгружается по частям.
    ShipmentMode shipmentMode =
        shipments.isEmpty ? ShipmentMode.whole : ShipmentMode.partial;
    bool hasDocument = false;

    final bool actualLessThanPlanned = safeActual < plannedQty;
    double maxWriteoffQty =
        shipmentMode == ShipmentMode.whole ? safeActual : remaining;
    final double suggestedWriteoff = math.min(plannedQty, maxWriteoffQty);
    double customQty = suggestedWriteoff;
    ShipmentQuantityMode mode = actualLessThanPlanned
        ? ShipmentQuantityMode.actual
        : ShipmentQuantityMode.tirage;
    final TextEditingController customController =
        TextEditingController(text: _formatQuantity(customQty));
    bool updatingCustomText = false;

    double sliderMax = maxWriteoffQty;
    final bool sliderEnabled = sliderMax > 0;
    if (!sliderEnabled) {
      sliderMax = 1;
    }
    final double? selectedWriteoff = await showDialog<double>(
      context: context,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (context, setDialogState) {
            // Лимит зависит от режима: «разом» опирается на весь факт,
            // «частями» — на неотгруженный остаток.
            maxWriteoffQty =
                shipmentMode == ShipmentMode.whole ? safeActual : remaining;
            sliderMax = maxWriteoffQty > 0 ? maxWriteoffQty : 1;
            final bool customQtyExceedsMax =
                mode == ShipmentQuantityMode.custom &&
                    customQty > maxWriteoffQty;
            final double effectiveCustom = sliderEnabled
                ? math.max(0, math.min(customQty, sliderMax))
                : math.max(0, math.min(customQty, maxWriteoffQty));
            double currentWriteoff;
            switch (mode) {
              case ShipmentQuantityMode.tirage:
                currentWriteoff = math.min(plannedQty, maxWriteoffQty);
                break;
              case ShipmentQuantityMode.actual:
                currentWriteoff = safeActual;
                break;
              case ShipmentQuantityMode.custom:
                currentWriteoff = effectiveCustom;
                break;
            }
            if (currentWriteoff < 0) currentWriteoff = 0;
            if (currentWriteoff > maxWriteoffQty) {
              currentWriteoff = maxWriteoffQty;
            }
            final double base =
                shipmentMode == ShipmentMode.whole ? safeActual : remaining;
            final double leftoverQty =
                base > currentWriteoff ? (base - currentWriteoff) : 0;

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
                    if (alreadyShipped > 0) ...[
                      const SizedBox(height: 4),
                      Text('Уже отгружено: '
                          '${_formatQuantity(alreadyShipped)}'),
                      Text('Осталось: ${_formatQuantity(remaining)}'),
                    ],
                    const SizedBox(height: 12),
                    // Режим решает не количество, а судьбу заказа после
                    // отгрузки: разом — уходит в архив, частями — остаётся
                    // ждать следующую партию.
                    Row(
                      children: [
                        Expanded(
                          child: _ShipmentModeButton(
                            label: 'Отгрузка разом',
                            selected: shipmentMode == ShipmentMode.whole,
                            // Часть тиража уже уехала — «разом» больше не про
                            // этот заказ, и выбор был бы обманом.
                            onTap: shipments.isEmpty
                                ? () => setDialogState(
                                    () => shipmentMode = ShipmentMode.whole)
                                : null,
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: _ShipmentModeButton(
                            label: 'Частями',
                            selected: shipmentMode == ShipmentMode.partial,
                            onTap: () => setDialogState(
                                () => shipmentMode = ShipmentMode.partial),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 4),
                    Text(
                      shipmentMode == ShipmentMode.whole
                          ? 'Заказ уйдёт в архив.'
                          : 'Заказ останется в «Завершённых», пока не '
                              'отгрузят всё фактическое количество.',
                      style: const TextStyle(
                          fontSize: 12, color: Colors.black54),
                    ),
                    const SizedBox(height: 12),
                    RadioListTile<ShipmentQuantityMode>(
                      title: Text(
                          'Списать тираж (${_formatQuantity(plannedQty)})'),
                      subtitle: plannedQty > maxWriteoffQty
                          ? Text(
                              'Недоступно: факт ${_formatQuantity(maxWriteoffQty)} меньше тиража',
                            )
                          : null,
                      value: ShipmentQuantityMode.tirage,
                      groupValue: mode,
                      onChanged: plannedQty > maxWriteoffQty
                          ? null
                          : (value) {
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
                        decoration: InputDecoration(
                          labelText: 'Количество к списанию',
                          helperText:
                              'Не больше факта: ${_formatQuantity(maxWriteoffQty)}',
                          errorText: customQtyExceedsMax
                              ? 'Количество не должно быть больше факта'
                              : null,
                          border: const OutlineInputBorder(),
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
                    CheckboxListTile(
                      value: hasDocument,
                      onChanged: (value) => setDialogState(
                          () => hasDocument = value == true),
                      contentPadding: EdgeInsets.zero,
                      dense: true,
                      controlAffinity: ListTileControlAffinity.leading,
                      title: const Text('Есть документ'),
                    ),
                    Text('К списанию: ${_formatQuantity(currentWriteoff)}'),
                    Text(
                      'Остаток после отгрузки: ${_formatQuantity(leftoverQty)}',
                    ),
                    if (shipments.isNotEmpty) ...[
                      const SizedBox(height: 12),
                      const Text(
                        'Отгрузки по заказу',
                        style: TextStyle(fontWeight: FontWeight.w600),
                      ),
                      const SizedBox(height: 4),
                      OrderShipmentsTable(
                        shipments: shipments,
                        // Галочка документа сохраняется явной кнопкой, а не
                        // касанием: каждое переключение пишется в историю
                        // заказа с автором и временем.
                        onToggleDocument: (shipment, value) async {
                          final messenger = ScaffoldMessenger.of(context);
                          try {
                            await context
                                .read<OrdersProvider>()
                                .setShipmentDocument(
                                  orderId: order.id,
                                  shipment: shipment,
                                  hasDocument: value,
                                );
                            final idx = shipments
                                .indexWhere((s) => s.id == shipment.id);
                            if (idx != -1) {
                              setDialogState(() {
                                shipments[idx] =
                                    shipment.copyWith(hasDocument: value);
                              });
                            }
                          } catch (e) {
                            messenger.showSnackBar(SnackBar(
                              content: Text('Не удалось сохранить документ: $e'),
                            ));
                          }
                        },
                      ),
                    ],
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(ctx, null),
                  child: const Text('Отмена'),
                ),
                ElevatedButton(
                  onPressed: currentWriteoff <= 0 ||
                          currentWriteoff > maxWriteoffQty ||
                          customQtyExceedsMax
                      ? null
                      : () => Navigator.pop(ctx, currentWriteoff),
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
      await context.read<OrdersProvider>().shipOrder(
            order,
            writeoffOverride: selectedWriteoff,
            mode: shipmentMode,
            hasDocument: hasDocument,
          );
      if (!mounted) return;
      final bool closed = shipmentClosesOrder(
        mode: shipmentMode,
        actualQty: safeActual,
        shipments: shipments,
        qty: selectedWriteoff,
      );
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(closed
              ? 'Заказ отправлен в архив'
              : 'Партия отгружена, заказ ждёт следующую'),
        ),
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
    // Уникальные менеджеры и типы изделий из списка заказов. Пустой менеджер
    // в чипы не выносим: выбрать «никого» смысла нет.
    final managers = provider.orders
        .map((o) => o.manager.trim())
        .where((name) => name.isNotEmpty)
        .toSet()
        .toList()
      ..sort();
    final products = provider.orders.map((o) => o.product.type).toSet().toList()
      ..sort();
    // Локальные копии фильтра на время редактирования
    final selectedManagers = List<String>.from(_filterManagers);
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
                    const Text('Менеджеры',
                        style: TextStyle(fontWeight: FontWeight.w600)),
                    Wrap(
                      spacing: 6,
                      children: managers
                          .map(
                            (m) => FilterChip(
                              label: Text(m),
                              selected: selectedManagers.contains(m),
                              onSelected: (sel) {
                                setModalState(() {
                                  if (sel) {
                                    selectedManagers.add(m);
                                  } else {
                                    selectedManagers.remove(m);
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
                          _filterManagers = List<String>.from(selectedManagers);
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
                          _filterManagers.clear();
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
    showDialog(
      context: context,
      barrierDismissible: true,
      builder: (_) => ViewOrderDialog(order: order),
    );
  }

  bool _canLaunchOrder(OrderModel order, WarehouseProvider warehouse) {
    return canLaunchOrder(order, warehouse.allTmc);
  }

  Future<void> _launchOrder(OrderModel order) async {
    if (_launchingInProgress.contains(order.id)) return;
    setState(() => _launchingInProgress.add(order.id));
    final messenger = ScaffoldMessenger.of(context);
    try {
      final provider = context.read<OrdersProvider>();
      final error = await provider.launchOrder(order);
      if (!mounted) return;
      if (error != null) {
        messenger.showSnackBar(SnackBar(content: Text(error)));
      } else {
        messenger.showSnackBar(
          const SnackBar(content: Text('Заказ запущен в производство')),
        );
      }
    } finally {
      if (mounted) {
        setState(() => _launchingInProgress.remove(order.id));
      }
    }
  }

  /// Возвращает цвет и текст статуса для заказа с учётом связанных задач.
  _OrderStatusInfo _computeStatus(OrderModel order, List<TaskModel> allTasks) {
    final tasks = allTasks.where((t) => t.orderId == order.id).toList();
    if (tasks.isNotEmpty) {
      if (isOrderFinallyCompleted(tasks)) {
        return const _OrderStatusInfo(Colors.green, 'Завершено');
      }
      if (tasks.any((t) => t.status == TaskStatus.inProgress)) {
        return const _OrderStatusInfo(Colors.orange, 'В производстве');
      }
      return const _OrderStatusInfo(Colors.blue, 'Ожидание запуска');
    }
    switch (order.statusEnum) {
      case OrderStatus.in_production:
        return const _OrderStatusInfo(Colors.orange, 'В производстве');
      case OrderStatus.completed:
        return const _OrderStatusInfo(Colors.green, 'Завершено');
      case OrderStatus.waiting_materials:
        return const _OrderStatusInfo(Colors.red, 'Ожидание материалов');
      case OrderStatus.ready_to_start:
        return const _OrderStatusInfo(Colors.blueGrey, 'Готов к запуску');
      case OrderStatus.draft:
      default:
        return const _OrderStatusInfo(Colors.blue, 'Черновик');
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
  /// Размер карточки заказа. Фиксированный, и это главное.
  ///
  /// Карточки лежат во Wrap, где каждая занимала свою натуральную высоту:
  /// заказ с причиной нехватки материала вырастал на три строки, завершённый —
  /// на строку «Факт», а длинный номер уводил бейдж статуса на второй ряд.
  /// Ряды получались рваными, между карточками зияли дыры.
  ///
  /// Высота выбрана по худшему случаю — нехватка материала с двумя строками
  /// причины даёт ~186 px вместе с рамкой и отступами. Запас в два десятка
  /// пикселей оставлен под системный масштаб шрифта; лишнее место забирает
  /// распорка перед кнопками, поэтому кнопки у всех карточек на одной линии.
  static const double _orderCardWidth = 240;
  static const double _orderCardHeight = 210;

  /// Палитра «краски нет на складе». Фиолетовый отделяет случай «нужно
  /// завести карточку» от красного «нужно докупить»: действия у них разные,
  /// и путать их в списке из полусотни заказов нельзя.
  static const Color _kMissingPaintFill = Color(0xFFF5F3FF);
  static const Color _kMissingPaintBorder = Color(0xFFC4B5FD);
  static const Color _kMissingPaintText = Color(0xFF7C3AED);

  /// Палитра «краска не выбрана». Серый отделяет заказ, которому нужна не
  /// поставка, а решение менеджера: докупать нечего, пока краска не названа.
  /// Красный здесь звал бы снабженца впустую.
  static const Color _kNoPaintFill = Color(0xFFF3F4F6);
  static const Color _kNoPaintBorder = Color(0xFFD1D5DB);
  static const Color _kNoPaintText = Color(0xFF6B7280);

  /// Открывает склад с готовой формой создания краски.
  Future<void> _openPaintCreation(String paintName) async {
    await showDialog<void>(
      context: context,
      builder: (_) => AddEntryDialog(
        initialTable: 'Краска',
        initialName: paintName,
      ),
    );
    if (!mounted) return;
    // Склад изменился — пересчитываем обеспеченность заказов, чтобы
    // фиолетовая карточка сама ушла в «Готов к запуску».
    final warehouse = context.read<WarehouseProvider>();
    await warehouse.fetchTmc();
    if (!mounted) return;
    await context.read<OrdersProvider>().recheckMaterialAvailability();
  }

  Widget _buildOrderCard(OrderModel order, List<TaskModel> allTasks,
      PersonnelProvider personnel, WarehouseProvider warehouse) {
    // Определяем цвет и текст для статуса с учётом задач
    final statusInfo = _computeStatus(order, allTasks);
    final Color statusColor = statusInfo.color;
    final String statusLabel = statusInfo.label;
    final product = order.product;
    final totalQty = product.quantity;
    final productSize = _formatProductSize(product);
    final missing = _isIncomplete(order);
    final bool isCompleted = statusLabel == 'Завершено';
    final bool isMaterialBlocked =
        order.statusEnum == OrderStatus.waiting_materials;
    // Краски нет на складе вовсе — это не «докупить», а «завести карточку».
    // Случай отличается и цветом (фиолетовый вместо красного), и действием:
    // на карточке появляется кнопка, открывающая склад с готовой формой.
    final List<String> missingPaints =
        missingPaintNamesFromShortage(order.materialShortageMessage);
    final bool isPaintMissing = isMaterialBlocked && missingPaints.isNotEmpty;
    // Краски в заказе нет вовсе — правило paintSelectionMissing. Случай
    // взаимоисключающий с фиолетовым: там краска названа, но её нет на складе.
    final bool isPaintNotSelected = isMaterialBlocked &&
        isPaintNotSelectedShortage(order.materialShortageMessage);
    final bool isShipping = _shippingInProgress.contains(order.id);
    final bool canLaunch = _canLaunchOrder(order, warehouse);
    final bool isLaunching = _launchingInProgress.contains(order.id);
    final String? stageName =
        _currentStageName(order, allTasks, personnel);
    return OrderEditingFrame(
      editorName: _editors[order.id],
      child: SizedBox(
      width: _orderCardWidth,
      height: _orderCardHeight,
      child: Container(
        // Переполнение обрезаем, а не отдаём «полосатой» подложке: карточка с
        // непредвиденно длинным текстом должна остаться карточкой.
        clipBehavior: Clip.antiAlias,
        decoration: BoxDecoration(
          color: isPaintNotSelected
              ? _kNoPaintFill
              : (isPaintMissing
                  ? _kMissingPaintFill
                  : (isMaterialBlocked
                      ? const Color(0xFFFEF2F2)
                      : (missing
                          ? OrderFormColors.fieldFill
                          : OrderFormColors.surface))),
          borderRadius: BorderRadius.circular(OrderFormMetrics.cardRadius),
          border: Border.all(
            color: isPaintNotSelected
                ? _kNoPaintBorder
                : (isPaintMissing
                    ? _kMissingPaintBorder
                    : (isMaterialBlocked
                        ? const Color(0xFFFCA5A5)
                        : OrderFormColors.border)),
          ),
        ),
        child: InkWell(
          borderRadius: BorderRadius.circular(OrderFormMetrics.cardRadius),
          onTap: () => _openViewOrder(order),
          child: Padding(
            padding: const EdgeInsets.all(10),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // Заказчик
                Text(
                  order.customer.isEmpty ? '—' : order.customer,
                  style: const TextStyle(
                    fontWeight: FontWeight.w700,
                    fontSize: 14,
                    color: OrderFormColors.text,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 4),
                // Номер и статус заказа — всегда одной строкой.
                //
                // Раньше здесь стоял Wrap, и при длинном номере бейдж уезжал
                // на второй ряд: соседние карточки в ряду отличались по высоте
                // на два десятка пикселей. Теперь номер сжимается многоточием,
                // а бейдж остаётся на месте.
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        _formatDate(order.orderDate),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontWeight: FontWeight.w500,
                          fontSize: 11,
                          color: OrderFormColors.muted,
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    statusLabel == 'В производстве' && stageName != null
                        ? Tooltip(
                            message: 'Текущий этап: $stageName',
                            child: _StatusBadge(
                                color: statusColor, label: statusLabel),
                          )
                        : _StatusBadge(color: statusColor, label: statusLabel),
                  ],
                ),
                const SizedBox(height: 2),
                // Срок под датой, тем же кеглем: две отметки одного порядка —
                // когда заказ приняли и сколько до сдачи осталось.
                OrderDeadlineTimer(order: order, fontSize: 11),
                if (isMaterialBlocked &&
                    order.materialShortageMessage.trim().isNotEmpty) ...[
                  const SizedBox(height: 4),
                  // Причина не помещается в карточку и обрезается, а знать
                  // её нужно целиком: сколько занято и какими заказами.
                  // Наведение (или долгое нажатие на планшете) показывает
                  // текст полностью.
                  Flexible(
                    child: Tooltip(
                      message: order.materialShortageMessage,
                      waitDuration: const Duration(milliseconds: 300),
                      // Перечнем, а не сплошным текстом: раньше карточка
                      // показывала одну позицию из пяти — строка обрезалась на
                      // первой, — и сотрудник шёл на склад за неполным
                      // списком. Подробности (сколько доступно, из чего
                      // сложилось) остаются в подсказке по наведению.
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          for (final line in parseShortageLines(
                            order.materialShortageMessage,
                          ))
                            Text(
                              line.text,
                              style: TextStyle(
                                fontSize: 10,
                                height: 1.25,
                                color: isPaintNotSelected
                                    ? _kNoPaintText
                                    : (isPaintMissing
                                        ? _kMissingPaintText
                                        : Colors.red),
                              ),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                        ],
                      ),
                    ),
                  ),
                ],
                if (isPaintMissing) ...[
                  const SizedBox(height: 4),
                  SizedBox(
                    height: 26,
                    child: OutlinedButton.icon(
                      onPressed: () => _openPaintCreation(missingPaints.first),
                      icon: const Icon(Icons.add, size: 14),
                      label: Text(
                        missingPaints.length == 1
                            ? 'Завести краску'
                            : 'Завести краски (${missingPaints.length})',
                        style: const TextStyle(fontSize: 10),
                      ),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: _kMissingPaintText,
                        side: const BorderSide(color: _kMissingPaintBorder),
                        padding: const EdgeInsets.symmetric(horizontal: 8),
                        visualDensity: VisualDensity.compact,
                        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      ),
                    ),
                  ),
                ],
                const SizedBox(height: 6),
                // Информация о продукте. Строго по одной строке на поле:
                // перенос длинного названия изделия сдвигал бы кнопки вниз и
                // ломал ровный ряд карточек.
                Text('Изделие: ${product.type}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                        fontSize: 11, fontWeight: FontWeight.w600)),
                const SizedBox(height: 2),
                Text('Размер: $productSize',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 11)),
                const SizedBox(height: 2),
                Text('Тираж: $totalQty шт.',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                        fontSize: 11, fontWeight: FontWeight.w600)),
                if (isCompleted)
                  Padding(
                    padding: const EdgeInsets.only(top: 4.0),
                    child: Text(
                      'Факт: ${order.actualQty != null ? _formatQuantity(order.actualQty!) : '—'} шт.',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                // Распорка забирает разницу высот: кнопки прижаты к низу и
                // стоят на одной линии во всех карточках ряда.
                const Spacer(),
                // Кнопки действий. «Часов» здесь больше нет: историю заказа
                // показывает сама карточка деталей, открытая по нажатию.
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    IconButton(
                      onPressed: _editors.containsKey(order.id) ? null : () {
                        Navigator.push(
                          context,
                          MaterialPageRoute(
                              builder: (_) => EditOrderScreen(order: order)),
                        );
                      },
                      icon: Icon(_editors.containsKey(order.id) ? Icons.lock_outline : Icons.edit_outlined, size: 17),
                      color: OrderFormColors.muted,
                      visualDensity: VisualDensity.compact,
                      tooltip: _editors.containsKey(order.id) ? 'Редактирует: ${_editors[order.id]}' : 'Редактировать',
                    ),
                    if (canLaunch)
                      _rowActionButton(
                        label: 'Запустить',
                        busy: isLaunching,
                        background: OrderFormColors.accent,
                        onPressed: () => _launchOrder(order),
                      )
                    else if (isCompleted && !order.isShipped)
                      _rowActionButton(
                        label: 'Отгрузить',
                        busy: isShipping,
                        background: const Color(0xFFDC2626),
                        onPressed: () => _confirmShipment(order),
                      ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    ));
  }

  String _formatDate(DateTime? date) {
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

/// Кнопка выбора режима отгрузки.
///
/// Не SegmentedButton: недоступный вариант в нём выглядит как выбранный
/// сосед, а «разом» для заказа с уже уехавшей партией обязан читаться именно
/// как запрещённый.
class _ShipmentModeButton extends StatelessWidget {
  const _ShipmentModeButton({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final enabled = onTap != null;
    final color = selected ? const Color(0xFF6A6CF7) : Colors.black54;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(10),
      child: Opacity(
        opacity: enabled ? 1 : 0.45,
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 10),
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: selected ? const Color(0xFFEDE9FE) : Colors.transparent,
            border: Border.all(
              color: selected ? const Color(0xFFA5B4FC) : Colors.black12,
            ),
            borderRadius: BorderRadius.circular(10),
          ),
          child: Text(
            label,
            style: TextStyle(
              fontSize: 13,
              fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
              color: color,
            ),
          ),
        ),
      ),
    );
  }
}
