// lib/modules/orders/orders_provider.dart
import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'material_model.dart';
import 'order_model.dart';
import 'product_model.dart';
import '../../utils/auth_helper.dart';

class OrdersProvider with ChangeNotifier {
  final SupabaseClient _supabase = Supabase.instance.client;

  final List<OrderModel> _orders = [];
  List<OrderModel> get orders => List.unmodifiable(_orders);

  // Realtime channel for listening to order changes.
  RealtimeChannel? _ordersChannel;
  final List<RealtimeChannel> _stockChannels = <RealtimeChannel>[];
  Timer? _stockRecheckDebounce;
  bool _stockRecheckInProgress = false;

  OrdersProvider() {
    _listenToOrders();
    _listenToStockChanges();
  }

  // ===== AUTH =====
  Future<void> _ensureAuthed() async {
    final auth = _supabase.auth;
    if (auth.currentUser == null) {
      try {
        // Supabase supports anonymous sign-in if enabled in your project.
        await auth.signInAnonymously();
      } catch (_) {
        // Если анонимная аутентификация выключена — просто продолжаем.
        // Для чтения у вас должна быть RLS-политика на anon.
      }
    }
  }

  // ===== DATA LOAD =====
  Future<void> refresh() async {
    try {
      await _ensureAuthed();
      final res = await _supabase
          .from('orders')
          .select()
          .order('created_at', ascending: false);

      final rows = (res as List).cast<Map<String, dynamic>>();
      _orders
        ..clear()
        ..addAll(rows.map((row) => OrderModel.fromMap(row)));
      notifyListeners();
    } catch (e, st) {
      debugPrint('❌ refresh orders error: $e\n$st');
    }
  }

  void _listenToStockChanges() {
    void scheduleStockRecheck() {
      _stockRecheckDebounce?.cancel();
      _stockRecheckDebounce = Timer(const Duration(milliseconds: 400), () async {
        await recheckMaterialAvailability(forceRefresh: true);
      });
    }

    void addStockChannel({
      required String channelName,
      required String table,
    }) {
      final channel = _supabase
          .channel(channelName)
          .onPostgresChanges(
            event: PostgresChangeEvent.all,
            schema: 'public',
            table: table,
            callback: (_) => scheduleStockRecheck(),
          )
          .subscribe();
      _stockChannels.add(channel);
    }

    // В разных проектах остатки могут меняться как напрямую в таблицах
    // номенклатуры, так и через журналы приходов/списаний/инвентаризаций.
    // Подписываемся на все связанные таблицы, чтобы не пропускать автозапуск.
    addStockChannel(
      channelName: 'orders:stock-recheck:materials',
      table: 'materials',
    );
    addStockChannel(
      channelName: 'orders:stock-recheck:papers',
      table: 'papers',
    );
    addStockChannel(
      channelName: 'orders:stock-recheck:materials-arrivals',
      table: 'materials_arrivals',
    );
    addStockChannel(
      channelName: 'orders:stock-recheck:materials-writeoffs',
      table: 'materials_writeoffs',
    );
    addStockChannel(
      channelName: 'orders:stock-recheck:materials-inventories',
      table: 'materials_inventories',
    );
    addStockChannel(
      channelName: 'orders:stock-recheck:papers-arrivals',
      table: 'papers_arrivals',
    );
    addStockChannel(
      channelName: 'orders:stock-recheck:papers-writeoffs',
      table: 'papers_writeoffs',
    );
    addStockChannel(
      channelName: 'orders:stock-recheck:papers-inventories',
      table: 'papers_inventories',
    );
  }

  Future<void> recheckMaterialAvailability({bool forceRefresh = false}) async {
    if (_stockRecheckInProgress) return;
    _stockRecheckInProgress = true;
    try {
      await _ensureAuthed();

      if (forceRefresh) {
        final res = await _supabase
            .from('orders')
            .select()
            .order('created_at', ascending: false);
        final rows = (res as List).cast<Map<String, dynamic>>();
        _orders
          ..clear()
          ..addAll(rows.map((row) => OrderModel.fromMap(row)));
        notifyListeners();
      }

      final pending = _orders.where((order) {
        if (order.assignmentCreated) return false;
        return order.statusEnum == OrderStatus.waiting_materials ||
            order.statusEnum == OrderStatus.ready_to_start;
      }).toList(growable: false);

      for (final order in pending) {
        final hasEnough = await _hasEnoughMaterialForLaunch(order);
        final nextStatus = hasEnough
            ? OrderStatus.ready_to_start
            : OrderStatus.waiting_materials;
        if (order.statusEnum == nextStatus &&
            order.hasMaterialShortage == !hasEnough) {
          continue;
        }
        final shortageMessage =
            hasEnough ? '' : await _materialShortageMessage(order);
        await _supabase.from('orders').update({
          'status': nextStatus.name,
          'has_material_shortage': !hasEnough,
          'material_shortage_message': shortageMessage,
        }).eq('id', order.id);
      }
      await refresh();
    } catch (e, st) {
      debugPrint('⚠️ material recheck failed: $e\n$st');
    } finally {
      _stockRecheckInProgress = false;
    }
  }

  Future<String> _materialShortageMessage(OrderModel order) async {
    final requiredLength = (order.product.length ?? 0).toDouble();
    if (requiredLength <= 0) return 'Недостаточно материала на складе.';
    final available = await _fetchMaterialQty(order.material?.id);
    if (available == null) return 'Материал не найден на складе.';
    final shortage = requiredLength - available;
    if (shortage <= 0) return '';
    return 'Недостаточно материала: требуется ${requiredLength.toStringAsFixed(2)}, '
        'доступно ${available.toStringAsFixed(2)} (не хватает ${shortage.toStringAsFixed(2)}).';
  }

  Future<double?> _fetchMaterialQty(String? materialId) async {
    final id = (materialId ?? '').trim();
    if (id.isEmpty) return null;
    Future<double?> fetchQty(String table) async {
      try {
        final row =
            await _supabase.from(table).select('quantity').eq('id', id).maybeSingle();
        if (row == null) return null;
        final value = row['quantity'];
        if (value is num) return value.toDouble();
        return double.tryParse('$value');
      } catch (_) {
        return null;
      }
    }

    return await fetchQty('materials') ?? await fetchQty('papers');
  }

  Future<bool> _hasEnoughMaterialForLaunch(OrderModel order) async {
    final String materialId = (order.material?.id ?? '').trim();
    final double requiredLength = (order.product.length ?? 0).toDouble();
    if (materialId.isEmpty || requiredLength <= 0) {
      return true;
    }

    final qty = await _fetchMaterialQty(materialId);
    if (qty == null) {
      // Если номенклатура не найдена (например, удалена) — не автозапускаем.
      return false;
    }
    return qty >= requiredLength;
  }

  // ===== REALTIME =====
  void _listenToOrders() {
    // Remove previous channel if any
    if (_ordersChannel != null) {
      _supabase.removeChannel(_ordersChannel!);
      _ordersChannel = null;
    }

    // Initial fetch
    refresh();

    // Subscribe to realtime changes in the dedicated 'orders' table
    _ordersChannel = _supabase
        .channel('orders_changes')
        .onPostgresChanges(
          event: PostgresChangeEvent.insert,
          schema: 'public',
          table: 'orders',
          callback: (payload) async => refresh(),
        )
        .onPostgresChanges(
          event: PostgresChangeEvent.update,
          schema: 'public',
          table: 'orders',
          callback: (payload) async {
            await _handleOrderUpdatePayload(payload);
          },
        )
        .onPostgresChanges(
          event: PostgresChangeEvent.delete,
          schema: 'public',
          table: 'orders',
          callback: (payload) async => refresh(),
        )
        .subscribe();
  }

  Future<void> _handleOrderUpdatePayload(PostgresChangePayload payload) async {
    Map<String, dynamic>? _castRecord(dynamic record) {
      if (record == null) return null;
      if (record is Map<String, dynamic>) {
        return Map<String, dynamic>.from(record);
      }
      if (record is Map) {
        return Map<String, dynamic>.from(record as Map);
      }
      return null;
    }

    try {
      final Map<String, dynamic>? newRecord = _castRecord(payload.newRecord);
      final Map<String, dynamic>? oldRecord = _castRecord(payload.oldRecord);
      if (newRecord != null) {
        final updated = OrderModel.fromMap(newRecord);
        if (oldRecord != null) {
          final previous = OrderModel.fromMap(oldRecord);
          await _handleActualQtyChange(previous: previous, updated: updated);
          await _handleOrderStatusChange(previous: previous, updated: updated);
        }

        final index = _orders.indexWhere((o) => o.id == updated.id);
        if (index != -1) {
          _orders[index] = updated;
        } else {
          _orders.add(updated);
        }
        notifyListeners();
        return;
      }
    } catch (e, st) {
      debugPrint('❌ orders update payload error: $e\n$st');
    }

    await refresh();
  }

  @override
  void dispose() {
    if (_ordersChannel != null) {
      _supabase.removeChannel(_ordersChannel!);
      _ordersChannel = null;
    }
    for (final channel in _stockChannels) {
      _supabase.removeChannel(channel);
    }
    _stockChannels.clear();
    _stockRecheckDebounce?.cancel();
    super.dispose();
  }

  // ===== CRUD =====

  /// Добавляет готовый заказ (оптимистично) и пишет в таблицу `orders`.
  Future<void> addOrder(OrderModel order) async {
    await _ensureAuthed();

    // Optimistic insert
    _orders.add(order);
    notifyListeners();

    try {
      final inserted = await _supabase
          .from('orders')
          .insert(order.toMap())
          .select()
          .single() as Map<String, dynamic>;

      final newOrder = OrderModel.fromMap(inserted);
      final idx = _orders.indexWhere((o) => o.id == order.id);
      if (idx != -1) {
        _orders[idx] = newOrder;
      } else {
        _orders.add(newOrder);
      }
      notifyListeners();

      // Log creation (best effort)
      await _logOrderEvent(newOrder.id, 'Создание', 'Создан заказ');
    } catch (e, st) {
      // Rollback optimistic change
      _orders.removeWhere((o) => o.id == order.id);
      notifyListeners();
      debugPrint('❌ addOrder error: $e\n$st');
    }
  }

  /// Создаёт заказ — id возвращает БД. Возвращает созданную модель или null при ошибке.
  Future<OrderModel?> createOrder({
    String manager = '',
    required String customer,
    required DateTime orderDate,
    DateTime? dueDate,
    required ProductModel product,
    List<String> additionalParams = const [],
    String handle = '-',
    String cardboard = 'нет',
    MaterialModel? material,
    double makeready = 0,
    double val = 0,
    String? pdfUrl,
    String? stageTemplateId,
    bool hasForm = false,
    bool contractSigned = false,
    bool paymentDone = false,
    String comments = '',
    String status = 'draft',
    String? assignmentId,
    bool assignmentCreated = false,
  }) async {
    await _ensureAuthed();

    // Local temp id for optimistic UI
    final tempLocalId = 'local-${DateTime.now().microsecondsSinceEpoch}';
    final localOrder = OrderModel(
      id: tempLocalId,
      manager: manager,
      customer: customer,
      orderDate: orderDate,
      dueDate: dueDate,
      product: product,
      additionalParams: additionalParams,
      handle: handle,
      cardboard: cardboard,
      material: material,
      makeready: makeready,
      val: val,
      pdfUrl: pdfUrl,
      stageTemplateId: stageTemplateId,
      hasForm: hasForm,
      contractSigned: contractSigned,
      paymentDone: paymentDone,
      comments: comments,
      status: status,
      assignmentId: assignmentId,
      assignmentCreated: assignmentCreated,
    );

    // Optimistic add
    _orders.add(localOrder);
    notifyListeners();

    try {
      final inserted = await _supabase
          .from('orders')
          .insert(localOrder.toMap()..remove('id')) // let DB generate id
          .select()
          .single() as Map<String, dynamic>;

      final created = OrderModel.fromMap(inserted);

      // Replace optimistic row
      final idx = _orders.indexWhere((o) => o.id == tempLocalId);
      if (idx != -1) _orders[idx] = created;
      notifyListeners();

      // Log creation (best effort)
      await _logOrderEvent(created.id, 'Создание', 'Создан заказ');
      return created;
    } catch (e, st) {
      // Rollback
      _orders.removeWhere((o) => o.id == tempLocalId);
      notifyListeners();
      debugPrint('❌ createOrder error: $e\n$st');
      return null;
    }
  }

  /// Обновляет существующий заказ по ID (оптимистично).
  Future<void> updateOrder(OrderModel updated) async {
    await _ensureAuthed();

    final index = _orders.indexWhere((o) => o.id == updated.id);
    if (index == -1) return;

    final prev = _orders[index];
    _orders[index] = updated; // optimistic
    notifyListeners();

    try {
      await _supabase
          .from('orders')
          .update(updated.toMap()..remove('id'))
          .eq('id', updated.id);

      await _logOrderEvent(updated.id, 'Обновление', 'Изменён заказ');
    } catch (e, st) {
      _orders[index] = prev; // rollback
      notifyListeners();
      debugPrint('❌ updateOrder error: $e\n$st');
    }
  }

  /// Запускает заказ в производство:
  /// - создаёт задачи по сохранённой очереди этапов;
  /// - переводит заказ в статус inWork.
  /// Возвращает `null` при успехе или текст ошибки.
  Future<String?> launchOrder(OrderModel order) async {
    await _ensureAuthed();
    if (order.assignmentCreated) {
      return null;
    }
    if (order.statusEnum != OrderStatus.ready_to_start) {
      return 'Заказ нельзя запустить: статус должен быть ready_to_start.';
    }
    if (!await _hasEnoughMaterialForLaunch(order)) {
      final message = await _materialShortageMessage(order);
      await _supabase.from('orders').update({
        'status': OrderStatus.waiting_materials.name,
        'has_material_shortage': true,
        'material_shortage_message': message,
      }).eq('id', order.id);
      await refresh();
      return message.isEmpty
          ? 'Недостаточно материала для запуска заказа.'
          : message;
    }

    try {
      final List<Map<String, dynamic>> stageRows = <Map<String, dynamic>>[];

      try {
        final plan = await _supabase
            .from('prod_plans')
            .select('id')
            .eq('order_id', order.id)
            .maybeSingle();
        final String? planId = plan?['id']?.toString();
        if (planId != null && planId.isNotEmpty) {
          final rows = await _supabase
              .from('prod_plan_stages')
              .select('stage_id, status, step, step_no, seq')
              .eq('plan_id', planId)
              .order('step', ascending: true);
          if (rows is List) {
            stageRows.addAll(rows
                .whereType<Map>()
                .map((r) => Map<String, dynamic>.from(r as Map)));
          }
        }
      } catch (_) {}

      if (stageRows.isEmpty) {
        try {
          final legacyPlan = await _supabase
              .from('production_plans')
              .select('stages')
              .eq('order_id', order.id)
              .maybeSingle();
          final dynamic stages = legacyPlan?['stages'];
          if (stages is List) {
            for (final raw in stages.whereType<Map>()) {
              final map = Map<String, dynamic>.from(raw as Map);
              final stageId = (map['stageId'] ??
                      map['stage_id'] ??
                      map['stageid'] ??
                      map['workplaceId'] ??
                      map['workplace_id'] ??
                      map['id'])
                  ?.toString();
              if (stageId == null || stageId.trim().isEmpty) continue;
              stageRows.add({
                'stage_id': stageId.trim(),
                'status': 'waiting',
              });
            }
          }
        } catch (_) {}
      }

      if (stageRows.isEmpty) {
        return 'Не удалось запустить заказ: не найдена очередь этапов.';
      }

      await _supabase.from('tasks').delete().eq('order_id', order.id);

      final Set<String> createdStageIds = <String>{};
      for (final row in stageRows) {
        final String stageId = (row['stage_id'] ?? '').toString().trim();
        if (stageId.isEmpty || createdStageIds.contains(stageId)) continue;
        createdStageIds.add(stageId);
        final String stageStatus = (row['status'] ?? '').toString().toLowerCase();
        final String taskStatus =
            (stageStatus == 'done' || stageStatus == 'completed')
                ? 'done'
                : 'waiting';
        await _supabase.from('tasks').insert({
          'order_id': order.id,
          'stage_id': stageId,
          'status': taskStatus,
          'assignees': [],
          'comments': [],
          if (taskStatus == 'done')
            'completed_at': DateTime.now().toIso8601String(),
        });
      }


      final String nextAssignmentId =
          (order.assignmentId ?? '').trim().isNotEmpty
              ? order.assignmentId!.trim()
              : generateAssignmentId();

      await _supabase.from('orders').update({
        'status': OrderStatus.in_production.name,
        'has_material_shortage': false,
        'material_shortage_message': '',
        'assignment_created': true,
        'assignment_id': nextAssignmentId,
      }).eq('id', order.id);

      final index = _orders.indexWhere((o) => o.id == order.id);
      if (index != -1) {
        _orders[index] = _orders[index].copyWith(
          status: OrderStatus.in_production.name,
          hasMaterialShortage: false,
          materialShortageMessage: '',
          assignmentCreated: true,
          assignmentId: nextAssignmentId,
        );
        notifyListeners();
      }

      await _logOrderEvent(order.id, 'Запуск', 'Заказ запущен в производство');
      return null;
    } catch (e, st) {
      debugPrint('❌ launchOrder error: $e\n$st');
      return 'Не удалось запустить заказ: $e';
    }
  }

  /// Удаляет заказ по идентификатору (оптимистично).
  Future<void> deleteOrder(String id) async {
    await _ensureAuthed();

    final index = _orders.indexWhere((o) => o.id == id);
    if (index == -1) return;

    final removed = _orders.removeAt(index);
    notifyListeners();

    try {
      // Важно: удаляем связанные сущности синхронно, чтобы заказ не "висел"
      // в модуле производственных заданий и рабочем пространстве.
      await _supabase.from('tasks').delete().eq('order_id', id);
      await _supabase.from('order_paints').delete().eq('order_id', id);
      try {
        final plan = await _supabase
            .from('prod_plans')
            .select('id')
            .eq('order_id', id)
            .maybeSingle();
        if (plan != null && plan['id'] != null) {
          await _supabase
              .from('prod_plan_stages')
              .delete()
              .eq('plan_id', plan['id'].toString());
        }
      } catch (_) {
        // Таблицы могут отсутствовать в некоторых окружениях.
      }
      await _supabase.from('prod_plans').delete().eq('order_id', id);
      await _supabase.from('production_plans').delete().eq('order_id', id);
      await _supabase.from('orders').delete().eq('id', id);
      // Историю удалять не обязательно — это след.
      await _logOrderEvent(id, 'Удаление', 'Удалён заказ');
    } catch (e, st) {
      // rollback
      _orders.insert(index, removed);
      notifyListeners();
      debugPrint('❌ deleteOrder error: $e\n$st');
    }
  }

  Future<void> shipOrder(OrderModel order, {double? writeoffOverride}) async {
    await _ensureAuthed();

    final index = _orders.indexWhere((o) => o.id == order.id);
    if (index == -1) return;

    Map<String, dynamic>? latestRow;
    try {
      latestRow = await _supabase
          .from('orders')
          .select('actual_qty, handle')
          .eq('id', order.id)
          .maybeSingle();
    } catch (e, st) {
      debugPrint('⚠️ shipOrder: unable to fetch latest actual_qty: $e\n$st');
    }

    double? actualQtyOverride =
        _toDoubleNullable(latestRow == null ? null : latestRow['actual_qty']);
    final String handleOverride =
        (latestRow?['handle'] ?? order.handle).toString();

    final OrderModel orderData = order.copyWith(
      handle: handleOverride,
      actualQty: actualQtyOverride ?? order.actualQty,
    );

    final double plannedQty = orderData.product.quantity.toDouble();
    final double actualQty =
        orderData.actualQty ?? orderData.product.quantity.toDouble();
    final double safeActual = actualQty < 0 ? 0 : actualQty;
    if (safeActual < plannedQty) {
      // Бизнес-правило отгрузки: нельзя отгружать меньше тиража.
      throw Exception(
        'Отгрузка запрещена: фактическое количество '
        '(${_formatQty(safeActual)}) меньше тиража (${_formatQty(plannedQty)}).',
      );
    }

    double writeoffQty = writeoffOverride ??
        (safeActual < plannedQty ? safeActual : plannedQty.toDouble());
    if (writeoffQty.isNaN || writeoffQty.isInfinite) {
      writeoffQty = 0;
    }
    if (writeoffQty < 0) {
      writeoffQty = 0;
    }

    final double leftoverQty =
        safeActual > writeoffQty ? (safeActual - writeoffQty) : 0;

    final double? actualQtyForPens = orderData.actualQty;
    final String? sizeLabel = _formatProductSize(orderData.product);

    try {
      await _processCategoryShipment(
        order: orderData,
        actualQty: safeActual,
        writeoffQty: writeoffQty,
        leftoverQty: leftoverQty,
        sizeLabel: sizeLabel,
      );
      await _applyPensConsumption(
        order: orderData,
        targetQty: safeActual,
        silentOnError: true,
      );
    } catch (e, st) {
      debugPrint('❌ shipOrder stock error: $e\n$st');
      rethrow;
    }

    final DateTime now = DateTime.now();
    final previous = _orders[index];
    final updated = orderData.copyWith(
      status: OrderStatus.completed.name,
      shippedAt: now,
      shippedBy: AuthHelper.currentUserName ?? '',
      shippedQty: writeoffQty,
    );

    _orders[index] = updated;
    notifyListeners();

    try {
      await _supabase
          .from('orders')
          .update(updated.toMap()..remove('id'))
          .eq('id', order.id);
      if (actualQtyForPens != null && actualQtyForPens > 0) {
        await _logPensCompletionWriteoff(
          order: orderData,
          quantity: actualQtyForPens,
        );
      }
      await _logOrderEvent(order.id, 'Отгрузка', 'Заказ отгружен');
    } catch (e, st) {
      debugPrint('❌ shipOrder update error: $e\n$st');
      _orders[index] = previous;
      notifyListeners();
      rethrow;
    }
  }

  Future<void> resetLaunchedOrderForRelaunch(String orderId) async {
    await _ensureAuthed();
    try {
      // Бизнес-правило: после правок запущенного, но не начатого заказа
      // убираем его из производственных списков и возвращаем в ручной запуск.
      await _supabase.from('tasks').delete().eq('order_id', orderId);
      await _supabase.from('orders').update({
        'assignment_created': false,
        'status': OrderStatus.ready_to_start.name,
      }).eq('id', orderId);
      await _logOrderEvent(
        orderId,
        'Сброс запуска',
        'После редактирования заказ снят с производства и требует повторного запуска',
      );
      await refresh();
    } catch (e, st) {
      debugPrint('❌ resetLaunchedOrderForRelaunch error: $e\n$st');
      rethrow;
    }
  }

  Future<void> _processCategoryShipment({
    required OrderModel order,
    required double actualQty,
    required double writeoffQty,
    required double leftoverQty,
    String? sizeLabel,
  }) async {
    final productName = order.product.type.trim();
    final customerName = order.customer.trim();
    if (productName.isEmpty || customerName.isEmpty) {
      return;
    }

    if (writeoffQty <= 0 && leftoverQty <= 0) {
      return;
    }

    final sanitizedProduct = productName.replaceAll("'", "''");
    final category = await _supabase
        .from('warehouse_categories')
        .select('id, has_subtables')
        .or('title.eq.$sanitizedProduct,code.eq.$sanitizedProduct')
        .maybeSingle();

    if (category == null || category['id'] == null) {
      throw Exception('Категория для "$productName" не найдена');
    }

    final bool hasSubtables = (category['has_subtables'] ?? false) == true;
    final String categoryId = category['id'].toString();

    Map<String, dynamic>? item;
    try {
      var rowsQuery = _supabase
          .from('warehouse_category_items')
          .select('id, quantity, table_key')
          .eq('category_id', categoryId)
          .eq('description', customerName);
      if (hasSubtables) {
        rowsQuery = rowsQuery.eq('table_key', productName);
      }
      final rows = await rowsQuery;
      if (rows is List && rows.isNotEmpty) {
        final raw = rows.first;
        if (raw is Map) {
          item = Map<String, dynamic>.from(raw);
        }
      }
    } catch (e) {
      debugPrint('❌ load category items error: $e');
    }

    final double initialQty = actualQty > 0 ? actualQty : writeoffQty;
    if (item == null) {
      final inserted = await _supabase
          .from('warehouse_category_items')
          .insert({
            'category_id': categoryId,
            'description': customerName,
            'quantity': initialQty,
            if (sizeLabel != null && sizeLabel.isNotEmpty) 'size': sizeLabel,
            if (hasSubtables) 'table_key': productName,
          })
          .select('id, quantity, table_key')
          .single();
      item = Map<String, dynamic>.from(inserted);
    } else {
      final double currentQty =
          (item['quantity'] is num) ? (item['quantity'] as num).toDouble() : 0.0;
      if (initialQty > currentQty) {
        final Map<String, dynamic> updatePayload = {
          'quantity': initialQty,
        };
        if (sizeLabel != null && sizeLabel.isNotEmpty) {
          updatePayload['size'] = sizeLabel;
        }
        await _supabase
            .from('warehouse_category_items')
            .update(updatePayload)
            .match({'id': item['id']});
        item['quantity'] = initialQty;
        if (sizeLabel != null && sizeLabel.isNotEmpty) {
          item['size'] = sizeLabel;
        }
      }
    }

    final String itemId = item['id'].toString();

    if (writeoffQty > 0) {
      final Map<String, dynamic> writeoffPayload = {
        'item_id': itemId,
        'qty': writeoffQty,
        'reason': customerName,
        'by_name': AuthHelper.currentUserName ?? '',
      };
      if (sizeLabel != null && sizeLabel.isNotEmpty) {
        writeoffPayload['size'] = sizeLabel;
      }
      await _supabase
          .from('warehouse_category_writeoffs')
          .insert(writeoffPayload);
    }

    final double nextQty = leftoverQty > 0 ? leftoverQty : 0;
    final Map<String, dynamic> nextPayload = {
      'quantity': nextQty,
    };
    if (sizeLabel != null && sizeLabel.isNotEmpty) {
      nextPayload['size'] = sizeLabel;
    }
    await _supabase
        .from('warehouse_category_items')
        .update(nextPayload)
        .match({'id': itemId});
    if (sizeLabel != null && sizeLabel.isNotEmpty) {
      item['size'] = sizeLabel;
    }
  }

  String? _formatProductSize(ProductModel product) {
    final List<String> parts = <String>[];

    String formatDouble(double value) {
      final String fixed = value.toStringAsFixed(2);
      if (!fixed.contains('.')) return fixed;
      final String trimmed = fixed
          .replaceAll(RegExp(r'0+$'), '')
          .replaceAll(RegExp(r'[.]$'), '');
      return trimmed.isEmpty ? '0' : trimmed;
    }

    void tryAdd(double value) {
      if (value > 0) {
        parts.add(formatDouble(value));
      }
    }

    tryAdd(product.width);
    tryAdd(product.height);
    tryAdd(product.depth);

    if (parts.isEmpty) {
      return null;
    }

    return parts.join('*');
  }

  Future<Map<String, dynamic>?> loadCategoryItemSnapshot(
      OrderModel order) async {
    await _ensureAuthed();

    final String productName = order.product.type.trim();
    final String customerName = order.customer.trim();

    if (productName.isEmpty || customerName.isEmpty) {
      return null;
    }

    final String sanitizedProduct = productName.replaceAll("'", "''");
    final dynamic category = await _supabase
        .from('warehouse_categories')
        .select('id, title, code, has_subtables')
        .or('title.eq.$sanitizedProduct,code.eq.$sanitizedProduct')
        .maybeSingle();

    if (category == null || category['id'] == null) {
      return null;
    }

    final bool hasSubtables = (category['has_subtables'] ?? false) == true;
    var rowsQuery = _supabase
        .from('warehouse_category_items')
        .select('id, description, quantity, size, comment')
        .eq('category_id', category['id'])
        .eq('description', customerName);
    if (hasSubtables) {
      rowsQuery = rowsQuery.eq('table_key', productName);
    }
    final rows = await rowsQuery;

    if (rows is List && rows.isNotEmpty) {
      final raw = rows.first;
      if (raw is Map) {
        return Map<String, dynamic>.from(raw as Map);
      }
    }

    return null;
  }

  Future<void> _handleActualQtyChange({
    required OrderModel previous,
    required OrderModel updated,
  }) async {
    final double? prevQty = previous.actualQty;
    final double? newQty = updated.actualQty;

    if (newQty == null) {
      return;
    }

    if (prevQty != null && newQty <= prevQty) {
      return;
    }

    await _applyPensConsumption(
      order: updated,
      targetQty: newQty,
      silentOnError: true,
    );
  }

  Future<void> _handleOrderStatusChange({
    required OrderModel previous,
    required OrderModel updated,
  }) async {
    final bool wasCompleted = previous.statusEnum == OrderStatus.completed;
    final bool isCompleted = updated.statusEnum == OrderStatus.completed;
    if (wasCompleted || !isCompleted) {
      return;
    }

    final double? actual = updated.actualQty;
    final double? fallback = updated.shippedQty;
    final double quantity = actual ?? fallback ?? 0;
    if (quantity <= 0) {
      return;
    }

    await _logPensCompletionWriteoff(order: updated, quantity: quantity);
  }

  Future<void> _applyPensConsumption({
    required OrderModel order,
    required double targetQty,
    bool silentOnError = false,
  }) async {
    final handle = order.handle.trim();
    if (handle.isEmpty || handle == '-') {
      return;
    }
    if (targetQty <= 0) {
      return;
    }

    try {
      final handleRow = await _findHandleRow(handle);
      if (handleRow == null) {
        if (!silentOnError) {
          throw Exception('Ручки "$handle" не найдены на складе');
        }
        return;
      }
      final String itemId = (handleRow['id'] ?? '').toString().trim();
      if (itemId.isEmpty) {
        if (!silentOnError) {
          throw Exception('Ручки "$handle" не найдены на складе');
        }
        return;
      }

      final String itemKey = 'pens:$itemId';
      final Map<String, dynamic> snapshot =
          await _ensureConsumptionSnapshot(order.id, itemKey);
      final double already = _toDouble(snapshot['quantity']);
      if (targetQty <= already) {
        return;
      }

      final String nowIso = DateTime.now().toIso8601String();
      final Map<String, dynamic> payload = {
        'quantity': targetQty,
        'updated_at': nowIso,
      };
      await _supabase
          .from('order_consumption_snapshots')
          .update(payload)
          .eq('order_id', order.id)
          .eq('item_key', itemKey);
    } catch (e, st) {
      if (silentOnError) {
        debugPrint('⚠️ pens consumption error: $e\n$st');
      } else {
        rethrow;
      }
    }
  }

  Future<void> _logPensCompletionWriteoff({
    required OrderModel order,
    required double quantity,
  }) async {
    final double safeQty = quantity;
    if (safeQty <= 0) {
      return;
    }
    final handle = order.handle.trim();
    if (handle.isEmpty || handle == '-') {
      return;
    }
    try {
      final handleRow = await _findHandleRow(handle);
      if (handleRow == null) {
        return;
      }
      final String itemId = (handleRow['id'] ?? '').toString().trim();
      if (itemId.isEmpty) {
        return;
      }
      final String customer = order.customer.trim();
      final String author = (AuthHelper.currentUserName ?? '').trim();
      final String orderId = order.id.trim();

      if (orderId.isEmpty) {
        return;
      }

      try {
        final existing = await _supabase
            .from('warehouse_pens_writeoffs')
            .select('id')
            .eq('order_id', orderId)
            .maybeSingle();
        if (existing != null) {
          return;
        }
      } catch (_) {
        // Если RLS запрещает просмотр — продолжаем и пытаемся вставить.
      }

      final payload = <String, dynamic>{
        'item_id': itemId,
        'qty': safeQty,
        'order_id': orderId,
      };
      if (customer.isNotEmpty) {
        payload['reason'] = customer;
      }
      if (author.isNotEmpty) {
        payload['by_name'] = author;
      }

      await _supabase.from('warehouse_pens_writeoffs').insert(payload);
    } catch (e, st) {
      debugPrint('⚠️ pens completion writeoff log error: $e\n$st');
    }
  }

  Future<Map<String, dynamic>> _ensureConsumptionSnapshot(
      String orderId, String itemKey) async {
    try {
      final existing = await _supabase
          .from('order_consumption_snapshots')
          .select()
          .eq('order_id', orderId)
          .eq('item_key', itemKey)
          .maybeSingle();
      if (existing != null) {
        return Map<String, dynamic>.from(existing as Map);
      }
    } catch (_) {}

    final String nowIso = DateTime.now().toIso8601String();
    final Map<String, dynamic> payload = {
      'order_id': orderId,
      'item_key': itemKey,
      'quantity': 0,
      'created_at': nowIso,
      'updated_at': nowIso,
    };
    await _supabase.from('order_consumption_snapshots').insert(payload);
    return payload;
  }

  Future<Map<String, dynamic>?> _findHandleRow(String description) async {
    final trimmed = description.trim();
    if (trimmed.isEmpty || trimmed == '-') {
      return null;
    }
    try {
      final response = await _supabase
          .from('warehouse_pens')
          .select('id, name, color, quantity')
          .order('created_at');
      if (response is! List) {
        return null;
      }
      Map<String, dynamic>? fallback;
      for (final raw in response) {
        if (raw is! Map) continue;
        final row = Map<String, dynamic>.from(raw as Map);
        final name = (row['name'] ?? '').toString().trim();
        final color = (row['color'] ?? '').toString().trim();
        final desc = [name, color]
            .where((part) => part.isNotEmpty)
            .join(' • ')
            .trim();
        if (desc.toLowerCase() == trimmed.toLowerCase()) {
          return row;
        }
        if (fallback == null &&
            name.isNotEmpty &&
            name.toLowerCase() == trimmed.toLowerCase()) {
          fallback = row;
        }
      }
      return fallback;
    } catch (e, st) {
      debugPrint('❌ _findHandleRow error: $e\n$st');
      return null;
    }
  }

  double _toDouble(dynamic value) {
    if (value is num) {
      return value.toDouble();
    }
    if (value == null) {
      return 0;
    }
    return double.tryParse(value.toString()) ?? 0;
  }

  double? _toDoubleNullable(dynamic value) {
    if (value == null) return null;
    if (value is num) return value.toDouble();
    final String text = value.toString().trim();
    if (text.isEmpty) return null;
    return double.tryParse(text.replaceAll(',', '.'));
  }

  String _formatQtyValue(double value) {
    if (value % 1 == 0) {
      return value.toInt().toString();
    }
    String text = value.toStringAsFixed(2);
    text = text.replaceAll(RegExp(r'0+$'), '');
    if (text.endsWith('.') || text.endsWith(',')) {
      text = text.substring(0, text.length - 1);
    }
    return text;
  }

  // ===== HISTORY =====

  Future<void> _logOrderEvent(
    String orderId,
    String eventType,
    String description, {
    String? userId,
  }) async {
    try {
      await _supabase.from('order_events').insert({
        'order_id': orderId,
        'event_type': eventType,
        'description': description,
        if (userId != null) 'user_id': userId,
      });
    } catch (e, st) {
      // Non-fatal
      debugPrint('❌ logOrderEvent error: $e\n$st');
    }
  }

  /// Возвращает список событий истории по идентификатору заказа.
  Future<List<Map<String, dynamic>>> fetchOrderHistory(String orderId) async {
    DateTime? _parseTimestamp(dynamic value) {
      if (value == null) return null;
      if (value is int) {
        if (value > 2000000000) {
          return DateTime.fromMillisecondsSinceEpoch(value);
        }
        return DateTime.fromMillisecondsSinceEpoch(value * 1000);
      }
      if (value is num) {
        final int intValue = value.toInt();
        return _parseTimestamp(intValue);
      }
      if (value is String) {
        if (value.isEmpty) return null;
        final parsedInt = int.tryParse(value);
        if (parsedInt != null) return _parseTimestamp(parsedInt);
        return DateTime.tryParse(value);
      }
      if (value is DateTime) return value;
      return null;
    }

    double? _extractQuantity(String type, String text) {
      const trackedTypes = {'quantity_done', 'quantity_team_total', 'quantity_share'};
      if (!trackedTypes.contains(type)) return null;
      final normalized = text.replaceAll(',', '.');
      final match = RegExp(r'-?[0-9]+(?:\.[0-9]+)?').firstMatch(normalized);
      if (match != null) {
        return double.tryParse(match.group(0)!);
      }
      return double.tryParse(normalized.trim());
    }

    String? _stringOrNull(dynamic value) {
      if (value == null) return null;
      final String stringValue = value.toString();
      return stringValue.trim().isEmpty ? null : stringValue;
    }

    try {
      final List<Map<String, dynamic>> combined = [];

      final eventRows = await _supabase
          .from('order_events')
          .select()
          .eq('order_id', orderId)
          .order('created_at');

      if (eventRows is List) {
        for (final raw in eventRows) {
          if (raw is! Map) continue;
          final map = Map<String, dynamic>.from(raw as Map);
          final DateTime? ts =
              _parseTimestamp(map['created_at'] ?? map['timestamp'] ?? map['inserted_at']);
          combined.add({
            'source': 'order_event',
            'timestamp': ts?.millisecondsSinceEpoch,
            'event_type': _stringOrNull(map['event_type']) ?? '',
            'description':
                _stringOrNull(map['description']) ?? _stringOrNull(map['message']) ?? '',
            'user_id': _stringOrNull(map['user_id']),
            'payload': map['payload'],
          });
        }
      }

      // Чат заказа (если room_id совпадает с id заказа).
      try {
        final chatRows = await _supabase
            .from('chat_messages')
            .select('created_at, sender_id, sender_name, body, text, kind')
            .eq('room_id', orderId)
            .order('created_at');
        if (chatRows is List) {
          for (final raw in chatRows) {
            if (raw is! Map) continue;
            final map = Map<String, dynamic>.from(raw as Map);
            final DateTime? ts =
                _parseTimestamp(map['created_at'] ?? map['timestamp']);
            final String text = _stringOrNull(map['body']) ??
                _stringOrNull(map['text']) ??
                '[вложение]';
            combined.add({
              'source': 'chat_message',
              'timestamp': ts?.millisecondsSinceEpoch,
              'event_type': 'chat_message',
              'description': text,
              'user_id': _stringOrNull(map['sender_id']),
              'user_name': _stringOrNull(map['sender_name']),
              'kind': _stringOrNull(map['kind']) ?? 'text',
            });
          }
        }
      } catch (_) {
        // Таблица/колонки чата могут отличаться между инсталляциями.
      }

      final taskRows = await _supabase
          .from('tasks')
          .select('id, stage_id, comments')
          .eq('order_id', orderId);

      if (taskRows is List) {
        for (final raw in taskRows) {
          if (raw is! Map) continue;
          final map = Map<String, dynamic>.from(raw as Map);
          final String? stageId = _stringOrNull(map['stage_id'] ?? map['stageId']);
          final commentsData = map['comments'];
          final List<Map<String, dynamic>> commentsList = [];

          if (commentsData is List) {
            for (final item in commentsData) {
              if (item is Map) {
                commentsList.add(Map<String, dynamic>.from(item));
              }
            }
          } else if (commentsData is Map) {
            commentsData.forEach((_, value) {
              if (value is Map) {
                commentsList.add(Map<String, dynamic>.from(value));
              }
            });
          }

          for (final comment in commentsList) {
            final String type = _stringOrNull(comment['type']) ?? '';
            final String text = _stringOrNull(comment['text']) ?? '';
            final DateTime? ts = _parseTimestamp(comment['timestamp']);
            combined.add({
              'source': 'task_comment',
              'timestamp': ts?.millisecondsSinceEpoch,
              'event_type': type,
              'description': text,
              'user_id': _stringOrNull(comment['userId']),
              'stage_id': stageId,
              'quantity': _extractQuantity(type, text),
            });
          }
        }
      }

      try {
        final orderRow = await _supabase
            .from('orders')
            .select('shipped_at, shipped_qty, shipped_by, actual_qty')
            .eq('id', orderId)
            .maybeSingle();
        if (orderRow case final Map<dynamic, dynamic> orderRowMap) {
          final Map<String, dynamic> orderData =
              Map<String, dynamic>.from(orderRowMap);
          final DateTime? shippedAt = _parseTimestamp(orderData['shipped_at']);
          final double? shippedQty = _toDoubleNullable(orderData['shipped_qty']);
          final double? producedQty = _toDoubleNullable(orderData['actual_qty']);
          if (producedQty != null) {
            combined.add({
              'source': 'order_event',
              'timestamp': shippedAt?.millisecondsSinceEpoch,
              'event_type': 'produced_qty',
              'description': 'Произведено: ${_formatQty(producedQty)}',
              'quantity': producedQty,
            });
          }
          if (shippedAt != null || shippedQty != null) {
            combined.add({
              'source': 'shipment',
              'timestamp': shippedAt?.millisecondsSinceEpoch,
              'event_type': 'shipment',
              'description':
                  'Отгрузка: ${_formatQty(shippedQty ?? 0)}; исполнитель: ${_stringOrNull(orderData['shipped_by']) ?? '—'}',
              'user_name': _stringOrNull(orderData['shipped_by']),
              'quantity': shippedQty,
            });
          }
        }
      } catch (_) {}

      combined.sort((a, b) {
        final int tsA = (a['timestamp'] as int?) ?? 0;
        final int tsB = (b['timestamp'] as int?) ?? 0;
        return tsA.compareTo(tsB);
      });

      return combined;
    } catch (e, st) {
      debugPrint('❌ fetchOrderHistory error: $e\n$st');
      return [];
    }
  }

  String _formatQty(double value) {
    if ((value - value.roundToDouble()).abs() < 0.0001) {
      return value.round().toString();
    }
    return value.toStringAsFixed(2);
  }

  // ===== STOCK (WAREHOUSE) INTEGRATION =====

  /// Списание бумаги по данным заказа (если выбран материал со склада бумаги).
  Future<void> _applyPaperWriteoffFromOrder(OrderModel order) async {
    final Map<String, dynamic> pm = order.product.toMap();
    final String? materialIdFromOrder = order.material?.id;
    final String? tmcId = materialIdFromOrder ??
        (pm['tmcId'] ?? pm['tmc_id'] ?? pm['materialId'] ?? pm['material_id'])
            as String?;

    final double lengthValue = () {
      final dynamic rawLength =
          pm['length'] ?? order.product.length ?? pm['length_l'];
      if (rawLength is num) {
        return rawLength.toDouble();
      }
      return double.tryParse('$rawLength') ?? 0.0;
    }();

    final dynamic qRaw = (pm['quantity'] ?? pm['qty'] ?? pm['count']);
    final double fallbackQty =
        (qRaw is num) ? qRaw.toDouble() : double.tryParse('$qRaw') ?? 0.0;
    final double targetQty = lengthValue > 0 ? lengthValue : fallbackQty;

    if (tmcId == null || targetQty <= 0) {
      return;
    }

    final String itemKey = 'paper:$tmcId';
    final Map<String, dynamic> snapshot =
        await _ensureConsumptionSnapshot(order.id, itemKey);
    final double alreadyWritten = _toDouble(snapshot['quantity']);

    final double delta = targetQty - alreadyWritten;
    final String nowIso = DateTime.now().toIso8601String();

    if (delta > 0) {
      final String reason = order.customer.trim().isEmpty
          ? 'Списание бумаги для заказа ${order.id}'
          : order.customer.trim();
      final String author = (AuthHelper.currentUserName ?? '').trim();

      final Map<String, dynamic> params = {
        'type': 'paper',
        'item': tmcId,
        'qty': delta,
        'reason': reason,
      };
      if (author.isNotEmpty) {
        params['by_name'] = author;
      }

      try {
        await _supabase.rpc('writeoff', params: params);
      } catch (error) {
        // не обновляем snapshot при ошибке — пусть вызывающий обработает исключение
        rethrow;
      }
    }

    await _supabase
        .from('order_consumption_snapshots')
        .update({'quantity': targetQty, 'updated_at': nowIso})
        .eq('order_id', order.id)
        .eq('item_key', itemKey);
  }

  Future<void> applyPaperWriteoff(OrderModel order) async {
    await _applyPaperWriteoffFromOrder(order);
  }

  Future<void> applyStockOnFulfillment(OrderModel order) async {
    await _applyStockDelta(order, isShipment: true);
  }

  Future<void> revertStockOnCancel(OrderModel order) async {
    await _applyStockDelta(order, isShipment: false);
  }

  Future<void> _applyStockDelta(
    OrderModel order, {
    required bool isShipment,
  }) async {
    final pm = order.product.toMap();

    final String? tmcId = (pm['tmcId'] ??
        pm['tmc_id'] ??
        pm['materialId'] ??
        pm['material_id']) as String?;

    final dynamic qRaw = (pm['quantity'] ?? pm['qty'] ?? pm['count']);
    final double qty =
        (qRaw is num) ? qRaw.toDouble() : double.tryParse('$qRaw') ?? 0.0;

    if (tmcId == null || qty <= 0) return;

    final delta = isShipment ? -qty : qty;
    try {
      await _supabase.rpc('materials_increment', params: {
        'p_id': tmcId,
        'p_delta': delta,
      });
    } catch (e) {
      debugPrint('⚠️ stock delta failed for $tmcId: $e');
    }
  }

  // ===== HELPERS =====

  /// Генерирует человекочитаемый номер заказа типа ORD-YYYY-N.
  /// Храните его в поле модели (не в PK).
  String generateHumanNumber({int? sequence}) {
    final year = DateTime.now().year;
    final n = sequence ?? (_orders.length + 1);
    return 'ORD-$year-$n';
  }

  /// Генерирует человекочитаемый номер задания вида `ZK-YYYY-NNN`.
  /// Храните его в `assignmentId` модели заказа.
  String generateAssignmentId({String prefix = 'ZK'}) {
    final year = DateTime.now().year;
    int maxSeq = 0;
    for (final o in _orders) {
      final id = o.assignmentId;
      if (id == null || id.isEmpty) continue;
      if (!id.startsWith('$prefix-$year-')) continue;
      final parts = id.split('-');
      if (parts.length < 3) continue;
      final seq = int.tryParse(parts.last) ?? 0;
      if (seq > maxSeq) maxSeq = seq;
    }
    final next = (maxSeq + 1).toString().padLeft(3, '0');
    return '$prefix-$year-$next';
  }

  /// Генерирует читаемый номер заказа: `ЗК-YYYY.MM.DD-N` (N — порядковый за день).
  Future<String> generateReadableOrderId(
    DateTime date, {
    String prefix = 'ЗК',
  }) async {
    await _ensureAuthed();
    final yyyy = date.year.toString().padLeft(4, '0');
    final mm = date.month.toString().padLeft(2, '0');
    final dd = date.day.toString().padLeft(2, '0');
    final datePrefix = '$prefix-$yyyy.$mm.$dd-';
    int maxSeq = 0;

    // Смотрим уже загруженные заказы в провайдере
    for (final o in _orders) {
      final aid = o.assignmentId ?? '';
      if (!aid.startsWith(datePrefix)) continue;
      final parts = aid.split('-');
      if (parts.length < 3) continue;
      final seq = int.tryParse(parts.last) ?? 0;
      if (seq > maxSeq) maxSeq = seq;
    }

    // Дополнительно проверим по БД на всякий случай
    try {
      final rows = await _supabase
          .from('orders')
          .select('assignment_id')
          .ilike('assignment_id', '${datePrefix}%');

      for (final r in (rows as List)) {
        final aid = (r['assignment_id'] ?? '').toString();
        if (!aid.startsWith(datePrefix)) continue;
        final parts = aid.split('-');
        if (parts.length < 3) continue;
        final seq = int.tryParse(parts.last) ?? 0;
        if (seq > maxSeq) maxSeq = seq;
      }
    } catch (_) {}

    final next = (maxSeq + 1).toString();
    return '$datePrefix$next';
  }
}
