import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../../services/doc_db.dart';

import 'material_model.dart';
import 'order_model.dart';
import 'product_model.dart';
import '../../utils/auth_helper.dart';

class OrdersProvider with ChangeNotifier {
  final SupabaseClient _supabase = Supabase.instance.client;
  // DocDB instance to interact with the universal `documents` table.
  final DocDB _docDb = DocDB();

  final List<OrderModel> _orders = [];
  StreamSubscription<List<Map<String, dynamic>>>? _ordersSub;
  // Realtime channel for listening to order changes via documents.
  RealtimeChannel? _ordersChannel;

  OrdersProvider() {
    _listenToOrders();
  }

  List<OrderModel> get orders => List.unmodifiable(_orders);

  Future<void> refresh() async {
    try {
      final rows = await _docDb.list('orders');
      _orders
        ..clear()
        ..addAll(rows.map((row) {
          // Extract order data from documents. `data` contains order fields.
          final data = Map<String, dynamic>.from(row['data'] as Map);
          // Preserve the document id as order id (UUID).
          data['id'] = row['id'];

          final p = data['product'];
          if (p is String) {
            try {
              data['product'] =
                  p.isEmpty ? <String, dynamic>{} : jsonDecode(p) as Map;
            } catch (_) {
              data['product'] = <String, dynamic>{};
            }
          } else if (p == null) {
            data['product'] = <String, dynamic>{};
          }

          return OrderModel.fromMap(data);
        }));
      notifyListeners();
    } catch (e, st) {
      debugPrint('❌ refresh orders error: $e\n$st');
    }
  }

  // ===== live stream =====
  void _listenToOrders() {
    // Cancel any previous subscriptions
    _ordersSub?.cancel();
    if (_ordersChannel != null) {
      _supabase.removeChannel(_ordersChannel!);
      _ordersChannel = null;
    }
    // Initial fetch
    refresh();
    // Subscribe to realtime changes in documents collection 'orders'
    _ordersChannel = _docDb.listenCollection('orders', (row, eventType) async {
      // On any change, refresh the local list. Simpler than patching.
      await refresh();
    });
  }

  @override
  void dispose() {
    _ordersSub?.cancel();
    if (_ordersChannel != null) {
      _supabase.removeChannel(_ordersChannel!);
    }
    super.dispose();
  }

  // ===== CRUD =====

  /// Добавляет готовый заказ и сохраняет его в DocDB.
  /// ВАЖНО: больше НЕ передаём "красивые" номера в id/explicitId.
  Future<void> addOrder(OrderModel order) async {
    // оптимистично добавляем с тем id, что есть в модели
    _orders.add(order);
    notifyListeners();

    try {
      // Вставляем БЕЗ explicitId — UUID создаст БД.
      final inserted = await _docDb.insert('orders', order.toMap());
      final newId = inserted['id'] as String;

      // Подменяем локально id на реальный UUID из БД
      final idx = _orders.indexWhere((o) => o.id == order.id);
      if (idx != -1) {
        final data = Map<String, dynamic>.from(inserted['data'] as Map)
          ..['id'] = newId;
        _orders[idx] = OrderModel.fromMap(data);
        notifyListeners();
      }
    } catch (e, st) {
      // Откат
      _orders.removeWhere((o) => o.id == order.id);
      notifyListeners();
      debugPrint('❌ addOrder error: $e\n$st');
      // НЕ бросаем дальше, чтобы не валить приложение
    }
  }

  /// Создаёт заказ и сохраняет его. UUID выдаёт БД.
  /// Если нужен человекочитаемый «ORD-YYYY-N», храните его в data.number,
  /// НО не используйте как documents.id.
  Future<OrderModel?> createOrder({
    String manager = '',
    required String customer,
    required DateTime orderDate,
    required DateTime dueDate,
    required ProductModel product,
    List<String> additionalParams = const [],
    String handle = '-',
    String cardboard = 'нет',
    MaterialModel? material,
    double makeready = 0,
    double val = 0,
    String? pdfUrl,
    String? stageTemplateId,
    bool contractSigned = false,
    bool paymentDone = false,
    String comments = '',
  }) async {
    // Временный локальный id (только для оптимистичного UI)
    final tempLocalId = 'local-${DateTime.now().microsecondsSinceEpoch}';

    // Собираем локальную модель (с временным id)
    OrderModel localOrder = OrderModel(
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
      contractSigned: contractSigned,
      paymentDone: paymentDone,
      comments: comments,
      status: 'newOrder',
      assignmentId: null,
      assignmentCreated: false,
    );

    // Оптимистично добавляем
    _orders.add(localOrder);
    notifyListeners();

    try {
      // Вставляем БЕЗ explicitId — БД присвоит UUID.
      final inserted = await _docDb.insert('orders', localOrder.toMap());

      // Синхронизируем локальную запись с БД
      final createdData = Map<String, dynamic>.from(inserted['data'] as Map)
        ..['id'] = inserted['id'];
      final created = OrderModel.fromMap(createdData);

      final idx = _orders.indexWhere((o) => o.id == tempLocalId);
      if (idx != -1) {
        _orders[idx] = created;
        notifyListeners();
      }

      // Логируем создание заказа (без падений)
      await _logOrderEvent(created.id, 'Создание', 'Создан заказ');
      return created;
    } catch (e, st) {
      // Откат оптимистичной вставки
      _orders.removeWhere((o) => o.id == tempLocalId);
      notifyListeners();
      debugPrint('❌ createOrder error: $e\n$st');
      // НЕ rethrow — чтобы не убивать экран
      return null;
    }
  }

  /// Обновляет существующий заказ по ID.
  Future<void> updateOrder(OrderModel updated) async {
    final index = _orders.indexWhere((o) => o.id == updated.id);
    if (index == -1) return;

    final prev = _orders[index];
    _orders[index] = updated; // оптимистично
    notifyListeners();

    try {
      // Update the document's data in `documents`. We only update the JSON data, not the metadata.
      await _docDb.updateById(updated.id, updated.toMap());

      await _logOrderEvent(updated.id, 'Обновление', 'Изменён заказ');
    } catch (e, st) {
      _orders[index] = prev; // откат
      notifyListeners();
      debugPrint('❌ updateOrder error: $e\n$st');
    }
  }

  /// Удаляет заказ по идентификатору.
  Future<void> deleteOrder(String id) async {
    final index = _orders.indexWhere((o) => o.id == id);
    if (index == -1) return;

    final removed = _orders.removeAt(index);
    notifyListeners();

    try {
      await _docDb.deleteById(removed.id);
    } catch (e, st) {
      _orders.insert(index, removed); // откат
      notifyListeners();
      debugPrint('❌ deleteOrder error: $e\n$st');
    }
  }

  // ===== История заказов =====

  Future<void> _logOrderEvent(
    String orderId,
    String eventType,
    String description, {
    String? user,
  }) async {
    final rawUser = user ?? AuthHelper.currentUserId;

    bool _looksLikeUuid(String s) {
      final re = RegExp(
        r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[1-5][0-9a-fA-F]{3}-[89abAB][0-9a-fA-F]{3}-[0-9a-fA-F]{12}$',
      );
      return re.hasMatch(s);
    }

    final payload = <String, dynamic>{
      'order_id': orderId,
      'event_type': eventType,
      'description': description,
    };

    if (rawUser != null && rawUser.isNotEmpty) {
      if (_looksLikeUuid(rawUser)) {
        payload['user'] = rawUser; // только UUID
      } else {
        payload['actor_role'] = rawUser; // роли/строки сюда
      }
    }

    debugPrint('ℹ️ order_history payload: $payload');

    try {
      // Store order history as a document in the `order_history` collection.
      await _docDb.insert('order_history', payload);
    } catch (e, st) {
      debugPrint('❌ logOrderEvent error: $e\n$st');
    }
  }

  /// Возвращает список событий истории по идентификатору заказа.
  Future<List<Map<String, dynamic>>> fetchOrderHistory(String orderId) async {
    try {
      final rows = await _docDb.whereEq('order_history', 'order_id', orderId);
      // Sort ascending by created_at to match previous behavior
      rows.sort((a, b) {
        final aTime = a['created_at'];
        final bTime = b['created_at'];
        if (aTime is String && bTime is String) {
          return aTime.compareTo(bTime);
        }
        return 0;
      });
      return rows.map((r) {
        final data = Map<String, dynamic>.from(r['data'] as Map);
        // include timestamp
        data['created_at'] = r['created_at'];
        return data;
      }).toList();
    } catch (e, st) {
      debugPrint('❌ fetchOrderHistory error: $e\n$st');
      return [];
    }
  }

  // ===== Склад =====

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

    final tmcId = (pm['tmcId'] ??
        pm['tmc_id'] ??
        pm['materialId'] ??
        pm['material_id']) as String?;

    final qRaw = (pm['quantity'] ?? pm['qty'] ?? pm['count']);
    final qty =
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

  // ===== helpers =====

  /// Если нужен человекочитаемый номер типа ORD-YYYY-N — генерируйте и
  /// кладите его в data.number (НЕ в documents.id).
  String generateHumanNumber({int? sequence}) {
    final year = DateTime.now().year;
    final n = (sequence ??
        (_orders.where((o) {
          // если вы где-то храните number в data, можете считать по нему
          return true;
        }).length +
            1));
    return 'ORD-$year-$n';
  }

  /// Генерирует человекочитаемый номер задания (НЕ UUID), вида `ZK-YYYY-NNN`.
  /// Храните его в `order.assignmentId` (в data), а не в documents.id.
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
}
