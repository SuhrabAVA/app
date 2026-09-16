// lib/modules/orders/orders_provider.dart
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../utils/kostanay_time.dart';
import 'material_model.dart';
import 'order_extra_options.dart';
import 'order_model.dart';
import 'order_form_rules.dart';
import 'order_change_log.dart';
import 'order_deadline_countdown.dart';
import 'order_launch_rules.dart';
import 'order_required_blocks.dart';
import 'order_shipment_rules.dart';
import 'product_type_settings.dart';
import '../warehouse/paint_stock_rules.dart';
import 'paint_reservation_rules.dart';
import 'paper_reservation_rules.dart';
import 'order_queue_service.dart';
import 'orders_repository.dart';
import 'product_model.dart';
import '../tasks/stage_quantity_records.dart';
import '../tasks/task_model.dart' show normalizeEpochToMillis;
import '../../utils/auth_helper.dart';
import '../../utils/network_failures.dart';
import '../../services/realtime_sync_service.dart';
import '../../services/stock_availability_recheck_coordinator.dart';

/// Проверить обеспеченность не удалось — ответа НЕТ.
///
/// Это НЕ вердикт. «Не хватает», «краски нет на складе» и «обеспечен» — три
/// возможных ответа проверки; этот класс означает, что данные прочитать не
/// вышло и ответа не получено вовсе.
///
/// Разница принципиальна, потому что результат проверки ПИШЕТСЯ в `orders`
/// и расходится по всем устройствам. Раньше каждый сбой чтения молча
/// превращался в уверенный ответ, причём в разный: пустой список красок (сбой
/// на тяжёлом `select` по `paints`) читался как «красок в заказе нет» и поднимал
/// заказ в «Готов к запуску»; `null` от чтения остатка — как «краска не
/// найдена на складе» (красная карточка); отсутствие имени в справочнике —
/// как «краски нет вовсе» (фиолетовая). Один и тот же заказ на каждом
/// пересчёте выпадал в новое состояние, и карточка мигала между тремя.
///
/// Ловится в местах, которые пишут статус: заказ пропускается, его
/// прежние статус и текст остаются нетронутыми до следующего пересчёта.
class _StockCheckUnavailable implements Exception {
  const _StockCheckUnavailable(this.reason);

  final String reason;

  @override
  String toString() => 'Проверка обеспеченности недоступна: $reason';
}

/// Заказ, который держит резерв на бумаге.
class _PaperReservationHolder {
  const _PaperReservationHolder({required this.orderId, required this.qty});

  final String orderId;
  final double qty;
}

/// Потребность заказа в одной краске: сколько нужно и чем это на складе.
///
/// [paintId] пуст, когда краски с таким названием в справочнике нет. Это не
/// «нехватки нет», а «обеспечить нечем»: заказ с такой краской запускать
/// нельзя.
class _PaintRequirement {
  const _PaintRequirement({
    required this.paintId,
    required this.name,
    required this.grams,
  });

  final String? paintId;
  final String name;
  final double grams;
}

class OrdersProvider with ChangeNotifier {
  final SupabaseClient _supabase = Supabase.instance.client;

  final List<OrderModel> _orders = [];
  List<OrderModel> get orders => List.unmodifiable(_orders);

  bool _stockRecheckInProgress = false;

  /// Пересчёт попросили, пока шёл другой — сделать ещё проход.
  bool _stockRecheckRequested = false;
  bool _stockRecheckForceRequested = false;
  Future<void>? _activeRefresh;
  bool _refreshQueued = false;
  bool _disposed = false;

  OrdersProvider() {
    RealtimeSyncService.instance.registerRefreshHandler(
      owner: this,
      resource: RealtimeResource.orders,
      handler: refresh,
    );
    StockAvailabilityRecheckCoordinator.instance.register(
      owner: this,
      handler: () => recheckMaterialAvailability(forceRefresh: true),
    );
    refresh();
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
  Future<void> refresh() {
    final active = _activeRefresh;
    if (active != null) {
      _refreshQueued = true;
      return active;
    }
    final future = _runRefreshLoop();
    _activeRefresh = future;
    return future.whenComplete(() {
      if (identical(_activeRefresh, future)) _activeRefresh = null;
    });
  }

  Future<void> _runRefreshLoop() async {
    do {
      _refreshQueued = false;
      await _refreshOnce();
    } while (_refreshQueued);
  }

  /// Читает ВСЕ заказы страницами.
  ///
  /// PostgREST отдаёт максимум 1000 строк за запрос и молча обрезает остальное:
  /// без страниц список заказов однажды просто перестал бы показывать хвост,
  /// причём без единой ошибки в журнале. Сортировка внутри страницы должна быть
  /// однозначной, иначе строки с одинаковым created_at могут продублироваться
  /// на границе страниц или пропасть — поэтому вторым ключом идёт id.
  Future<List<Map<String, dynamic>>> _fetchAllOrderRows() async {
    const pageSize = 1000;
    final rows = <Map<String, dynamic>>[];
    for (var offset = 0;; offset += pageSize) {
      final page = await _supabase
          .from('orders')
          .select()
          .order('created_at', ascending: false)
          .order('id')
          .range(offset, offset + pageSize - 1);
      rows.addAll(page.cast<Map<String, dynamic>>());
      if (page.length < pageSize) break;
    }
    return rows;
  }

  Future<void> _refreshOnce() async {
    try {
      await _ensureAuthed();
      final rows = await _fetchAllOrderRows();
      if (_disposed) return;
      _orders
        ..clear()
        ..addAll(rows.map((row) => OrderModel.fromMap(row)));
      _dedupeOrdersById();
      notifyListeners();
    } catch (e, st) {
      debugPrint('❌ refresh orders error: $e\n$st');
    }
  }

  /// Пересчитать обеспеченность заказов.
  ///
  /// Просьба, пришедшая во время идущего пересчёта, НЕ теряется: после
  /// текущего прохода делается ещё один. Раньше здесь стоял немой `return`, и
  /// это ломало ровно то, ради чего пересчёт существует — автоматический
  /// переход статуса. Список заказов запускает пересчёт при открытии, а он
  /// ходит в сеть по каждому заказу и живёт секунды; заведение краски за это
  /// время попадало в идущий проход, обе его просьбы (из `addTmc` и из
  /// карточки) выбрасывались, и заказ оставался в прежнем статусе до тех пор,
  /// пока экран не откроют заново.
  Future<void> recheckMaterialAvailability({bool forceRefresh = false}) async {
    if (_stockRecheckInProgress) {
      _stockRecheckRequested = true;
      _stockRecheckForceRequested = _stockRecheckForceRequested || forceRefresh;
      return;
    }

    _stockRecheckInProgress = true;
    try {
      var force = forceRefresh;
      // Потолок проходов: пересчёт сам меняет `orders`, а его собственные
      // записи могут вызвать новую просьбу. Без потолка это крутилось бы
      // бесконечно на любом заказе, который не сходится.
      for (var pass = 0; pass < 3; pass++) {
        _stockRecheckRequested = false;
        await _runMaterialAvailabilityPass(forceRefresh: force);
        force = _stockRecheckForceRequested;
        _stockRecheckForceRequested = false;
        if (!_stockRecheckRequested || _disposed) break;
      }
    } finally {
      _stockRecheckInProgress = false;
      _stockRecheckRequested = false;
      _stockRecheckForceRequested = false;
    }
  }

  Future<void> _runMaterialAvailabilityPass({
    required bool forceRefresh,
  }) async {
    try {
      await _ensureAuthed();

      if (forceRefresh) {
        final rows = await _fetchAllOrderRows();
        _orders
          ..clear()
          ..addAll(rows.map((row) => OrderModel.fromMap(row)));
        _dedupeOrdersById();
        notifyListeners();
      }

      // Сначала возвращаем в производство запущенные заказы, у которых остался
      // дозапускной статус, и освобождаем бумагу, занятую теми, кому она
      // по статусу не положена.
      await _normalizeLaunchedOrderStatuses();
      await _releaseReservationsOfUnentitledOrders();

      final pending = _orders.where((order) {
        if (order.assignmentCreated) return false;
        return order.statusEnum == OrderStatus.waiting_materials ||
            order.statusEnum == OrderStatus.ready_to_start;
      }).toList(growable: false);

      for (final order in pending) {
        // Сбой чтения — не вердикт: заказ пропускаем, его статус и текст
        // остаются прежними до следующего пересчёта. Раньше такой сбой
        // превращался в уверенный ответ, и карточка мигала между «нет краски»,
        // «не найдена» и «готов к запуску».
        try {
          final queueBuilt = QueueBuildStatus.normalize(order.queueBuildStatus) ==
              QueueBuildStatus.built;
          if (!queueBuilt) {
            if (order.statusEnum == OrderStatus.draft &&
                !order.hasMaterialShortage &&
                order.materialShortageMessage.isEmpty) {
              continue;
            }
            await _releasePaperReservations(
              orderId: order.id,
              reason: 'queue_not_built',
              eventMessage:
                  'Бронь снята: очередь этапов не собрана, заказ вернулся в черновик',
            );
            await _releasePaintReservations(
              orderId: order.id,
              reason: 'queue_not_built',
            );
            await _supabase.from('orders').update({
              'status': OrderStatus.draft.name,
              'has_material_shortage': false,
              'material_shortage_message': '',
            }).eq('id', order.id);
            continue;
          }

          // Заказ с материалом без количества — не «ожидание материалов», а
          // недописанный заказ: возвращаем его в черновик и снимаем бронь.
          //
          // Без этой ветки правило держалось бы только на форме заказа, а
          // пересчёт поднимал бы старые записи обратно: проверка обеспеченности
          // разрешительная, и позиция с нулевой потребностью проходит её как
          // «нехватки нет». Правило — в materialsWithoutQuantity.
          final missingQuantities = await _materialsWithoutQuantity(order);
          if (missingQuantities.isNotEmpty) {
            await _releasePaperReservations(
              orderId: order.id,
              reason: 'material_quantity_missing',
              eventMessage: 'Бронь снята: у материала не указано количество '
                  '(${missingQuantities.join(', ')}), заказ вернулся в черновик',
            );
            await _releasePaintReservations(
              orderId: order.id,
              reason: 'material_quantity_missing',
            );
            await _supabase.from('orders').update({
              'status': OrderStatus.draft.name,
              'has_material_shortage': false,
              'material_shortage_message': '',
            }).eq('id', order.id);
            continue;
          }

          // Незаполненный обязательный блок — тоже недописанный заказ, а не
          // нехватка на складе. Ветка повторяет соседнюю по количеству:
          // правило обязано держаться и на пересчёте, иначе форма роняла бы
          // заказ в черновик, а фоновый пересчёт поднимал бы обратно.
          final missingRequired = await _missingRequiredBlocks(order);
          if (missingRequired.isNotEmpty) {
            final what = missingRequiredBlocksMessage(
                  missingCodes: missingRequired,
                  titlesByCode: ProductTypeSettings.instance.formBlockTitles,
                ) ??
                '';
            await _releasePaperReservations(
              orderId: order.id,
              reason: 'required_block_missing',
              eventMessage:
                  'Бронь снята: заказ вернулся в черновик. $what'.trim(),
            );
            await _releasePaintReservations(
              orderId: order.id,
              reason: 'required_block_missing',
            );
            // Текст нехватки пуст намеренно: карточка показывает его только у
            // заказа в «Ожидании материалов», а этот ушёл в черновик. Чего не
            // хватает, менеджер видит в самой форме заказа.
            await _supabase.from('orders').update({
              'status': OrderStatus.draft.name,
              'has_material_shortage': false,
              'material_shortage_message': '',
            }).eq('id', order.id);
            continue;
          }

          final hasEnough = await _hasEnoughMaterialForLaunch(order);

          // Бронь берём здесь же, а не при запуске. «Готов к запуску» обещает
          // менеджеру материал, и подтвердить обещание может только сервер: он
          // один видит гонку за рулон под блокировкой. Поэтому отказ RPC — это и
          // есть настоящая нехватка, даже когда локальная проверка её не
          // увидела, а его текст точнее нашего собственного сообщения.
          //
          // Проверка резерва идёт до сравнения статусов: заказ 323 уже стоял в
          // «Готов к запуску» с нулём метров, и выход по «статус не изменился»
          // оставлял бы его без брони навсегда.
          var ready = hasEnough;
          var shortageMessage = '';
          if (hasEnough) {
            final reserveError = await _syncPaperReservationsForOrder(order);
            if (reserveError != null) {
              ready = false;
              shortageMessage = reserveError;
            }
            // Краску занимаем здесь же, по той же причине, что и бумагу.
            //
            // Бронь краски пишет форма заказа, но при нехватке сервер отклоняет
            // её целиком — и заказ ложится в «Ожидание материалов» без единого
            // грамма за собой. Когда краску привезли, поднять заказ в готовность
            // мало: без брони её тут же заберёт сосед, и заказ вернётся обратно.
            if (ready) {
              final paintError = await _syncPaintReservationsForOrder(order.id);
              if (paintError != null) {
                ready = false;
                shortageMessage = paintError;
              }
            }
          } else {
            await _releasePaperReservations(
              orderId: order.id,
              reason: 'material_shortage',
              eventMessage:
                  'Бронь снята: материала не хватает, бумага возвращена на склад',
            );
            await _releasePaintReservations(
              orderId: order.id,
              reason: 'material_shortage',
            );
            shortageMessage = await _materialShortageMessage(order);
          }

          final nextStatus = ready
              ? OrderStatus.ready_to_start
              : OrderStatus.waiting_materials;

          // Сравнивать с [order] нельзя: это снимок из `_orders`, сделанный в
          // НАЧАЛЕ прохода. Предыдущий проход уже мог записать другой статус, а
          // до `refresh()` дело ещё не дошло — и тогда «ничего не изменилось»
          // означало «не писать», хотя в базе лежит противоположное.
          //
          // Как это выглядело в цехе: бронь снималась записью «материала не
          // хватает», а заказ оставался «Готов к запуску» с пустым сообщением —
          // без единого метра за собой. Карточка прыгала между «Готов к
          // запуску» и «Ожидание материалов» каждые пару минут, и в журнале
          // заказа копились пары «Создан резерв» / «Бронь снята» по 13 секунд.
          //
          // Поэтому сверяемся со свежей строкой. Лишнее чтение здесь дешёвое:
          // в проходе участвуют только незапущенные заказы, их единицы.
          final currentRow = await _supabase
              .from('orders')
              .select('status, has_material_shortage, material_shortage_message')
              .eq('id', order.id)
              .maybeSingle();
          final currentStatus = (currentRow?['status'] ?? '').toString();
          final currentShortage = currentRow?['has_material_shortage'] == true;
          final currentMessage =
              (currentRow?['material_shortage_message'] ?? '').toString();
          if (currentRow != null &&
              currentStatus == nextStatus.name &&
              currentShortage == !ready &&
              currentMessage == shortageMessage) {
            continue;
          }

          await _supabase.from('orders').update({
            'status': nextStatus.name,
            'has_material_shortage': !ready,
            'material_shortage_message': shortageMessage,
          }).eq('id', order.id);
        } on _StockCheckUnavailable catch (e) {
          debugPrint('ℹ️ заказ ${order.id} пропущен: $e');
          continue;
        }
      }
      await refresh();
    } catch (e, st) {
      debugPrint('material recheck failed: $e\n$st');
    }
  }

  /// Возвращает на склад бронь заказов, которым она по статусу не положена.
  ///
  /// Бумагу держит обеспеченный заказ — «Готов к запуску» и всё, что дальше.
  /// Черновик и «Ожидание материалов» бронь не держат: заказ, у которого
  /// рассыпалась очередь или не хватило метража, не должен морозить рулон.
  /// Правило — в [holdsPaperReservation].
  ///
  /// Прежняя версия снимала бронь со ВСЕХ незапущенных заказов. Так писалось,
  /// когда заказ не проходил проверку по собственной брони и чужие брони
  /// выталкивали соседей в «Ожидание материалов»; снос выглядел лечением.
  /// После исправления самоисключения тот снос стал вредным: заказ показывал
  /// кнопку «Запустить», не держа ни метра, и бумагу мог забрать сосед.
  Future<void> _releaseReservationsOfUnentitledOrders() async {
    final unentitled = _orders
        .where((order) =>
            !order.isShipped &&
            !holdsPaperReservation(
              assignmentCreated: order.assignmentCreated,
              status: order.statusEnum,
            ) &&
            // Завершённый заказ сюда не попадает: его бронь не возвращается на
            // склад, а списывается в finalize_order_paper_reservations.
            order.statusEnum != OrderStatus.completed)
        .map((order) => order.id.trim())
        .where((id) => id.isNotEmpty)
        .toList(growable: false);
    if (unentitled.isEmpty) return;

    try {
      final rows = await _supabase
          .from('order_paper_reservations')
          .select('order_id')
          .inFilter('order_id', unentitled);
      if (rows is! List || rows.isEmpty) return;
      final withReservation = rows
          .whereType<Map>()
          .map((row) => (row['order_id'] ?? '').toString().trim())
          .where((id) => id.isNotEmpty)
          .toSet()
          .toList(growable: false);
      if (withReservation.isEmpty) return;

      await _supabase
          .from('order_paper_reservations')
          .delete()
          .inFilter('order_id', withReservation);
      for (final orderId in withReservation) {
        await _logOrderEvent(
          orderId,
          'Резерв бумаги',
          'Бронь снята: заказ не обеспечен, бумага возвращена на склад',
        );
      }
    } catch (e, st) {
      debugPrint('⚠️ не удалось снять бронь необеспеченных заказов: $e\n$st');
    }
  }

  /// Запущенный заказ обязан жить в производственных статусах.
  ///
  /// Прежняя версия дозапускной проверки выбрасывала такие заказы в «Ожидание
  /// материалов» и «Готов к запуску»: она вычитала из доступного остатка их
  /// собственную бронь и считала заказ необеспеченным. Сама проверка
  /// исправлена, но заказы, испорченные до этого, обратно не возвращаются —
  /// статус лежит в базе, а сохранение запущенного заказа его лишь сохраняет
  /// как есть. Поэтому чиним их сами, при первом же пересчёте.
  ///
  /// Заказ, снятый с производства намеренно (resetLaunchedOrderForRelaunch),
  /// сюда не попадает: там вместе со статусом сбрасывается assignment_created.
  Future<void> _normalizeLaunchedOrderStatuses() async {
    // Набор статусов берём из materialAvailabilityStatus: там то же правило
    // применяется на каждом сохранении, и разъехаться эти два места не должны.
    final broken = _orders
        .where((order) =>
            order.assignmentCreated &&
            preLaunchStatuses.contains(order.statusEnum))
        .toList(growable: false);
    if (broken.isEmpty) return;

    for (final order in broken) {
      try {
        await _supabase.from('orders').update({
          'status': OrderStatus.in_production.name,
          'has_material_shortage': false,
          'material_shortage_message': '',
        }).eq('id', order.id);
        final index = _orders.indexWhere((o) => o.id == order.id);
        if (index != -1) {
          _orders[index] = _orders[index].copyWith(
            status: OrderStatus.in_production.name,
            hasMaterialShortage: false,
            materialShortageMessage: '',
          );
        }
        await _logOrderEvent(
          order.id,
          'Статус',
          'Заказ возвращён в производство: он был запущен, '
              'но статус остался дозапускным',
        );
      } catch (e, st) {
        debugPrint('⚠️ не удалось вернуть заказ ${order.id} в производство: '
            '$e\n$st');
      }
    }
    notifyListeners();
  }

  /// Что именно держит заказ в «Ожидании материалов» — целиком.
  ///
  /// Раньше здесь возвращалась ПЕРВАЯ найденная нехватка: сначала краска, и
  /// если она нашлась — бумагу уже не смотрели вовсе; если краски хватало —
  /// печаталась первая короткая бумага, а вторая и третья молчали. Менеджер
  /// вёз только то, что написано на карточке, заказ снова вставал, и так по
  /// кругу. Теперь перечисляем всё, чего не хватает, — и бумагу, и краски.
  Future<String> _materialShortageMessage(OrderModel order) async {
    final papers = _resolveOrderPapers(order);
    final shortages = <String>[
      // Невыбранная краска идёт первой: карточка красится серым только когда
      // это ЕДИНСТВЕННАЯ причина (см. isPaintNotSelectedShortage).
      if (await _paintSelectionMissing(order)) kPaintNotSelectedShortageMessage,
      ...await _paperShortages(order, papers),
      ...await _paintShortages(order),
    ];
    if (shortages.isNotEmpty) return shortages.join(' ');
    if (papers.isEmpty) return 'Материал не выбран в заказе.';
    return '';
  }

  Future<List<String>> _paperShortages(
    OrderModel order,
    List<MaterialModel> papers,
  ) async {
    final messages = <String>[];
    for (final paper in papers) {
      final requiredLength = _requiredPaperReserveQty(order, paper);
      if (requiredLength <= 0) continue;
      final stock = await _fetchMaterialStockQty(paper.id);
      if (stock == null) {
        messages.add('Материал «${paper.name}» не найден на складе.');
        continue;
      }
      final holders = await _paperReservationHolders(
        paper.id,
        excludeOrderId: order.id,
      );
      final reservedByOthers = holders.fold<double>(
        0,
        (sum, holder) => sum + holder.qty,
      );
      final available = stock - reservedByOthers;
      if (available >= requiredLength) continue;

      // Сотруднику нужны две цифры: сколько не хватает и сколько есть.
      // Разбор «на складе столько, из них столько забронировано такими-то
      // заказами» в карточку не помещался и обрезался многоточием — толку
      // от него не было.
      // Доступное может уйти в минус: склад обнулили, а брони прошлых
      // заказов остались. Показывать «-32» бессмысленно — для сотрудника это
      // просто ноль, и не хватает всей потребности целиком.
      final shownAvailable = available < 0 ? 0.0 : available;
      final shortage = requiredLength - shownAvailable;
      messages.add(
        shownAvailable <= 0
            ? 'Не хватает ${_qtyText(shortage)} м бумаги «${paper.name}»: '
                'на складе нет.'
            : 'Не хватает ${_qtyText(shortage)} м бумаги «${paper.name}»: '
                'доступно ${_qtyText(shownAvailable)} из '
                '${_qtyText(requiredLength)}.',
      );
    }
    return messages;
  }

  /// Количество для человека: без хвостовых нулей.
  ///
  /// `toStringAsFixed(2)` давал «4200.00» и «0.00» — в короткой строке это
  /// лишний шум, а именно эти строки сотрудник и читает на карточке.
  static String _qtyText(double value) {
    final rounded = (value * 100).round() / 100;
    if (rounded == rounded.roundToDouble()) {
      return rounded.toInt().toString();
    }
    return rounded
        .toStringAsFixed(2)
        .replaceFirst(RegExp(r'0+$'), '')
        .replaceFirst(RegExp(r'\.$'), '');
  }

  /// Кто держит резерв на этой бумаге, кроме самого заказа.
  Future<List<_PaperReservationHolder>> _paperReservationHolders(
    String? paperId,
    {String? excludeOrderId}
  ) async {
    final id = (paperId ?? '').trim();
    if (id.isEmpty) return const <_PaperReservationHolder>[];
    final rows = await _activePaperReservationsByPaper(id);
    final own = (excludeOrderId ?? '').trim();
    final result = <_PaperReservationHolder>[];
    for (final row in rows) {
      final orderId = (row['order_id'] ?? '').toString().trim();
      if (orderId.isEmpty || orderId == own) continue;
      final qty = _toDouble(row['qty']);
      if (qty <= 0) continue;
      result.add(_PaperReservationHolder(orderId: orderId, qty: qty));
    }
    return result;
  }

  /// Складской остаток без учёта резервов.
  Future<double?> _fetchMaterialStockQty(String? materialId) async {
    final id = (materialId ?? '').trim();
    if (id.isEmpty) return null;
    Future<double?> fetchQty(String table) async {
      try {
        final row = await _supabase
            .from(table)
            .select('quantity')
            .eq('id', id)
            .maybeSingle();
        if (row == null) return null;
        final value = row['quantity'];
        if (value is num) return value.toDouble();
        return double.tryParse('$value');
      } catch (e) {
        // «Строки нет» и «не смог прочитать» — разные вещи: первое значит, что
        // материал удалён со склада, второе не значит ничего.
        if (isTransientNetworkFailure(e)) {
          throw _StockCheckUnavailable('$table.quantity $id: $e');
        }
        return null;
      }
    }

    final materialQty = await fetchQty('materials');
    final paperQty = await fetchQty('papers');
    return materialQty ?? paperQty;
  }

  /// Доступный остаток бумаги = складской остаток − резервы ЧУЖИХ заказов.
  ///
  /// Собственный резерв заказа вычитать нельзя: сервер в
  /// `sync_order_paper_reservations` считает так же (`r.order_id <> v_order_id`),
  /// а клиент раньше вычитал все резервы подряд — и запущенный заказ не
  /// проходил проверку по своей же брони, показывая «доступно 0.00».
  Future<double?> _fetchMaterialQty(
    String? materialId, {
    String? excludeOrderId,
  }) async {
    final baseQty = await _fetchMaterialStockQty(materialId);
    if (baseQty == null) return null;

    try {
      final holders = await _paperReservationHolders(
        materialId,
        excludeOrderId: excludeOrderId,
      );
      if (holders.isEmpty) return baseQty;
      final reserved = holders.fold<double>(
        0,
        (sum, holder) => sum + holder.qty,
      );
      return baseQty - reserved;
    } on _StockCheckUnavailable {
      rethrow;
    } catch (e) {
      // Фолбэк рассчитан на отсутствующую таблицу резервов: тогда старый
      // расчёт верен. Обрыв связи под него маскироваться не должен — он даёт
      // ЗАВЫШЕННЫЙ остаток (резервы не вычтены) и поднимает заказ в
      // «Готов к запуску».
      if (isTransientNetworkFailure(e)) {
        throw _StockCheckUnavailable('order_paper_reservations $materialId: $e');
      }
      return baseQty;
    }
  }

  Future<List<Map<String, dynamic>>> _activePaperReservationsByPaper(
    String paperId,
  ) async {
    final normalizedId = paperId.trim();
    if (normalizedId.isEmpty) return const [];
    final reserveRows = await _supabase
        .from('order_paper_reservations')
        .select('order_id, qty')
        .eq('paper_id', normalizedId);
    if (reserveRows is! List || reserveRows.isEmpty) return const [];

    final rows = reserveRows
        .whereType<Map>()
        .map((raw) => Map<String, dynamic>.from(raw as Map))
        .toList(growable: false);
    final orderIds = rows
        .map((row) => (row['order_id'] ?? '').toString().trim())
        .where((id) => id.isNotEmpty)
        .toSet()
        .toList(growable: false);
    if (orderIds.isEmpty) return rows;

    final activeOrderIds = <String>{};
    final orderRows = await _supabase
        .from('orders')
        .select('id, status, shipped_at')
        .inFilter('id', orderIds);
    if (orderRows is List) {
      for (final raw in orderRows.whereType<Map>()) {
        final row = Map<String, dynamic>.from(raw as Map);
        final orderId = (row['id'] ?? '').toString().trim();
        if (orderId.isEmpty) continue;
        final status = (row['status'] ?? '').toString().toLowerCase().trim();
        final shippedAt = row['shipped_at'];
        final isClosed =
            status == 'completed' || status == 'shipped' || shippedAt != null;
        if (!isClosed) activeOrderIds.add(orderId);
      }
    }

    final staleOrderIds = orderIds
        .where((orderId) => !activeOrderIds.contains(orderId))
        .toList(growable: false);
    if (staleOrderIds.isNotEmpty) {
      // Жёсткая проверка: чистим "зависший" резерв для закрытых заказов.
      await _supabase
          .from('order_paper_reservations')
          .delete()
          .inFilter('order_id', staleOrderIds);
    }

    return rows
        .where((row) =>
            activeOrderIds.contains((row['order_id'] ?? '').toString().trim()))
        .toList(growable: false);
  }

  /// Сколько краски заказу НУЖНО — по составу заказа, а не по его броням.
  ///
  /// Источник — `order_paints`: там лежит то, что менеджер вписал в форму, и
  /// лежит всегда. Брони (`order_paint_reservations`) для этого не годятся:
  /// `sync_order_paint_reservations` при нехватке краски бросает исключение и
  /// откатывает всю транзакцию, а клиент ловит его и только показывает
  /// сообщение. То есть ровно в случае нехватки строк брони НЕТ — и проверка,
  /// которая их перебирала, находила пустой список и отвечала «краски хватает».
  /// Заказ с красной надписью «Недостаточно материала» в форме уходил в
  /// «Готов к запуску».
  ///
  /// Имя краски приводим к id так же, как это делает сервер:
  /// `lower(trim(description))`. Иначе клиент и сервер разошлись бы в том,
  /// какую именно краску считать выбранной.
  Future<List<_PaintRequirement>> _paintRequirementsForOrder(
    String orderId,
  ) async {
    final normalizedId = orderId.trim();
    if (normalizedId.isEmpty) return const <_PaintRequirement>[];
    try {
      final rows = await _supabase
          .from('order_paints')
          .select('name, qty_kg')
          .eq('order_id', normalizedId);
      if (rows is! List || rows.isEmpty) return const <_PaintRequirement>[];

      final wanted = <String, double>{};
      for (final raw in rows.whereType<Map>()) {
        final row = Map<String, dynamic>.from(raw);
        final name = (row['name'] ?? '').toString().trim();
        final qtyKg = _toDoubleNullable(row['qty_kg']);
        if (name.isEmpty || qtyKg == null || qtyKg <= 0) continue;
        final key = normalizePaintKey(name);
        wanted.update(key, (value) => value + qtyKg * 1000,
            ifAbsent: () => qtyKg * 1000);
      }
      if (wanted.isEmpty) return const <_PaintRequirement>[];

      // Тянем справочник целиком (две колонки на ~200 строк) и сопоставляем
      // локально в нижнем регистре — ровно как сервер в
      // `sync_order_paint_reservations`. Фильтр по списку имён на стороне базы
      // был бы регистрозависимым: «192d Красный» в заказе не нашёл бы «192D
      // Красный» на складе, и проверка молча решила бы, что краски нет.
      final stock = await _supabase.from('paints').select('id, description');
      final idByName = <String, String>{};
      final labelByName = <String, String>{};
      if (stock is List) {
        for (final raw in stock.whereType<Map>()) {
          final row = Map<String, dynamic>.from(raw);
          final id = (row['id'] ?? '').toString().trim();
          final description = (row['description'] ?? '').toString().trim();
          if (id.isEmpty || description.isEmpty) continue;
          final key = normalizePaintKey(description);
          idByName.putIfAbsent(key, () => id);
          labelByName.putIfAbsent(key, () => description);
        }
      }

      return wanted.entries
          .map(
            (entry) => _PaintRequirement(
              paintId: idByName[entry.key],
              name: labelByName[entry.key] ?? entry.key,
              grams: entry.value,
            ),
          )
          .toList(growable: false);
    } catch (e, st) {
      debugPrint('⚠️ не удалось прочитать краски заказа $orderId: $e\n$st');
      throw _StockCheckUnavailable('order_paints $orderId: $e');
    }
  }

  /// Доступный остаток краски = склад − НЕПОГАШЕННЫЕ брони ЧУЖИХ заказов.
  ///
  /// Собственная бронь заказа не вычитается — иначе заказ не проходит проверку
  /// по своим же граммам. Сервер в `sync_order_paint_reservations` считает так
  /// же (`r.order_id::text <> p_order_id`).
  ///
  /// «Непогашенная» — это `reserved_qty − used_qty − released_qty`, ровно как на
  /// сервере. Клиент раньше брал голый `reserved_qty`, и израсходованная краска
  /// считалась дважды: граммы уже ушли со склада через `paints_writeoffs`, а её
  /// бронь продолжала занимать тот же остаток. По «300i Синий» это давало склад
  /// 3800 г при броне 17000 г, из которых 18500 г израсходовано, — доступно
  /// −13200 г. Заказ на такую краску не выходил из «Ожидания материалов»
  /// никогда: чтобы дойти хотя бы до нуля, пришлось бы завезти 13 200 г сверх
  /// собственной потребности.
  Future<double?> _fetchPaintAvailableQty(
    String paintId, {
    String? excludeOrderId,
  }) async {
    final id = paintId.trim();
    if (id.isEmpty) return null;
    final ownOrderId = (excludeOrderId ?? '').trim();
    try {
      final row = await _supabase
          .from('paints')
          .select('quantity')
          .eq('id', id)
          .maybeSingle();
      if (row == null) return null;
      final baseQty = _toDouble(row['quantity']);

      // Фильтруем только активные (незакрытые) заказы, чтобы старые резервы
      // завершённых заказов не занижали доступный остаток краски.
      final allReserveRows = await _supabase
          .from('order_paint_reservations')
          .select('order_id, reserved_qty, used_qty, released_qty')
          .eq('paint_id', id);
      if (allReserveRows is! List || allReserveRows.isEmpty) {
        return availablePaintGrams(stockGrams: baseQty);
      }

      final reserveList = allReserveRows
          .whereType<Map>()
          .map((raw) => Map<String, dynamic>.from(raw as Map))
          .toList(growable: false);

      final orderIds = reserveList
          .map((r) => (r['order_id'] ?? '').toString().trim())
          .where((oid) => oid.isNotEmpty)
          .toSet()
          .toList(growable: false);

      final activeOrderIds = <String>{};
      if (orderIds.isNotEmpty) {
        final orderRows = await _supabase
            .from('orders')
            .select('id, status, shipped_at')
            .inFilter('id', orderIds);
        if (orderRows is List) {
          for (final raw in orderRows.whereType<Map>()) {
            final r = Map<String, dynamic>.from(raw as Map);
            final oid = (r['id'] ?? '').toString().trim();
            if (oid.isEmpty) continue;
            final status = (r['status'] ?? '').toString().toLowerCase().trim();
            final shippedAt = r['shipped_at'];
            final isClosed = status == 'completed' ||
                status == 'shipped' ||
                shippedAt != null;
            if (!isClosed) activeOrderIds.add(oid);
          }
        }
        // Удаляем зависшие резервы закрытых заказов.
        final staleIds = orderIds
            .where((oid) => !activeOrderIds.contains(oid))
            .toList(growable: false);
        if (staleIds.isNotEmpty) {
          try {
            await _supabase
                .from('order_paint_reservations')
                .delete()
                .inFilter('order_id', staleIds);
          } catch (_) {}
        }
      }

      double reservedQty = 0;
      for (final r in reserveList) {
        final oid = (r['order_id'] ?? '').toString().trim();
        if (!activeOrderIds.contains(oid)) continue;
        if (ownOrderId.isNotEmpty && oid == ownOrderId) continue;
        reservedQty += outstandingPaintReservation(
          reservedQty: _toDouble(r['reserved_qty']),
          usedQty: _toDouble(r['used_qty']),
          releasedQty: _toDouble(r['released_qty']),
        );
      }
      // Неприкасаемый запас снимается с доступного остатка ОДИН раз на
      // краску, а не по 5 кг с каждого заказа: чужие брони уже вычтены выше.
      return availablePaintGrams(
        stockGrams: baseQty,
        reservedByOthersGrams: reservedQty,
      );
    } on _StockCheckUnavailable {
      rethrow;
    } catch (e) {
      throw _StockCheckUnavailable('paints.quantity $id: $e');
    }
  }

  /// Складской остаток краски без вычета брони и запаса — для сообщений о
  /// закупке: снабженцу важно, сколько краски физически лежит.
  Future<double?> _fetchPaintStockQty(String paintId) async {
    final id = paintId.trim();
    if (id.isEmpty) return null;
    try {
      final row = await _supabase
          .from('paints')
          .select('quantity')
          .eq('id', id)
          .maybeSingle();
      if (row == null) return null;
      return _toDouble(row['quantity']);
    } catch (e) {
      throw _StockCheckUnavailable('paints.quantity $id: $e');
    }
  }

  /// Заказ с формой, в котором не выбрана ни одна краска.
  ///
  /// Правило — [paintSelectionMissing]; здесь только чтение состава.
  Future<bool> _paintSelectionMissing(OrderModel order) async {
    // Заказ без формы читать не за чем: ответ известен заранее, а метод
    // зовётся по КАЖДОМУ заказу в проходе пересчёта. assert стережёт, чтобы
    // короткий путь не разошёлся с самим правилом.
    if (!order.hasForm) {
      assert(!paintSelectionMissing(hasForm: false, paintLineCount: 0));
      return false;
    }
    // Старые заказы держат краски только текстом в product.parameters, строк
    // в order_paints у них нет вовсе. Посчитай их «без краски» — и всё, что
    // заведено до появления таблицы, разом провалилось бы в «Ожидание
    // материалов». Заодно это короткий путь для обычного заказа: у него та же
    // строка «Краска: …» есть, и лишнего чтения не будет.
    if (_orderHasPaints(order)) return false;
    return paintSelectionMissing(
      hasForm: true,
      paintLineCount: await _paintLineCountForOrder(order.id),
    );
  }

  /// Сколько красок вписано в заказ — независимо от граммовки.
  ///
  /// Отличать «краску не выбрали вовсе» от «выбрали, но без граммов» обязано
  /// именно это чтение: [_paintRequirementsForOrder] отбрасывает строки без
  /// количества, и оба случая выглядели бы в нём одинаково пустыми — хотя
  /// ведут заказ в разные статусы (ожидание материалов против черновика).
  Future<int> _paintLineCountForOrder(String orderId) async {
    final normalizedId = orderId.trim();
    if (normalizedId.isEmpty) return 0;
    try {
      final rows = await _supabase
          .from('order_paints')
          .select('name')
          .eq('order_id', normalizedId);
      if (rows is! List) return 0;
      return rows
          .whereType<Map>()
          .where((row) => (row['name'] ?? '').toString().trim().isNotEmpty)
          .length;
    } catch (e) {
      // Сбой чтения — не вердикт «красок нет»: иначе сетевой обрыв уронил бы
      // обеспеченный заказ в «Ожидание материалов».
      throw _StockCheckUnavailable('order_paints names $normalizedId: $e');
    }
  }

  Future<bool> _hasEnoughPaintForLaunch(OrderModel order) async {
    for (final need in await _paintRequirementsForOrder(order.id)) {
      // Краски нет в справочнике — обеспечить заказ нечем.
      if (need.paintId == null) return false;
      final availableQty = await _fetchPaintAvailableQty(
        need.paintId!,
        excludeOrderId: order.id,
      );
      // Раньше здесь стояло `availableQty < 0`: нехватка краски не
      // останавливала заказ вовсе, пока остаток не уходил в минус. Теперь
      // краска считается так же, как бумага — по потребности.
      if (availableQty == null) return false;
      if (availableQty + kReservationEpsilon < need.grams) return false;
    }
    return true;
  }

  Future<List<String>> _paintShortages(OrderModel order) async {
    final messages = <String>[];
    for (final need in await _paintRequirementsForOrder(order.id)) {
      final name = need.name;
      final requiredQty = need.grams;
      final paintId = need.paintId;
      if (paintId == null) {
        // Краски нет в справочнике вовсе — её нужно завести и закупить
        // потребность заказа плюс неприкасаемый запас.
        messages.add(missingPaintShortageMessage(
          paintName: name,
          neededGrams: requiredQty,
        ));
        continue;
      }
      final availableQty = await _fetchPaintAvailableQty(
        paintId,
        excludeOrderId: order.id,
      );
      if (availableQty == null) {
        messages.add('Краска «$name» не найдена на складе.');
        continue;
      }
      if (availableQty + kReservationEpsilon >= requiredQty) continue;

      final shownAvailable = availableQty < 0 ? 0.0 : availableQty;
      final stockQty = await _fetchPaintStockQty(paintId) ?? 0;
      final toPurchase = requiredQty - shownAvailable;

      // Про запас говорим отдельной фразой: без неё сообщение «доступно 0 из
      // 3000» при складе в 4 кг выглядит враньём — краска-то на складе видна.
      final reserveNote = needsReplenishment(stockQty)
          ? ' Обязательный запас просел: нужно пополнить '
              '${_qtyText(replenishmentGrams(stockQty))} г.'
          : '';
      messages.add(
        shownAvailable <= 0
            ? 'Не хватает ${_qtyText(toPurchase)} г краски «$name»: '
                'свободного остатка нет '
                '(на складе ${_qtyText(stockQty)} г, из них '
                '${_qtyText(kUntouchablePaintGrams)} г неприкасаемы).$reserveNote'
            : 'Не хватает ${_qtyText(toPurchase)} г краски «$name»: '
                'доступно ${_qtyText(shownAvailable)} из '
                '${_qtyText(requiredQty)}.$reserveNote',
      );
    }
    return messages;
  }

  Future<bool> _hasEnoughMaterialForLaunch(OrderModel order) async {
    final papers = _resolveOrderPapers(order);
    // Заказ с формой, но без краски, обеспеченным не считается: печатать
    // нечем. Проверка идёт до всех прочих — краски у него нет вовсе, и
    // остальным проверкам нечего перебирать.
    if (await _paintSelectionMissing(order)) return false;
    if (!await _hasEnoughPaintForLaunch(order)) return false;
    if (papers.isEmpty) return true;
    for (final paper in papers) {
      final String materialId = (paper.id ?? '').trim();
      final double requiredLength = _requiredPaperReserveQty(order, paper);
      if (materialId.isEmpty || requiredLength <= 0) continue;
      final qty = await _fetchMaterialQty(
        materialId,
        excludeOrderId: order.id,
      );
      if (qty == null || qty < requiredLength) return false;
    }
    return true;
  }

  @override
  void dispose() {
    _disposed = true;
    StockAvailabilityRecheckCoordinator.instance.unregister(this);
    RealtimeSyncService.instance.unregisterOwner(this);
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
      final normalizedOrder = _applyOrderFormRulesForPersist(
        order,
        hasPaints: _orderHasPaints(order),
      );
      final inserted = await _supabase
          .from('orders')
          .insert(normalizedOrder.toMap())
          .select()
          .single() as Map<String, dynamic>;

      final newOrder = OrderModel.fromMap(inserted);
      final idx = _orders.indexWhere((o) => o.id == order.id);
      if (idx != -1) {
        _orders[idx] = newOrder;
      } else {
        _orders.add(newOrder);
      }
      _dedupeOrdersById();
      notifyListeners();

      // Log creation (best effort)
      await _logOrderEvent(
        newOrder.id,
        'Создание',
        describeOrderCreation(newOrder),
      );
    } catch (e, st) {
      // Rollback optimistic change
      _orders.removeWhere((o) => o.id == order.id);
      notifyListeners();
      debugPrint('❌ addOrder error: $e\n$st');
    }
  }

  bool _orderHasPaints(OrderModel order) {
    final params = order.product.parameters.toLowerCase();
    return params.contains('краска:');
  }

  OrderModel _applyOrderFormRulesForPersist(OrderModel order,
      {required bool hasPaints}) {
    final result = applyOrderFormRules(
      draft: order,
      hasPaints: hasPaints,
      userManuallySelectedFormType: order.isOldForm || order.newFormNo != null,
    );
    return order.copyWith(
      hasForm: result.hasForm,
      isOldForm: result.isOldForm,
      newFormNo: result.newFormNo,
      formSeries: result.formSeries,
      formCode: result.formCode,
    );
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
    List<MaterialModel> paperMaterials = const [],
    double makeready = 0,
    double val = 0,
    String? pdfUrl,
    String? stageTemplateId,
    bool hasForm = false,
    String? formId,
    bool isOldForm = false,
    bool contractSigned = false,
    bool paymentDone = false,
    String comments = '',
    String status = 'draft',
    String queueBuildStatus = QueueBuildStatus.notBuilt,
    String? selectedVStage,
    String? selectedPStage,
    Map<String, dynamic>? queueSignature,
    String? restartedFromOrderId,
    String? restartRootOrderId,
    int restartGeneration = 0,
    String? assignmentId,
    bool assignmentCreated = false,
    String? productTypeId,
    List<OrderOptionSelection>? extraOptions,
  }) async {
    await _ensureAuthed();

    // Local temp id for optimistic UI
    final tempLocalId = 'local-${DateTime.now().microsecondsSinceEpoch}';
    final localOrder = _applyOrderFormRulesForPersist(
      OrderModel(
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
        paperMaterials: paperMaterials,
        makeready: makeready,
        val: val,
        pdfUrl: pdfUrl,
        stageTemplateId: stageTemplateId,
        hasForm: hasForm,
        formId: formId,
        isOldForm: isOldForm,
        contractSigned: contractSigned,
        paymentDone: paymentDone,
        comments: comments,
        status: status,
        queueBuildStatus: queueBuildStatus,
        selectedVStage: selectedVStage,
        selectedPStage: selectedPStage,
        queueSignature: queueSignature,
        restartedFromOrderId: restartedFromOrderId,
        restartRootOrderId: restartRootOrderId,
        restartGeneration: restartGeneration,
        assignmentId: assignmentId,
        assignmentCreated: assignmentCreated,
        productTypeId: productTypeId,
        extraOptions: extraOptions,
      ),
      hasPaints: product.parameters.toLowerCase().contains('краска:'),
    );

    // Optimistic add
    _orders.add(localOrder);
    notifyListeners();

    try {
      final inserted = await _supabase
          .from('orders')
          .insert(localOrder.toMap(canonicalFormReference: true)..remove('id')) // let DB generate id
          .select()
          .single() as Map<String, dynamic>;

      final created = OrderModel.fromMap(inserted);

      // Replace optimistic row
      final idx = _orders.indexWhere((o) => o.id == tempLocalId);
      if (idx != -1) _orders[idx] = created;
      _dedupeOrdersById();
      notifyListeners();

      // Бронь под новый заказ не ставим: бумагу занимает только запуск.
      await _applyImmediateMaterialAvailabilityState(created);

      // Log creation (best effort)
      await _logOrderEvent(
        created.id,
        'Создание',
        describeOrderCreation(created),
      );
      return created;
    } catch (e, st) {
      // Rollback
      _orders.removeWhere((o) => o.id == tempLocalId);
      notifyListeners();
      debugPrint('❌ createOrder error: $e\n$st');
      return null;
    }
  }

  void _dedupeOrdersById() {
    final seen = <String>{};
    _orders.removeWhere((order) {
      final id = order.id.trim();
      if (id.isEmpty) return false;
      if (seen.contains(id)) {
        return true;
      }
      seen.add(id);
      return false;
    });
  }

  /// Обновляет существующий заказ по ID (оптимистично).
  Future<void> updateOrder(OrderModel updated) async {
    await _ensureAuthed();

    final index = _orders.indexWhere((o) => o.id == updated.id);
    if (index == -1) throw StateError('Заказ не найден. Обновите список заказов.');

    final prev = _orders[index];
    _orders[index] = updated; // optimistic
    notifyListeners();

    try {
      final bool paperChanged = _hasPaperCompositionChanged(
        previous: prev,
        updated: updated,
      );
      // Причина изменения бумаги валидируется только в рабочем пространстве.
      // В модулях оформления/редактирования заказа не блокируем сохранение.
      final normalizedUpdated = _applyOrderFormRulesForPersist(
        updated,
        hasPaints: _orderHasPaints(updated),
      );
      await _supabase
          .from('orders')
          .update(normalizedUpdated.toMap(includeNulls: true, canonicalFormReference: true)
            ..remove('id')
            // These fields can change on the shop floor while a manager edits.
            // A form snapshot must never write their old values back.
            ..remove('actual_qty')
            ..remove('shipped_at')
            ..remove('shipped_by')
            ..remove('shipped_qty')
            ..remove('completed_at')
            ..remove('paper_written_off_at')
            ..remove('promised_at'))
          .eq('id', updated.id);
      // Бумагу занимает обеспеченный заказ — с «Готов к запуску» и дальше.
      // Правило одно на весь модуль, см. [holdsPaperReservation].
      //
      // Раньше здесь стояло «только запущенный». Из-за этого правка состава
      // бумаги у заказа в готовности не доходила до склада, а сам переход в
      // готовность не занимал ни метра. Переход между статусами доводит
      // _applyImmediateMaterialAvailabilityState — оно вызывается следующим и
      // знает уже пересчитанный статус.
      if (holdsPaperReservation(
        assignmentCreated: updated.assignmentCreated,
        status: updated.statusEnum,
      )) {
        final reserveError = await _syncPaperReservationsForOrder(updated);
        if (reserveError != null) {
          throw Exception(reserveError);
        }
      }
      await _applyImmediateMaterialAvailabilityState(updated);
      final paperHistory = _describePaperChanges(
        previous: prev,
        updated: updated,
        reason: updated.comments,
      );
      if (paperHistory != null) {
        await _logOrderEvent(updated.id, 'Изменение бумаги', paperHistory);
      }

      // Опции разрешено править и в уже запущенном заказе, поэтому смена
      // значения обязана оставлять след. Оба снимка проверяются на null:
      // null — это «экран про опции ничего не знал», и принять его за пустой
      // список означало бы записать в историю выдуманное «Ламинация: Да → —».
      final prevOptions = prev.extraOptions;
      final nextOptions = updated.extraOptions;
      if (prevOptions != null && nextOptions != null) {
        final optionsHistory = describeOrderExtraOptionChanges(
          before: prevOptions,
          after: nextOptions,
        );
        if (optionsHistory != null) {
          await _logOrderEvent(updated.id, 'Изменение опций', optionsHistory);
        }
      }

      // Поимённый список правок вместо прежнего «Изменён заказ».
      //
      // И событие не пишется вовсе, когда ничего не изменилось: updateOrder
      // зовётся на каждом сохранении формы, в том числе когда сотрудник просто
      // открыл заказ и закрыл. Такие пустые записи копились сотнями и
      // хоронили под собой настоящие правки.
      final fieldChanges = describeOrderFieldChanges(
        diffOrderFields(before: prev, after: normalizedUpdated),
      );
      if (fieldChanges != null) {
        await _logOrderEvent(updated.id, 'Изменение заказа', fieldChanges);
      }
    } catch (e, st) {
      _orders[index] = prev; // rollback
      notifyListeners();
      debugPrint('❌ updateOrder error: $e\n$st');
      rethrow;
    }
  }

  /// Обновляет состав бумаги из рабочего пространства производства.
  ///
  /// Бизнес-правила:
  /// - причина изменения обязательна;
  /// - количество типов бумаги не ограничено искусственным лимитом;
  /// - при запущенном заказе пересчитываем только резерв (без списания).
  Future<String?> updateOrderPapersFromWorkspace({
    required String orderId,
    required List<MaterialModel> paperMaterials,
    required String reason,
    double? lengthL,
    double? width,
    int? quantity,
    double? widthB,
    String? blQuantity,
  }) async {
    await _ensureAuthed();

    final trimmedReason = reason.trim();
    if (trimmedReason.isEmpty) {
      return 'Укажите причину изменения бумаги.';
    }

    final prepared = <MaterialModel>[];
    for (final paper in paperMaterials) {
      final normalizedPaper = await _normalizePaperForReservation(paper);
      if ((normalizedPaper.id ?? '').trim().isEmpty) {
        continue;
      }
      prepared.add(normalizedPaper);
    }
    if (prepared.isEmpty) {
      return 'Добавьте хотя бы один тип бумаги.';
    }
    final index = _orders.indexWhere((o) => o.id == orderId);
    if (index == -1) {
      return 'Заказ не найден в локальном кеше.';
    }
    final prev = _orders[index];
    final normalizedLength = lengthL != null && lengthL > 0 ? lengthL : null;
    final normalizedWidth = width != null && width > 0 ? width : null;
    final normalizedQuantity =
        quantity != null && quantity > 0 ? quantity : null;
    final normalizedWidthB = widthB != null && widthB > 0 ? widthB : null;
    final normalizedBlQuantity = (blQuantity ?? '').trim();
    final nextProduct = ProductModel.fromMap(prev.product.toMap());
    if (normalizedLength != null) {
      nextProduct.length = normalizedLength;
    }
    if (normalizedWidth != null) {
      nextProduct.width = normalizedWidth;
    }
    if (normalizedQuantity != null) {
      nextProduct.quantity = normalizedQuantity;
    }
    nextProduct.widthB = normalizedWidthB;
    nextProduct.blQuantity =
        normalizedBlQuantity.isEmpty ? null : normalizedBlQuantity;
    final updated = prev.copyWith(
      product: nextProduct,
      paperMaterials: prepared,
      material: prepared.first,
      comments: prev.comments,
    );

    if (!_hasPaperCompositionChanged(previous: prev, updated: updated)) {
      return null;
    }

    _orders[index] = updated; // optimistic
    notifyListeners();

    try {
      await _supabase
          .from('orders')
          .update(updated.toMap()..remove('id'))
          .eq('id', updated.id);
      // Ключевое бизнес-правило рабочего пространства: при правке бумаги
      // резерв должен пересчитываться всегда, чтобы детали ПЗ и склад
      // оставались синхронизированы даже если статус/флаг запуска устарели.
      final reserveError = await _syncPaperReservationsForOrder(updated);
      if (reserveError != null) {
        throw Exception(reserveError);
      }
      await _applyImmediateMaterialAvailabilityState(updated);
      final paperHistory = _describePaperChanges(
        previous: prev,
        updated: updated,
        reason: trimmedReason,
      );
      if (paperHistory != null) {
        await _logOrderEvent(updated.id, 'Изменение бумаги', paperHistory);
      }
      await _logOrderEvent(
        updated.id,
        'Обновление',
        'Состав бумаги обновлен из рабочего пространства',
      );
      return null;
    } catch (e, st) {
      _orders[index] = prev; // rollback
      notifyListeners();
      debugPrint('❌ updateOrderPapersFromWorkspace error: $e\n$st');
      return 'Не удалось сохранить изменения бумаги: $e';
    }
  }

  /// Запускает заказ в производство:
  /// - создаёт задачи по сохранённой очереди этапов;
  /// - переводит заказ в статус inWork.
  /// Возвращает `null` при успехе или текст ошибки.
  /// Заказы, запуск которых сейчас выполняется. Ключ — id заказа.
  ///
  /// Экран заказов гасит свою кнопку на время запроса, но этого мало: запуск
  /// зовут и из других мест, а один и тот же заказ могут запустить с двух
  /// устройств. `OrderQueueSyncService` создаёт задачи по схеме
  /// «прочитал существующие → вставил недостающие», без транзакции и без
  /// уникального ключа в базе. Два запуска, разошедшиеся на сотню
  /// миллисекунд, оба видят «задач нет» и оба их создают — заказ двоится в
  /// списке рабочего места. В базе таких пар накопилось 22, и все ровно по
  /// две: ЗК-2026.08.31-5 (Флексопечать, Автомат маленький, Упаковка) создан
  /// дважды с разницей в 150 мс.
  final Set<String> _launchInFlight = <String>{};

  Future<String?> launchOrder(OrderModel order) async {
    await _ensureAuthed();
    if (order.assignmentCreated) {
      return null;
    }
    final launchKey = order.id.trim();
    if (launchKey.isNotEmpty && !_launchInFlight.add(launchKey)) {
      return 'Запуск заказа уже выполняется, подождите.';
    }
    try {
      return await _launchOrderGuarded(order);
    } finally {
      _launchInFlight.remove(launchKey);
    }
  }

  Future<String?> _launchOrderGuarded(OrderModel order) async {
    OrderModel launchOrder = order;
    try {
      final persisted = await _supabase
          .from('orders')
          .select()
          .eq('id', order.id)
          .maybeSingle();
      if (persisted != null) {
        launchOrder = OrderModel.fromMap(
          Map<String, dynamic>.from(persisted),
        );
      }
    } catch (_) {
      // If the row cannot be reloaded, keep checking the provided model below.
    }
    if (QueueBuildStatus.normalize(launchOrder.queueBuildStatus) !=
        QueueBuildStatus.built) {
      return QueueBuildStatus.normalize(launchOrder.queueBuildStatus) ==
              QueueBuildStatus.outdated
          ? 'Заказ нельзя запустить: очередь изменилась, нажмите «Собрать очередь» и сохраните заказ.'
          : 'Заказ нельзя запустить: сначала соберите очередь этапов и сохраните заказ.';
    }
    if (launchOrder.assignmentCreated) {
      return null;
    }
    if (launchOrder.statusEnum != OrderStatus.ready_to_start) {
      return 'Заказ нельзя запустить: статус должен быть ready_to_start.';
    }
    if (!await _hasEnoughMaterialForLaunch(launchOrder)) {
      final message = await _materialShortageMessage(launchOrder);
      await _supabase.from('orders').update({
        'status': OrderStatus.waiting_materials.name,
        'has_material_shortage': true,
        'material_shortage_message': message,
      }).eq('id', launchOrder.id);
      await refresh();
      return message.isEmpty
          ? 'Недостаточно материала для запуска заказа.'
          : message;
    }

    try {
      try {
        await OrderQueueService(_supabase)
            .createTasksFromSavedQueue(launchOrder.id);
      } on OrderQueueSyncSchemaOutdatedException catch (e) {
        return e.message;
      } on StateError catch (e) {
        return 'Не удалось запустить заказ: ${e.message}';
      }

      // Бизнес-правило резерва: до перевода в in_production
      // пытаемся атомарно зафиксировать резерв бумаги.
      final reserveError = await _syncPaperReservationsForOrder(
        launchOrder.copyWith(
          status: OrderStatus.in_production.name,
          assignmentCreated: true,
        ),
      );
      if (reserveError != null) {
        // Если резерв не зафиксирован, убираем только будущие задачи, не трогая
        // уже начатые/завершённые записи повторного запуска.
        await _supabase
            .from('tasks')
            .delete()
            .eq('order_id', launchOrder.id)
            .inFilter('status', ['waiting', 'pending', 'planned']);
        RealtimeSyncService.instance.invalidateLocal(RealtimeResource.tasks);
        return reserveError;
      }

      final String nextAssignmentId =
          (launchOrder.assignmentId ?? '').trim().isNotEmpty
              ? launchOrder.assignmentId!.trim()
              : generateAssignmentId();

      await _supabase.from('orders').update({
        'status': OrderStatus.in_production.name,
        'has_material_shortage': false,
        'material_shortage_message': '',
        'assignment_created': true,
        'assignment_id': nextAssignmentId,
      }).eq('id', launchOrder.id);

      final index = _orders.indexWhere((o) => o.id == launchOrder.id);
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

      await _logOrderEvent(
        launchOrder.id,
        'Запуск',
        'Заказ запущен в производство. Бумага переведена в резерв',
      );
      // Задания заказа создаёт этот метод, а живут они в TaskProvider:
      // без сигнала рабочее пространство на этом же устройстве ждало
      // эха realtime и показывало пустую очередь.
      RealtimeSyncService.instance.invalidateLocal(RealtimeResource.tasks);
      return null;
    } on OrderQueueSyncSchemaOutdatedException catch (e) {
      return e.message;
    } catch (e, st) {
      debugPrint('❌ launchOrder error: $e\n$st');
      return 'Не удалось запустить заказ: $e';
    }
  }

  /// Удаляет заказ по идентификатору (оптимистично).
  ///
  /// Возвращает null при успехе и текст ошибки, если удалить не удалось:
  /// раньше сбой молча откатывался, и заказ «мигал» — исчезал из списка и тут
  /// же возвращался, не объясняя почему.
  Future<String?> deleteOrder(String id) async {
    await _ensureAuthed();

    final index = _orders.indexWhere((o) => o.id == id);
    if (index == -1) return null;

    final removed = _orders.removeAt(index);
    notifyListeners();

    try {
      final assignmentId = (removed.assignmentId ?? '').trim();
      final relatedOrderIds = <String>{
        id.trim(),
        if (assignmentId.isNotEmpty) assignmentId,
      }..removeWhere((value) => value.isEmpty);
      final dbOrderRefs =
          relatedOrderIds.where(_looksLikeUuid).toList(growable: false);

      // Фикс: логируем удаление до фактического удаления заказа, иначе
      // вставка в order_events ломается по FK order_events_order_id_fkey.
      await _logOrderEvent(id, 'Удаление', 'Удалён заказ');

      // Важно: удаляем связанные сущности синхронно, чтобы заказ не "висел"
      // в модуле производственных заданий и рабочем пространстве.
      // Если этап уже запущен, сначала принудительно завершаем его, затем удаляем,
      // чтобы в очереди не оставались "висящие" назначения.
      for (final orderRef in dbOrderRefs) {
        try {
          await _supabase
              .from('tasks')
              .update({
                'status': 'done',
                'completed_at': DateTime.now().toUtc().toIso8601String(),
              })
              .eq('order_id', orderRef)
              .neq('status', 'done');
        } catch (_) {
          // На старых схемах может отсутствовать completed_at.
          await _supabase
              .from('tasks')
              .update({'status': 'done'})
              .eq('order_id', orderRef)
              .neq('status', 'done');
        }
        await _supabase.from('tasks').delete().eq('order_id', orderRef);
      }
      await _cleanupProductionQueueState(relatedOrderIds);
      // Бизнес-правило: удаление заказа освобождает весь резерв бумаги.
      // Резервы возвращаем ДО удаления самого заказа: строки резерва уйдут
      // каскадом, и после удаления возвращать на склад было бы уже нечего.
      await _releasePaperReservations(orderId: id);
      await _releasePaintReservations(orderId: id);
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

      // Краски, файлы и резервы заказа снимает каскад ON DELETE CASCADE —
      // и это единственный способ удалить их без ложного срабатывания
      // guard_carryover_paint_removal. Тот триггер пропускает удаление, только
      // если заказа в этой же транзакции уже нет; отдельный запрос
      // «delete order_paints» его условию не удовлетворял, и заказ с любой
      // переходящей краской не удалялся вовсе.
      final deleted =
          await _supabase.from('orders').delete().eq('id', id).select('id');
      if (deleted.isEmpty) {
        // Пустой ответ на DELETE — это не обязательно успех: так же выглядит
        // отказ политики RLS. Проверяем, что строки действительно нет.
        final stillThere = await _supabase
            .from('orders')
            .select('id')
            .eq('id', id)
            .maybeSingle();
        if (stillThere != null) {
          throw StateError(
            'база отклонила удаление строки заказа (нет прав на удаление)',
          );
        }
      }
      return null;
    } catch (e, st) {
      // rollback
      _orders.insert(index, removed);
      notifyListeners();
      debugPrint('❌ deleteOrder error: $e\n$st');
      return 'Не удалось удалить заказ: ${_describeDeleteError(e)}';
    }
  }

  /// Достаёт из ошибки Supabase текст, который имеет смысл показать человеку.
  String _describeDeleteError(Object error) {
    if (error is PostgrestException) {
      final message = error.message.trim();
      if (message.isNotEmpty) return message;
      final details = (error.details ?? '').toString().trim();
      if (details.isNotEmpty) return details;
    }
    if (error is StateError) return error.message;
    return error.toString();
  }

  bool _looksLikeUuid(String value) {
    final normalized = value.trim();
    if (normalized.isEmpty) return false;
    final uuidPattern = RegExp(
      r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[1-5][0-9a-fA-F]{3}-[89abAB][0-9a-fA-F]{3}-[0-9a-fA-F]{12}$',
    );
    return uuidPattern.hasMatch(normalized);
  }

  Future<void> _cleanupProductionQueueState(Set<String> removedOrderIds) async {
    if (removedOrderIds.isEmpty) return;

    try {
      try {
        await _supabase
            .from('workplace_queue_positions')
            .delete()
            .inFilter('order_id', removedOrderIds.toList(growable: false));
      } catch (_) {
        // Таблица появляется только после миграции очередей рабочих мест.
      }

      final rows = await _supabase
          .from('production_queue_state')
          .select('group_id, order_sequence, hidden_order_ids');
      if (rows is! List) return;

      for (final row in rows.whereType<Map>()) {
        final map = Map<String, dynamic>.from(row as Map);
        final groupId = (map['group_id'] ?? '').toString();
        final originalSequence = (map['order_sequence'] as List? ?? const [])
            .map((e) => e?.toString() ?? '')
            .toList(growable: false);
        final originalHidden = (map['hidden_order_ids'] as List? ?? const [])
            .map((e) => e?.toString() ?? '')
            .toList(growable: false);

        final nextSequence = originalSequence
            .where((value) => !removedOrderIds.contains(value.trim()))
            .toList(growable: false);
        final nextHidden = originalHidden
            .where((value) => !removedOrderIds.contains(value.trim()))
            .toList(growable: false);

        final changed = nextSequence.length != originalSequence.length ||
            nextHidden.length != originalHidden.length;
        if (!changed) continue;

        await _supabase.from('production_queue_state').upsert({
          'group_id': groupId,
          'order_sequence': nextSequence,
          'hidden_order_ids': nextHidden,
          'updated_at': DateTime.now().toUtc().toIso8601String(),
        });
      }
    } catch (e, st) {
      debugPrint('⚠️ cleanup production_queue_state failed: $e\n$st');
    }
  }

  /// Назначает срок завершения, обещанный производством.
  ///
  /// `null` снимает обещание — заказ возвращается к сроку заказчика.
  ///
  /// Правка доступна ТОЛЬКО из МУПЗ: там сотрудник видит очередь целиком и
  /// понимает, когда действительно закончит. Показывается новый срок везде —
  /// в списке заказов, в архиве, в карточке, — но менять его в форме заказа
  /// нельзя: там живёт договорённость с заказчиком, и смешивать их значило бы
  /// потерять сам факт сдвига.
  Future<void> setOrderPromisedDate(
    OrderModel order,
    DateTime? promisedAt,
  ) async {
    await _ensureAuthed();
    final index = _orders.indexWhere((o) => o.id == order.id);
    final previous = index == -1 ? order : _orders[index];
    // Снимок ДО правки: ниже снятие срока обнуляет поле прямо в этом объекте
    // (copyWith не умеет вернуть значение к null), и история прочитала бы уже
    // стёртое «не назначен → не назначен».
    final DateTime? previousPromised = previous.promisedAt;
    final DateTime? previousDue = previous.dueDate;
    if (previousPromised == promisedAt) return;

    try {
      await _supabase.from('orders').update({
        'promised_at': promisedAt?.toUtc().toIso8601String(),
      }).eq('id', order.id);
    } catch (e) {
      debugPrint('❌ setOrderPromisedDate error: $e');
      rethrow;
    }

    if (index != -1) {
      // copyWith не умеет вернуть поле к null — снятие срока собираем явно.
      _orders[index] = promisedAt == null
          ? (previous..promisedAt = null)
          : previous.copyWith(promisedAt: promisedAt);
      notifyListeners();
    }

    await _logOrderEvent(
      order.id,
      'Срок завершения',
      describePromisedDateChange(
        before: previousPromised,
        after: promisedAt,
        dueDate: previousDue,
      ),
    );
  }

  /// Партии отгрузки заказа, старые сверху.
  ///
  /// Пустой список — либо не отгружали, либо таблицы ещё нет: миграция может
  /// не доехать, и тогда правильный ответ «отгрузок не знаем», а не падение
  /// экрана заказов.
  Future<List<OrderShipment>> fetchOrderShipments(String orderId) async {
    if (orderId.trim().isEmpty || orderId.startsWith('local-')) {
      return const <OrderShipment>[];
    }
    try {
      final rows = await _supabase
          .from('order_shipments')
          .select('id, qty, shipped_at, shipped_by, has_document, note')
          .eq('order_id', orderId)
          .order('shipped_at');
      if (rows is! List) return const <OrderShipment>[];
      return <OrderShipment>[
        for (final raw in rows.whereType<Map>())
          if (OrderShipment.tryFromMap(Map<String, dynamic>.from(raw))
              case final shipment?)
            shipment,
      ];
    } catch (e) {
      debugPrint('⚠️ не удалось прочитать отгрузки заказа $orderId: $e');
      return const <OrderShipment>[];
    }
  }

  /// Переключает признак документа у партии отгрузки.
  ///
  /// Отдельным методом, а не полем формы: галочку ставят задним числом, когда
  /// бумаги наконец пришли, и каждое переключение обязано оставить след в
  /// истории — по этому признаку ищут партии без документов.
  Future<void> setShipmentDocument({
    required String orderId,
    required OrderShipment shipment,
    required bool hasDocument,
  }) async {
    await _ensureAuthed();
    await _supabase
        .from('order_shipments')
        .update({'has_document': hasDocument}).eq('id', shipment.id);
    await _logOrderEvent(
      orderId,
      'Отгрузка',
      describeDocumentToggle(shipment: shipment, hasDocument: hasDocument),
    );
    notifyListeners();
  }

  Future<void> shipOrder(
    OrderModel order, {
    double? writeoffOverride,
    ShipmentMode mode = ShipmentMode.whole,
    bool hasDocument = false,
  }) async {
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

    // orders.actual_qty ведёт recomputeOrderActualQty — единственное место,
    // которое знает правило «считаем только после закрытия упаковки» и
    // переводит упаковки в штуки по фасовке заказа. Локальный пересчёт по
    // задачам ниже этого не умеет: при фасовке 500 он давал 1299 вместо
    // 649500, и отгрузка падала на собственной проверке — диалог предлагал
    // списать факт из карточки, а проверка считала его превышением.
    // Поэтому сохранённое значение первично, а скан производства остаётся
    // запасным для старых заказов, где пересчёт ни разу не отработал.
    final double? savedActualQty =
        _toDoubleNullable(latestRow == null ? null : latestRow['actual_qty']);
    final double? actualQtyOverride =
        savedActualQty ?? await _loadLatestProductionActualQty(order.id);
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

    // Журнал прошлых партий: он же отвечает, сколько осталось. Читаем ДО
    // списания — после вставки новой строки остаток был бы уже уменьшен.
    final previousShipments = await fetchOrderShipments(order.id);

    // Сколько ещё можно отгрузить. При отгрузке разом заказ закрывается
    // целиком, и точкой отсчёта остаётся весь факт; при отгрузке частями —
    // только неотгруженный остаток.
    final double remainingBefore = mode == ShipmentMode.whole
        ? safeActual
        : remainingToShip(actualQty: safeActual, shipments: previousShipments);

    double writeoffQty = writeoffOverride ?? math.min(plannedQty, remainingBefore);
    if (writeoffQty.isNaN || writeoffQty.isInfinite) {
      writeoffQty = 0;
    }
    if (writeoffQty < 0) {
      writeoffQty = 0;
    }
    if (writeoffQty <= 0) {
      throw Exception('Количество для списания должно быть больше нуля.');
    }
    if (writeoffQty > remainingBefore + 0.01) {
      throw Exception(
        mode == ShipmentMode.whole
            ? 'Нельзя отгрузить больше фактического количества: '
                'к отгрузке ${_formatQty(writeoffQty)}, '
                'факт ${_formatQty(safeActual)}.'
            : 'Нельзя отгрузить больше остатка: '
                'к отгрузке ${_formatQty(writeoffQty)}, '
                'осталось ${_formatQty(remainingBefore)}.',
      );
    }

    // Остаток на складе после этой партии. Для частичной отгрузки это ровно
    // то, что заберут в следующий раз, — списывается только увезённое.
    final double leftoverQty =
        remainingBefore > writeoffQty ? (remainingBefore - writeoffQty) : 0;

    final bool closesOrder = shipmentClosesOrder(
      mode: mode,
      actualQty: safeActual,
      shipments: previousShipments,
      qty: writeoffQty,
    );

    final String? sizeLabel = _formatProductSize(orderData.product);

    try {
      await _processCategoryShipment(
        order: orderData,
        // Точка отсчёта на складе — неотгруженный остаток, а не весь факт:
        // на второй партии весь факт задрал бы количество обратно вверх.
        actualQty: remainingBefore,
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

    final DateTime now = DateTime.now().toUtc();
    final previous = _orders[index];
    // Незакрывающая партия НЕ ставит shipped_at: по нему заказ уходит из
    // «Завершённых» в архив, а он должен остаться и ждать следующей отгрузки.
    // Остальные поля обновляются и у неё — они означают ПОСЛЕДНЮЮ отгрузку.
    final updated = orderData.copyWith(
      status: OrderStatus.completed.name,
      // Дату завершения ПРОИЗВОДСТВА отгрузка не перебивает: её ставит
      // закрытие последнего этапа, и заказ мог пролежать на складе неделю.
      // Раньше в запрос безусловно писалось `now`, и у каждого отгруженного
      // заказа «завершение» совпадало с отгрузкой — по такой дате нельзя ни
      // отфильтровать архив, ни посчитать, сколько товар ждал машину.
      // Заказ, отгруженный вообще без завершения производства, отметку всё же
      // получает: иначе он остался бы навсегда без даты закрытия.
      completedAt: orderData.completedAt ?? now,
      shippedAt: closesOrder ? now : orderData.shippedAt,
      shippedBy: AuthHelper.currentUserName ?? '',
      shippedQty: writeoffQty,
    );

    _orders[index] = updated;
    notifyListeners();

    try {
      // completed_at уезжает в запрос через toMap: copyWith выше уже проставил
      // его так, чтобы прежняя дата завершения производства не потерялась.
      final orderUpdate = updated.toMap()..remove('id');
      await _supabase.from('orders').update(orderUpdate).eq('id', order.id);
      // Момент отгрузки ставит сервер (триггер orders_stamp_shipped_at):
      // часы устройства могут отставать, и в архиве отгрузка выглядела бы
      // сделанной раньше, чем была. Забираем проставленное время сразу, иначе
      // карточка до следующего обновления показывала бы время планшета.
      await _adoptServerShippedAt(order.id);
      try {
        // Этот side effect принадлежит исходной команде отгрузки. Realtime
        // только перечитывает состояние и не повторяет списание на устройствах.
        await _finalizePaperReservations(
          orderId: order.id,
          orderLabel: _buildOrderLabelForWriteoff(orderData),
        );
      } catch (error, stackTrace) {
        // До централизации это выполнялось best-effort из realtime callback и
        // не откатывало уже сохранённую отгрузку; сохраняем ту же семантику.
        debugPrint(
          '⚠️ shipOrder: paper reservation finalization failed: '
          '$error\n$stackTrace',
        );
      }
      // Строка журнала пишется ПОСЛЕ успешного обновления заказа: партия,
      // которую не удалось провести, не должна остаться в журнале и съесть
      // остаток.
      try {
        await _supabase.from('order_shipments').insert({
          'order_id': order.id,
          'qty': writeoffQty,
          'shipped_at': now.toIso8601String(),
          'shipped_by': AuthHelper.currentUserName ?? '',
          if ((AuthHelper.currentUserId ?? '').trim().isNotEmpty)
            'user_id': AuthHelper.currentUserId!.trim(),
          'has_document': hasDocument,
        });
      } catch (error) {
        // Таблицы может ещё не быть (миграция не доехала). Отгрузка при этом
        // состоялась: склад списан, заказ обновлён. Терять её из-за журнала
        // нельзя, но и молчать нельзя — иначе остаток посчитается неверно.
        debugPrint('⚠️ shipOrder: не удалось записать партию отгрузки: $error');
      }

      await _logOrderEvent(
        order.id,
        'Отгрузка',
        describeShipment(
          qty: writeoffQty,
          hasDocument: hasDocument,
          remaining: leftoverQty,
          closed: closesOrder,
        ),
      );
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
      await _supabase
          .from('tasks')
          .delete()
          .eq('order_id', orderId)
          .inFilter('status', ['waiting', 'pending', 'planned']);
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

    final category = await _findWarehouseCategoryByProductName(
      productName,
      columns: 'id, has_subtables',
    );

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
      final double currentQty = (item['quantity'] is num)
          ? (item['quantity'] as num).toDouble()
          : 0.0;
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
      final String trimmed =
          fixed.replaceAll(RegExp(r'0+$'), '').replaceAll(RegExp(r'[.]$'), '');
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

    final dynamic category = await _findWarehouseCategoryByProductName(
      productName,
      columns: 'id, title, code, has_subtables',
    );

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

  Future<Map<String, dynamic>?> _findWarehouseCategoryByProductName(
    String productName, {
    required String columns,
  }) async {
    final String normalized = productName.trim();
    if (normalized.isEmpty) {
      return null;
    }

    final dynamic byTitle = await _supabase
        .from('warehouse_categories')
        .select(columns)
        .eq('title', normalized)
        .maybeSingle();
    if (byTitle is Map && byTitle['id'] != null) {
      return Map<String, dynamic>.from(byTitle);
    }

    final dynamic byCode = await _supabase
        .from('warehouse_categories')
        .select(columns)
        .eq('code', normalized)
        .maybeSingle();
    if (byCode is Map && byCode['id'] != null) {
      return Map<String, dynamic>.from(byCode);
    }

    return null;
  }

  /// Пересчитывает статус обеспеченности одного заказа по свежим данным.
  ///
  /// Нужен экрану заказа: краски сохраняются последними — их бронь можно
  /// записать только зная id заказа, — а статус к тому моменту уже посчитан по
  /// брони, которой ещё не существовало. Заказ читаем из базы заново: локальная
  /// копия к этому моменту не знает ни о новых красках, ни о правках формы.
  Future<void> applyMaterialAvailability(String orderId) async {
    final id = orderId.trim();
    if (id.isEmpty) return;
    await _ensureAuthed();
    try {
      final row =
          await _supabase.from('orders').select().eq('id', id).maybeSingle();
      if (row == null) return;
      await _applyImmediateMaterialAvailabilityState(
        OrderModel.fromMap(Map<String, dynamic>.from(row)),
      );
      await refresh();
    } catch (e, st) {
      // Пересчёт — уточнение уже сохранённого заказа. Сорвать сохранение из-за
      // него нельзя: заказ в базе, а статус поправит следующий пересчёт.
      debugPrint('⚠️ applyMaterialAvailability($id) failed: $e\n$st');
    }
  }

  Future<void> _applyImmediateMaterialAvailabilityState(
      OrderModel order) async {
    // Дозапускной конвейер статусов (draft → waiting_materials →
    // ready_to_start) к уже запущенному заказу не применяется.
    //
    // Во-первых, его материал к этому моменту уже переведён в резерв, и
    // проверка свободного остатка почти всегда показывает нехватку — на своём
    // же резерве. Во-вторых, метод зовётся из updateOrder, то есть на КАЖДОМ
    // сохранении: запущенный заказ выдёргивало из производства в «Ожидание
    // материалов», а следующее сохранение переводило его в «Готовы к запуску»
    // — с assignment_created = true, где canLaunchOrder возвращает false и
    // кнопка запуска мертва. Заказ выпадал из всех рабочих списков.
    //
    // Ту же защиту держит recheckMaterialAvailability, а edit_order_screen
    // при wasAlreadyLaunched сохраняет прежние статус и признак нехватки.
    // Само правило — в materialAvailabilityStatus, с тестами.
    final queueBuilt = QueueBuildStatus.normalize(order.queueBuildStatus) ==
        QueueBuildStatus.built;
    final bool hasEnough;
    try {
      hasEnough = queueBuilt && await _hasEnoughMaterialForLaunch(order);
    } on _StockCheckUnavailable catch (e) {
      // Обеспеченность не проверена — статус не трогаем вовсе. Записать сюда
      // хоть что-нибудь значит соврать: и «готов», и «ожидание материалов»
      // одинаково не подтверждены.
      debugPrint('ℹ️ статус заказа ${order.id} не пересчитан: $e');
      return;
    }
    final dataComplete = order.assignmentCreated
        ? true
        : (await _materialsWithoutQuantity(order)).isEmpty;
    final requiredComplete = order.assignmentCreated
        ? true
        : (await _missingRequiredBlocks(order)).isEmpty;
    final nextStatus = materialAvailabilityStatus(
      order: order,
      queueBuilt: queueBuilt,
      hasEnoughMaterial: hasEnough,
      materialDataComplete: dataComplete,
      requiredBlocksComplete: requiredComplete,
    );
    final shortageMessage =
        queueBuilt && !hasEnough ? await _materialShortageMessage(order) : '';
    final hasMaterialShortage = queueBuilt && !hasEnough;

    // Запущенный заказ: статус не трогаем — он живёт в производстве. Но
    // признак нехватки и текст обязаны оставаться свежими.
    //
    // Раньше здесь стоял безусловный выход, и получалось хуже исходного бага:
    // заказ переставал пересчитываться совсем и навсегда застывал со старым
    // сообщением. Материал уже привезли, а карточка продолжала писать
    // «доступно -32», потому что этот текст не переписывался ничем.
    if (nextStatus == null) {
      if (order.hasMaterialShortage == hasMaterialShortage &&
          order.materialShortageMessage == shortageMessage) {
        return;
      }
      await _supabase.from('orders').update({
        'has_material_shortage': hasMaterialShortage,
        'material_shortage_message': shortageMessage,
      }).eq('id', order.id);
      final launchedIndex = _orders.indexWhere((o) => o.id == order.id);
      if (launchedIndex != -1) {
        _orders[launchedIndex] = _orders[launchedIndex].copyWith(
          hasMaterialShortage: hasMaterialShortage,
          materialShortageMessage: shortageMessage,
        );
        notifyListeners();
      }
      return;
    }

    // Бронь идёт следом за статусом: обеспеченный заказ занимает бумагу,
    // необеспеченный — возвращает её на склад. Делаем это ДО сравнения
    // статусов: заказ мог уже стоять в «Готов к запуску» и при этом не держать
    // ни метра, и выход по «ничего не изменилось» оставил бы его без брони.
    //
    // Отказ RPC означает, что рулон успел забрать сосед. Тогда статус не
    // поднимаем и показываем текст сервера — он точнее нашего, потому что
    // сервер считает остаток под блокировкой строки.
    var effectiveStatus = nextStatus;
    var effectiveShortage = hasMaterialShortage;
    var effectiveMessage = shortageMessage;

    if (holdsPaperReservation(
      assignmentCreated: order.assignmentCreated,
      status: nextStatus,
    )) {
      final reserveError = await _syncPaperReservationsForOrder(
        order.copyWith(status: nextStatus.name),
      );
      if (reserveError != null) {
        effectiveStatus = OrderStatus.waiting_materials;
        effectiveShortage = true;
        effectiveMessage = reserveError;
      }
    } else if (nextStatus != OrderStatus.completed) {
      await _releasePaperReservations(
        orderId: order.id,
        reason: 'not_ready_to_start',
        eventMessage:
            'Бронь снята: заказ не обеспечен, бумага возвращена на склад',
      );
      await _releasePaintReservations(
        orderId: order.id,
        reason: 'not_ready_to_start',
      );
    }

    if (order.statusEnum == effectiveStatus &&
        order.hasMaterialShortage == effectiveShortage &&
        order.materialShortageMessage == effectiveMessage) {
      return;
    }

    final updatePayload = <String, dynamic>{
      'status': effectiveStatus.name,
      'has_material_shortage': effectiveShortage,
      'material_shortage_message': effectiveMessage,
    };

    await _supabase.from('orders').update(updatePayload).eq('id', order.id);

    final index = _orders.indexWhere((o) => o.id == order.id);
    if (index != -1) {
      _orders[index] = _orders[index].copyWith(
        status: effectiveStatus.name,
        hasMaterialShortage: effectiveShortage,
        materialShortageMessage: effectiveMessage,
      );
      notifyListeners();
    }
  }

  String _buildOrderLabelForWriteoff(OrderModel order) {
    final customer = order.customer.trim();
    if (customer.isNotEmpty) return customer;

    final productName = order.product.type.trim();
    if (productName.isNotEmpty) return productName;

    final assignment = (order.assignmentId ?? '').trim();
    if (assignment.isNotEmpty) return assignment;

    return order.id;
  }

  /// Позиции заказа, где материал выбран, а количество не указано.
  ///
  /// Правило и его обоснование — в [materialsWithoutQuantity]. Здесь только
  /// сбор данных: бумага лежит в самом заказе, краски — отдельной таблицей
  /// `order_paints`, где граммовка хранится килограммами.
  ///
  /// Ошибку чтения красок трактуем как «краски проверить не удалось», а не как
  /// «краски неполные»: уронить чужой заказ в черновик из-за сетевого сбоя
  /// хуже, чем пропустить одну проверку — её повторит следующее сохранение.
  Future<List<String>> _materialsWithoutQuantity(OrderModel order) async {
    var paints = const <OrderPaintLine>[];
    try {
      final rows =
          await OrdersRepository(supabaseClient: _supabase).getPaints(order.id);
      paints = rows.map((row) {
        final qtyKg = _toDoubleNullable(row['qty_kg']);
        return OrderPaintLine(
          name: (row['name'] ?? '').toString(),
          qtyGrams: qtyKg == null ? null : qtyKg * 1000,
        );
      }).toList(growable: false);
    } catch (e, st) {
      debugPrint('⚠️ не удалось прочитать краски заказа ${order.id}: $e\n$st');
    }

    return materialsWithoutQuantity(
      papers: _resolveOrderPapers(order),
      paints: paints,
    );
  }

  /// Обязательные блоки, которые в заказе не заполнены.
  ///
  /// Пустой список — либо всё заполнено, либо техлид ничего не требовал.
  ///
  /// НЕИЗВЕСТНОСТЬ ТРАКТУЕТСЯ КАК «ЗАПОЛНЕНО». Сбой чтения справочника, красок
  /// или файлов не должен ронять заказ в черновик: это тот же принцип, что и у
  /// остального пересчёта — «сбой чтения не вердикт». Ошибка в эту сторону
  /// оставляет прежнее поведение, обратная заперла бы заказы без объяснения.
  ///
  /// Краски и файлы дочитываются ТОЛЬКО когда их действительно требуют: у
  /// пересчёта это цикл по всем заказам, и лишний запрос на каждый заказ стоит
  /// дороже самой проверки.
  Future<List<String>> _missingRequiredBlocks(OrderModel order) async {
    final settings = ProductTypeSettings.instance;
    try {
      await settings.ensureLoaded();
    } catch (e) {
      debugPrint('⚠️ настройки типов продукта недоступны: $e');
      return const <String>[];
    }

    final productType = (order.productTypeId ?? '').trim().isNotEmpty
        ? order.productTypeId!.trim()
        : order.product.type;
    final requiredCodes = settings.requiredBlockCodes(productType);
    if (requiredCodes.isEmpty) return const <String>[];

    var paintLineCount = 1;
    if (requiredCodes.contains(kOrderFormBlockPaints)) {
      try {
        paintLineCount = await _paintLineCountForOrder(order.id);
      } catch (e) {
        debugPrint('⚠️ не удалось прочитать краски заказа ${order.id}: $e');
      }
    }

    var hasPdf = true;
    if (requiredCodes.contains(kOrderFormBlockPdf)) {
      try {
        final rows = await _supabase
            .from('order_files')
            .select('id')
            .eq('order_id', order.id)
            .limit(1);
        hasPdf = (rows as List).isNotEmpty;
      } catch (e) {
        debugPrint('⚠️ не удалось прочитать файлы заказа ${order.id}: $e');
      }
    }

    return missingRequiredBlocksForOrder(
      requiredCodes: requiredCodes,
      filledCodes: filledOrderBlocks(
        order: order,
        paintLineCount: paintLineCount,
        hasPdf: hasPdf,
      ),
      conditionsFor: (code) => settings.blockConditions(productType, code),
      handleTypeName: orderHandleTypeName(order),
      order: settings.formBlockCodes,
    );
  }

  List<MaterialModel> _resolveOrderPapers(OrderModel order) {
    if (order.paperMaterials.isNotEmpty) return order.paperMaterials;
    if (order.material != null) return <MaterialModel>[order.material!];
    return const <MaterialModel>[];
  }

  double _requiredPaperReserveQty(OrderModel order, MaterialModel paper) {
    final double? perPaperLength = _paperExtraLength(paper);
    if (perPaperLength != null && perPaperLength > 0) {
      return perPaperLength;
    }

    // Приоритет: если в материале уже есть длина (например, из поля "Длина L"),
    // используем её до общих размеров продукта.
    if (paper.quantity > 0) return paper.quantity;

    final double length = (order.product.length ?? 0).toDouble();
    if (length > 0) return length;

    if (paper.weight != null && paper.weight! > 0) return paper.weight!;
    return 0;
  }

  Future<MaterialModel> _normalizePaperForReservation(
      MaterialModel paper) async {
    final double? perPaperLength = _paperExtraLength(paper);
    final double qty = paper.quantity > 0
        ? paper.quantity
        : (perPaperLength != null && perPaperLength > 0
            ? perPaperLength
            : (paper.weight != null && paper.weight! > 0
                ? paper.weight!
                : 0.0));
    final normalized = paper.copyWith(quantity: qty);
    final currentId = (normalized.id ?? '').trim();
    if (currentId.isNotEmpty) {
      return normalized;
    }
    final resolvedId = await _resolvePaperIdByAttributes(normalized);
    if (resolvedId == null) {
      return normalized;
    }
    return normalized.copyWith(id: resolvedId);
  }

  Future<String?> _resolvePaperIdByAttributes(MaterialModel paper) async {
    final name = paper.name.trim();
    final format = (paper.format ?? '').trim();
    final grammage = (paper.grammage ?? '').trim();
    if (name.isEmpty || format.isEmpty || grammage.isEmpty) {
      return null;
    }
    try {
      final Map<String, dynamic>? row = await _supabase
          .from('papers')
          .select('id')
          .eq('description', name)
          .eq('format', format)
          .eq('grammage', grammage)
          .maybeSingle();
      if (row == null) {
        return null;
      }
      final id = (row['id'] ?? '').toString().trim();
      return id.isEmpty ? null : id;
    } catch (_) {
      return null;
    }
    return null;
  }

  double? _paperExtraLength(MaterialModel paper) {
    final dynamic value = paper.extra?['lengthL'];
    if (value is num) return value.toDouble();
    if (value is String) {
      final normalized = value.trim().replaceAll(',', '.');
      if (normalized.isEmpty) return null;
      return double.tryParse(normalized);
    }
    return null;
  }

  /// Приводит бронь краски заказа к его составу. `null` — успех.
  ///
  /// Состав берём из `order_paints` — это то, что сохранила форма заказа.
  /// Сервер сам решает, хватает ли остатка: при нехватке он бросает исключение
  /// с текстом, который точнее нашего (считает под блокировкой строки).
  Future<String?> _syncPaintReservationsForOrder(String orderId) async {
    final id = orderId.trim();
    if (id.isEmpty) return null;
    final repo = OrdersRepository(supabaseClient: _supabase);
    try {
      await repo.syncPaintReservations(
        orderId: id,
        paints: await repo.getPaints(id),
        actor: AuthHelper.currentUserName ?? '',
      );
      return null;
    } on PostgrestException catch (error) {
      final details = error.message.trim();
      return details.isEmpty
          ? 'Не удалось зарезервировать краску для заказа $id.'
          : details;
    } catch (e, st) {
      debugPrint('⚠️ sync paint reservations for $id failed: $e\n$st');
      // Отказ PostgrestException выше — настоящая нехватка, его текст точнее
      // нашего. Обрыв связи и таймаут вердиктом не являются: вернув отсюда
      // сообщение, мы клали заказ в «Ожидание материалов» из-за моргнувшего
      // Wi-Fi.
      throw _StockCheckUnavailable('sync_order_paint_reservations $id: $e');
    }
  }

  Future<String?> _syncPaperReservationsForOrder(OrderModel order) async {
    final papers = _resolveOrderPapers(order)
        .where((paper) => (paper.id ?? '').trim().isNotEmpty)
        .toList(growable: false);

    // Бизнес-правило: в production всегда держим актуальный резерв по составу бумаги заказа.
    // Если один и тот же paper_id был выбран в нескольких слотах, агрегируем метраж,
    // чтобы корректно проходить уникальный индекс (order_id, paper_id).
    final Map<String, double> aggregated = <String, double>{};
    for (final paper in papers) {
      final paperId = (paper.id ?? '').trim();
      if (paperId.isEmpty) continue;
      final qty = _requiredPaperReserveQty(order, paper);
      if (qty <= 0) continue;
      aggregated.update(
        paperId,
        (value) => value + qty,
        ifAbsent: () => qty,
      );
    }

    final before = await _loadOrderReservationMap(order.id);

    // Состав и метраж резерва не изменились — не проверяем и не пишем ничего.
    // Перезапись 1700 → 1700 не требует ни метра нового остатка, а проверка
    // доступности могла отклонить такое сохранение из-за чужих броней: заказ
    // не проходил по собственной же брони и вылетал из производства.
    if (sameReservationPlan(before, aggregated)) return null;

    final requestedRows = aggregated.entries
        .map((entry) => <String, dynamic>{
              'paper_id': entry.key,
              'qty': entry.value,
            })
        .toList(growable: false);

    try {
      // Атомарно синхронизируем резерв на стороне БД:
      // upsert + удаление неактуальных строк + проверка доступного остатка.
      await _supabase.rpc(
        'sync_order_paper_reservations',
        params: {
          'p_order_id': order.id,
          'p_reservations': requestedRows,
          'p_actor': AuthHelper.currentUserName ?? '',
        },
      );
    } on PostgrestException catch (error) {
      final details = error.message.trim();
      if (details.isNotEmpty) return details;
      return 'Не удалось обновить резерв бумаги для заказа ${order.id}.';
    }

    final after = await _loadOrderReservationMap(order.id);
    await _logReservationDiff(orderId: order.id, before: before, after: after);
    return null;
  }

  /// Вернуть краску заказа на склад.
  ///
  /// Зовётся из тех же мест, что и снятие брони бумаги: заказ, потерявший
  /// право на материал, отдаёт и то, и другое. Раньше вызов был ровно один —
  /// удаление заказа, — и застрявший заказ вечно держал краску, которой сам
  /// воспользоваться не мог, отнимая её у соседей.
  ///
  /// Запущенные заказы сюда не попадают: пересчёт их не перебирает.
  Future<void> _releasePaintReservations({
    required String orderId,
    String reason = 'order_deleted',
  }) async {
    try {
      await OrdersRepository(supabaseClient: _supabase)
          .releasePaintReservations(
        orderId: orderId,
        reason: reason,
        actor: AuthHelper.currentUserName ?? '',
      );
    } catch (_) {
      try {
        await _supabase
            .from('order_paint_reservations')
            .delete()
            .eq('order_id', orderId);
      } catch (_) {}
    }
  }

  Future<void> _releasePaperReservations({
    required String orderId,
    String reason = 'order_deleted',
    String eventMessage = 'Резерв возвращен из-за удаления заказа',
  }) async {
    final before = await _loadOrderReservationMap(orderId);
    if (before.isEmpty) return;
    try {
      // Атомарный возврат резерва при удалении/откате заказа.
      await _supabase.rpc(
        'release_order_paper_reservations',
        params: {
          'p_order_id': orderId,
          'p_reason': reason,
          'p_actor': AuthHelper.currentUserName ?? '',
        },
      );
    } catch (_) {
      // Fallback для окружений без RPC-функции.
      await _supabase
          .from('order_paper_reservations')
          .delete()
          .eq('order_id', orderId);
    }
    await _logOrderEvent(orderId, 'Резерв бумаги', eventMessage);
  }

  /// Перечитывает момент отгрузки, проставленный сервером, в локальный заказ.
  Future<void> _adoptServerShippedAt(String orderId) async {
    try {
      final row = await _supabase
          .from('orders')
          .select('shipped_at')
          .eq('id', orderId)
          .maybeSingle();
      final raw = (row?['shipped_at'] ?? '').toString().trim();
      final serverShippedAt = raw.isEmpty ? null : DateTime.tryParse(raw);
      if (serverShippedAt == null) return;
      final index = _orders.indexWhere((o) => o.id == orderId);
      if (index == -1) return;
      _orders[index] = _orders[index].copyWith(shippedAt: serverShippedAt);
      notifyListeners();
    } catch (e) {
      // Не критично: realtime и следующий перечит принесут серверное время.
      debugPrint('⚠️ не удалось перечитать время отгрузки заказа $orderId: $e');
    }
  }

  Future<void> _finalizePaperReservations({
    required String orderId,
    required String orderLabel,
  }) async {
    // Бумага почти всегда списана раньше — сервером, после последнего по
    // маршруту из Бабинорезки/Флексопечати, а без них — после первого этапа
    // (см. `order_paper_writeoff_stage_key`). Тогда брони здесь уже нет, и
    // отгрузке делать нечего. Этот вызов остаётся страховкой для заказов без
    // маршрута: там списывать бумагу больше негде.
    final before = await _loadOrderReservationMap(orderId);
    if (before.isEmpty) return;
    final normalizedOrderLabel =
        orderLabel.trim().isEmpty ? orderId : orderLabel.trim();
    final humanReadableReason =
        'Списание бумаги по заказу $normalizedOrderLabel';
    try {
      // Финализируем резерв атомарно: списание + очистка резерва в одной транзакции.
      await _supabase.rpc(
        'finalize_order_paper_reservations',
        params: {
          'p_order_id': orderId,
          'p_actor': AuthHelper.currentUserName ?? '',
        },
      );
    } catch (_) {
      // Fallback для обратной совместимости.
      final rows = await _supabase
          .from('order_paper_reservations')
          .select('paper_id, qty')
          .eq('order_id', orderId);
      if (rows is! List || rows.isEmpty) return;
      for (final raw in rows.whereType<Map>()) {
        final row = Map<String, dynamic>.from(raw as Map);
        final paperId = (row['paper_id'] ?? '').toString().trim();
        final qty = _toDouble(row['qty']);
        if (paperId.isEmpty || qty <= 0) continue;
        await _supabase.from('papers_writeoffs').insert({
          'paper_id': paperId,
          'qty': qty,
          'reason': humanReadableReason,
          'by_name': AuthHelper.currentUserName ?? '',
        });
      }
      await _supabase
          .from('order_paper_reservations')
          .delete()
          .eq('order_id', orderId);
    }

    // Причину больше не переписываем задним числом: RPC сама подставляет имя
    // заказчика. Прежний UPDATE искал строки по причине с UUID и работал только
    // если списание прошло с этого же устройства — при серверном списании
    // (завершение последнего этапа) кладовщик так и видел в журнале склада
    // голый uuid заказа.
    await _logOrderEvent(
      orderId,
      'Резерв бумаги',
      'Резерв списан: бумага заказа ушла со склада',
    );
    await StockAvailabilityRecheckCoordinator.instance
        .afterCommittedStockMutation();
  }

  Future<Map<String, double>> _loadOrderReservationMap(String orderId) async {
    final rows = await _supabase
        .from('order_paper_reservations')
        .select('paper_id, qty')
        .eq('order_id', orderId);
    if (rows is! List) return const <String, double>{};
    final map = <String, double>{};
    for (final raw in rows.whereType<Map>()) {
      final row = Map<String, dynamic>.from(raw as Map);
      final paperId = (row['paper_id'] ?? '').toString().trim();
      final qty = _toDouble(row['qty']);
      if (paperId.isEmpty || qty <= 0) continue;
      map.update(paperId, (value) => value + qty, ifAbsent: () => qty);
    }
    return map;
  }

  Future<void> _logReservationDiff({
    required String orderId,
    required Map<String, double> before,
    required Map<String, double> after,
  }) async {
    final paperIds = <String>{...before.keys, ...after.keys};
    if (paperIds.isEmpty) return;
    for (final paperId in paperIds) {
      final oldQty = before[paperId] ?? 0;
      final newQty = after[paperId] ?? 0;
      if ((oldQty - newQty).abs() < 0.000001) continue;
      if (oldQty <= 0 && newQty > 0) {
        await _logOrderEvent(
          orderId,
          'Резерв бумаги',
          'Создан резерв ${newQty.toStringAsFixed(2)} м бумаги $paperId для заказа $orderId',
        );
      } else if (oldQty > 0 && newQty <= 0) {
        await _logOrderEvent(
          orderId,
          'Резерв бумаги',
          'Удален резерв ${oldQty.toStringAsFixed(2)} м бумаги $paperId для заказа $orderId',
        );
      } else {
        await _logOrderEvent(
          orderId,
          'Резерв бумаги',
          'Изменен резерв бумаги $paperId: было ${oldQty.toStringAsFixed(2)} м, стало ${newQty.toStringAsFixed(2)} м',
        );
      }
    }
  }

  String? _describePaperChanges({
    required OrderModel previous,
    required OrderModel updated,
    String? reason,
  }) {
    if (!_hasPaperCompositionChanged(previous: previous, updated: updated)) {
      return null;
    }
    final before = _resolveOrderPapers(previous);
    final after = _resolveOrderPapers(updated);
    String fmtDate(DateTime dt) {
      final local = toKostanayTime(dt);
      String two(int v) => v.toString().padLeft(2, '0');
      return '${two(local.day)}.${two(local.month)}.${local.year} '
          '${two(local.hour)}:${two(local.minute)}';
    }

    String materialName(MaterialModel m) {
      final format = (m.format ?? '').trim();
      final grammage = (m.grammage ?? '').trim();
      final suffix = [
        if (format.isNotEmpty) 'Ф $format',
        if (grammage.isNotEmpty) 'Гр $grammage',
      ].join(' / ');
      return suffix.isEmpty ? m.name : '${m.name} ($suffix)';
    }

    double _paperWidthB(MaterialModel m) {
      final raw = m.extra?['widthB'];
      if (raw is num) return raw.toDouble();
      return double.tryParse((raw ?? '').toString().replaceAll(',', '.')) ?? 0;
    }

    String _paperBlQuantity(MaterialModel m, {String fallback = ''}) =>
        (m.extra?['blQuantity'] ?? fallback).toString().trim();

    String _paperMetrics(
      MaterialModel m, {
      double? fallbackWidthB,
      String? fallbackBlQuantity,
    }) {
      final parsedWidthB = _paperWidthB(m);
      final widthB = parsedWidthB > 0 ? parsedWidthB : (fallbackWidthB ?? 0);
      final blQuantity = _paperBlQuantity(
        m,
        fallback: (fallbackBlQuantity ?? '').trim(),
      );
      final lengthL = m.quantity;
      final widthText =
          widthB > 0 ? widthB.toStringAsFixed(widthB % 1 == 0 ? 0 : 2) : '—';
      final quantityText = blQuantity.isNotEmpty ? blQuantity : '—';
      return 'Ш $widthText, К $quantityText, Длина L ${lengthL.toStringAsFixed(2)} м';
    }

    final user = (AuthHelper.currentUserName ?? 'Сотрудник').trim();
    final timestamp = fmtDate(DateTime.now());
    final maxCount =
        before.length > after.length ? before.length : after.length;
    final buffer = StringBuffer()..writeln('$user изменил бумагу $timestamp');
    for (var i = 0; i < maxCount; i++) {
      final old = i < before.length ? before[i] : null;
      final next = i < after.length ? after[i] : null;
      final slot = i + 1;
      if (old != null && next != null) {
        final delta = next.quantity - old.quantity;
        final deltaPrefix = delta >= 0 ? '+' : '';
        buffer.writeln(
          'Бумага №$slot: было ${materialName(old)} — ${_paperMetrics(old, fallbackWidthB: i == 0 ? previous.product.widthB : null, fallbackBlQuantity: i == 0 ? previous.product.blQuantity : null)}, '
          'стало ${materialName(next)} — ${_paperMetrics(next, fallbackWidthB: i == 0 ? updated.product.widthB : null, fallbackBlQuantity: i == 0 ? updated.product.blQuantity : null)} '
          '($deltaPrefix${delta.toStringAsFixed(2)} м)',
        );
      } else if (old == null && next != null) {
        buffer.writeln(
          'Добавлена бумага №$slot: ${materialName(next)} — ${_paperMetrics(next, fallbackWidthB: i == 0 ? updated.product.widthB : null, fallbackBlQuantity: i == 0 ? updated.product.blQuantity : null)}',
        );
      } else if (old != null && next == null) {
        buffer.writeln(
          'Удалена бумага №$slot: ${materialName(old)} — ${_paperMetrics(old, fallbackWidthB: i == 0 ? previous.product.widthB : null, fallbackBlQuantity: i == 0 ? previous.product.blQuantity : null)}',
        );
      }
    }
    final reasonText = (reason ?? '').trim();
    if (reasonText.isNotEmpty) {
      // Бизнес-правило: причина изменения бумаги обязательна для производства.
      buffer.writeln('Причина: $reasonText');
    }
    return buffer.toString().trim();
  }

  bool _hasPaperCompositionChanged({
    required OrderModel previous,
    required OrderModel updated,
  }) {
    bool textChanged(String? a, String? b) {
      return (a ?? '').trim().toLowerCase() != (b ?? '').trim().toLowerCase();
    }

    final before = _resolveOrderPapers(previous);
    final after = _resolveOrderPapers(updated);
    if ((previous.product.widthB ?? 0) != (updated.product.widthB ?? 0)) {
      return true;
    }
    final prevBlQuantity = previous.product.blQuantity?.trim() ?? '';
    final nextBlQuantity = updated.product.blQuantity?.trim() ?? '';
    if (prevBlQuantity != nextBlQuantity) {
      return true;
    }
    if (before.length != after.length) return true;
    for (var i = 0; i < before.length; i++) {
      final beforeWidthB = _toDouble(before[i].extra?['widthB']);
      final afterWidthB = _toDouble(after[i].extra?['widthB']);
      final beforeBlQuantity =
          (before[i].extra?['blQuantity'] ?? '').toString().trim();
      final afterBlQuantity =
          (after[i].extra?['blQuantity'] ?? '').toString().trim();
      if (before[i].id != after[i].id ||
          textChanged(before[i].name, after[i].name) ||
          textChanged(before[i].format, after[i].format) ||
          textChanged(before[i].grammage, after[i].grammage) ||
          (before[i].quantity - after[i].quantity).abs() > 0.0001 ||
          (beforeWidthB - afterWidthB).abs() > 0.0001 ||
          beforeBlQuantity != afterBlQuantity) {
        return true;
      }
    }
    return false;
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
        final desc =
            [name, color].where((part) => part.isNotEmpty).join(' • ').trim();
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
    return double.tryParse(value.toString().replaceAll(',', '.')) ?? 0;
  }

  double? _toDoubleNullable(dynamic value) {
    if (value == null) return null;
    if (value is num) return value.toDouble();
    final String text = value.toString().trim();
    if (text.isEmpty) return null;
    return double.tryParse(text.replaceAll(',', '.'));
  }

  Future<double?> _loadLatestProductionActualQty(String orderId) async {
    try {
      final rows = await _loadProductionTaskQuantityRows(orderId);
      if (rows.isEmpty) {
        return null;
      }

      final stageTotals = <String, double>{};
      final stageLastTouched = <String, int>{};
      for (final raw in rows.whereType<Map>()) {
        final row = Map<String, dynamic>.from(raw);
        final stageId = (row['stage_id'] ?? '').toString();
        if (stageId.isEmpty) continue;

        final comments = _normalizeTaskComments(row['comments']);
        final helperIds = helperIdsFromComments(
          assignees: assigneesFromRaw(row['assignees']),
          comments: comments,
        );
        final quantity = _taskProductionQuantity(comments, helperIds);
        if (quantity == null || quantity <= 0) continue;

        stageTotals.update(stageId, (current) => current + quantity,
            ifAbsent: () => quantity);
        final touchedAt =
            _latestTaskQuantityTimestamp(comments, row, helperIds);
        final previousTouchedAt = stageLastTouched[stageId] ?? 0;
        if (touchedAt > previousTouchedAt) {
          stageLastTouched[stageId] = touchedAt;
        }
      }

      if (stageTotals.isEmpty) {
        return null;
      }

      var latestStageId = stageTotals.keys.first;
      var latestTouchedAt = stageLastTouched[latestStageId] ?? 0;
      for (final stageId in stageTotals.keys.skip(1)) {
        final touchedAt = stageLastTouched[stageId] ?? 0;
        if (touchedAt > latestTouchedAt) {
          latestStageId = stageId;
          latestTouchedAt = touchedAt;
        }
      }
      return stageTotals[latestStageId];
    } catch (e, st) {
      debugPrint('⚠️ shipOrder: unable to load production actual_qty: $e\n$st');
      return null;
    }
  }

  Future<List<Map<String, dynamic>>> _loadProductionTaskQuantityRows(
    String orderId,
  ) async {
    // assignees нужен, чтобы отличить долю помощника от тиража этапа
    // (см. [helperIdsFromComments]).
    const columnSets = <String>[
      'stage_id, comments, assignees, completed_at, finished_at',
      'stage_id, comments, assignees, finished_at',
      'stage_id, comments, assignees',
    ];

    Object? lastMissingColumnError;
    for (final columns in columnSets) {
      try {
        final rows = await _supabase
            .from('tasks')
            .select(columns)
            .eq('order_id', orderId);
        if (rows is! List) {
          return const <Map<String, dynamic>>[];
        }
        return rows
            .whereType<Map>()
            .map((row) => Map<String, dynamic>.from(row))
            .toList(growable: false);
      } catch (error) {
        final canRetry = _isMissingColumnError(error, 'completed_at') ||
            _isMissingColumnError(error, 'finished_at');
        if (!canRetry) rethrow;
        lastMissingColumnError = error;
      }
    }

    if (lastMissingColumnError != null) throw lastMissingColumnError;
    return const <Map<String, dynamic>>[];
  }

  bool _isMissingColumnError(Object error, String columnName) {
    if (error is! PostgrestException) return false;

    final code = (error.code ?? '').trim();
    final message = error.message.toLowerCase();
    final details = (error.details ?? '').toString().toLowerCase();
    final hint = (error.hint ?? '').toString().toLowerCase();
    final normalizedColumn = columnName.toLowerCase();
    final mentionsColumn = message.contains(normalizedColumn) ||
        details.contains(normalizedColumn) ||
        hint.contains(normalizedColumn);

    return mentionsColumn &&
        (code == '42703' ||
            code == 'PGRST204' ||
            message.contains('column') ||
            message.contains('schema cache'));
  }

  List<Map<String, dynamic>> _normalizeTaskComments(dynamic value) {
    if (value is List) {
      return value
          .whereType<Map>()
          .map((item) => Map<String, dynamic>.from(item))
          .toList(growable: false);
    }
    if (value is Map) {
      return value.values
          .whereType<Map>()
          .map((item) => Map<String, dynamic>.from(item))
          .toList(growable: false);
    }
    return const <Map<String, dynamic>>[];
  }

  // Типы записей количества этапа: перерывы (share) + завершение
  // (done/team_total — «сделано с последнего перерыва»). Семантика единая
  // с аналитикой (TaskAnalyticsMapper) и recomputeOrderActualQty; отбор
  // записей — общий, см. [countsTowardOrderQuantity].

  double? _taskProductionQuantity(
    List<Map<String, dynamic>> comments,
    Set<String> helperIds,
  ) {
    double total = 0;
    var hasQuantity = false;
    for (final comment in comments) {
      if (!countsTowardOrderQuantity(
          comment: comment, helperIds: helperIds)) {
        continue;
      }
      total += _parseProductionQuantity(comment['text']);
      hasQuantity = true;
    }
    return hasQuantity ? total : null;
  }

  int _latestTaskQuantityTimestamp(
    List<Map<String, dynamic>> comments,
    Map<String, dynamic> row,
    Set<String> helperIds,
  ) {
    var timestamp = _parseTimestamp(row['completed_at']);
    final finishedAt = _parseTimestamp(row['finished_at']);
    if (finishedAt > timestamp) timestamp = finishedAt;

    for (final comment in comments) {
      if (!countsTowardOrderQuantity(
          comment: comment, helperIds: helperIds)) {
        continue;
      }
      final commentTimestamp = _commentTimestamp(comment);
      if (commentTimestamp > timestamp) timestamp = commentTimestamp;
    }
    return timestamp;
  }

  int _commentTimestamp(Map<String, dynamic> comment) {
    return _parseTimestamp(comment['timestamp']);
  }

  int _parseTimestamp(dynamic value) {
    if (value == null) return 0;
    if (value is num) return value.toInt();
    final text = value.toString().trim();
    if (text.isEmpty) return 0;
    final asInt = int.tryParse(text);
    if (asInt != null) return asInt;
    return DateTime.tryParse(text)?.millisecondsSinceEpoch ?? 0;
  }

  double _parseProductionQuantity(dynamic value) {
    if (value == null) return 0;
    if (value is num) return value.toDouble();
    final normalized = value.toString().replaceAll(',', '.').trim();
    if (normalized.isEmpty) return 0;

    final totalFromFormula =
        RegExp(r'=\s*(-?\d+(?:\.\d+)?)').firstMatch(normalized);
    if (totalFromFormula != null) {
      return double.tryParse(totalFromFormula.group(1) ?? '') ?? 0;
    }

    final packsMatch = RegExp(r'(-?\d+(?:\.\d+)?)\s*пач', caseSensitive: false)
        .firstMatch(normalized);
    final inPackMatch =
        RegExp(r'[x×*]\s*(-?\d+(?:\.\d+)?)').firstMatch(normalized);
    if (packsMatch != null && inPackMatch != null) {
      final packs = double.tryParse(packsMatch.group(1) ?? '') ?? 0;
      final inPack = double.tryParse(inPackMatch.group(1) ?? '') ?? 0;
      return packs * inPack;
    }

    final parsed = double.tryParse(normalized);
    if (parsed != null) return parsed;

    final firstNumber = RegExp(r'-?\d+(?:\.\d+)?').firstMatch(normalized);
    if (firstNumber != null) {
      return double.tryParse(firstNumber.group(0) ?? '') ?? 0;
    }
    return 0;
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
    if (orderId.trim().isEmpty || orderId.startsWith('local-')) {
      return;
    }
    // Автор проставляется САМ, а не только когда его передали явно. Раньше
    // почти все вызовы шли без userId, и история отвечала «что изменилось», но
    // не «кто» — ради чего в неё и заходят. Единственный источник личности на
    // клиенте — AuthHelper: до Postgres она не доходит, и подставить её может
    // только клиент.
    final author = (userId ?? AuthHelper.currentUserId)?.trim();
    final row = <String, dynamic>{
      'order_id': orderId,
      'event_type': eventType,
      'description': description,
    };
    try {
      await _supabase.from('order_events').insert({
        ...row,
        if (author != null && author.isNotEmpty) 'user_id': author,
      });
    } catch (e, st) {
      if (e is PostgrestException && e.code == '23503') {
        // Заказ уже удалён/не записан — не считаем это фатальной ошибкой.
        debugPrint('⚠️ logOrderEvent skipped (missing order_id=$orderId)');
        return;
      }
      // Автор мог не подойти колонке: у техлида служебный id 'tech_leader', и
      // если user_id в базе типа uuid, вставка падает ЦЕЛИКОМ — вместе с
      // текстом правки. Запись о том, что изменилось, дороже подписи, поэтому
      // повторяем без автора: иначе история молча теряет событие.
      if (author != null && author.isNotEmpty) {
        try {
          await _supabase.from('order_events').insert(row);
          debugPrint('⚠️ logOrderEvent: автор "$author" не принят колонкой '
              'user_id, событие записано без него ($e)');
          return;
        } catch (retryError) {
          debugPrint('❌ logOrderEvent retry error: $retryError');
        }
      }
      debugPrint('❌ logOrderEvent error: $e\n$st');
    }
  }

  /// Возвращает список событий истории по идентификатору заказа.
  Future<List<Map<String, dynamic>>> fetchOrderHistory(String orderId) async {
    DateTime? _parseTimestamp(dynamic value) {
      if (value == null) return null;
      if (value is int) {
        return DateTime.fromMillisecondsSinceEpoch(
            normalizeEpochToMillis(value));
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
      const trackedTypes = {
        'quantity_stage_total',
        'quantity_done',
        'quantity_team_total',
        'quantity_share'
      };
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
          final DateTime? ts = _parseTimestamp(
              map['created_at'] ?? map['timestamp'] ?? map['inserted_at']);
          combined.add({
            'source': 'order_event',
            'timestamp': ts?.millisecondsSinceEpoch,
            'event_type': _stringOrNull(map['event_type']) ?? '',
            'description': _stringOrNull(map['description']) ??
                _stringOrNull(map['message']) ??
                '',
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
          final String? stageId =
              _stringOrNull(map['stage_id'] ?? map['stageId']);
          final commentsData = map['comments'];
          final List<Map<String, dynamic>> commentsList = [];

          if (commentsData is List) {
            for (final item in commentsData) {
              if (item is Map) {
                commentsList.add(Map<String, dynamic>.from(item));
              }
            }
          } else if (commentsData is Map) {
            commentsData.forEach((key, value) {
              if (value is Map) {
                final item = Map<String, dynamic>.from(value);
                // В map-формате id комментария — ключ узла, не поле значения.
                item.putIfAbsent('id', () => key.toString());
                commentsList.add(item);
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
              'comment_id': _stringOrNull(comment['id']),
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
          final double? shippedQty =
              _toDoubleNullable(orderData['shipped_qty']);
          final double? producedQty =
              _toDoubleNullable(orderData['actual_qty']);
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
