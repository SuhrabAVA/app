import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:uuid/uuid.dart';

import '../../services/order_edit_http_client.dart';
import '../../utils/auth_helper.dart';

/// Чем закончилась попытка занять заказ.
enum OrderEditLeaseStatus {
  /// Заказ занят этим редактором: можно править и сохранять.
  acquired,

  /// Заказ уже правит другой сотрудник.
  busy,

  /// Серверной части блокировки нет — миграция
  /// `20260916064742_order_edit_leases.sql` не применена к базе. Приложение
  /// работает как до появления блокировки: заказ открывается и сохраняется,
  /// но одновременное редактирование ничем не защищено.
  unavailable,
}

/// Одна на всё приложение отметка «серверные функции блокировки есть».
///
/// Без неё каждый экран самостоятельно ходил бы за несуществующей функцией:
/// список заказов — раз в две секунды, форма — при каждом открытии, создание
/// заказа — посреди сохранения. Первый же ответ «функции нет» выключает опрос.
class OrderEditLockSupport {
  OrderEditLockSupport._();

  static bool installed = true;

  /// Ошибка означает, что функции блокировки нет в базе.
  ///
  /// PostgREST отвечает `PGRST202` («не найдено в кеше схемы»), сам Postgres —
  /// `42883` («функция не существует»).
  static bool isNotInstalled(Object error) {
    if (error is! PostgrestException) return false;
    if (error.code == 'PGRST202' || error.code == '42883') return true;
    return error.code == '404' && error.message.contains('order_edit');
  }

  /// Сервер отказал из-за отсутствия входа: функции блокировки доступны только
  /// вошедшему пользователю.
  ///
  /// Автовход по `.env` в `main.dart` молча проглатывает ошибку, поэтому
  /// приложение может работать и без сессии. До блокировки такое устройство
  /// спокойно правило заказы — пусть правит и дальше, а не упирается в ошибку.
  /// Общий флаг [installed] при этом не сбрасывается: вход может появиться.
  static bool isNotPermitted(Object error) =>
      error is PostgrestException &&
      (error.code == '42501' ||
          error.code == 'PGRST301' ||
          error.code == '401' ||
          error.code == '403');
}

class OrderEditLease extends ChangeNotifier {
  OrderEditLease(this.orderId, {SupabaseClient? client})
      : _client = client ?? Supabase.instance.client;

  final String orderId;
  final SupabaseClient _client;
  final String token = const Uuid().v4();
  final int _session = AuthHelper.sessionRevision.value;
  Timer? _timer;
  Future<bool>? _renewing;
  bool _closed = false;
  bool _lost = false;
  bool _owned = false;
  bool _unavailable = false;
  bool ready = false;
  String message = 'Проверяем, свободен ли заказ…';

  /// Серверной блокировки нет: экран работает в режиме совместимости.
  bool get unavailable => _unavailable;

  Map<String, dynamic> get _params => {
        'p_order_id': orderId,
        'p_token': token,
      };

  Future<OrderEditLeaseStatus> acquire() async {
    if (!OrderEditLockSupport.installed) return _markUnavailable();
    final Map<String, dynamic> result;
    try {
      result = Map<String, dynamic>.from(await _client.rpc(
        'acquire_order_edit',
        params: {
          ..._params,
          'p_editor_name': AuthHelper.currentUserName ?? 'Сотрудник'
        },
      ).timeout(const Duration(seconds: 10)));
    } on PostgrestException catch (error) {
      if (OrderEditLockSupport.isNotInstalled(error)) {
        OrderEditLockSupport.installed = false;
        return _markUnavailable();
      }
      if (OrderEditLockSupport.isNotPermitted(error)) return _markUnavailable();
      rethrow;
    }
    _owned = result['acquired'] == true;
    if (_closed) {
      if (_owned) await _release();
      return OrderEditLeaseStatus.busy;
    }
    if (_session != AuthHelper.sessionRevision.value) {
      _lost = true;
      message = 'Сотрудник сменился. Откройте заказ заново.';
      if (_owned) await _release();
      return OrderEditLeaseStatus.busy;
    }
    ready = _owned;
    message = ready
        ? ''
        : 'Заказ редактирует ${result['editor_name'] ?? 'другой сотрудник'}. '
            'Дождитесь сохранения изменений.';
    if (ready) {
      OrderEditTokens.active[orderId] = token;
      _timer = Timer.periodic(const Duration(seconds: 20), (_) => renew());
      AuthHelper.sessionRevision.addListener(_onSessionChanged);
    }
    notifyListeners();
    return ready ? OrderEditLeaseStatus.acquired : OrderEditLeaseStatus.busy;
  }

  OrderEditLeaseStatus _markUnavailable() {
    _unavailable = true;
    ready = false;
    message = '';
    notifyListeners();
    return OrderEditLeaseStatus.unavailable;
  }

  void _onSessionChanged() {
    if (_session != AuthHelper.sessionRevision.value) {
      _lost = true;
      ready = false;
      message = 'Сотрудник вышел из системы. Откройте заказ заново.';
      _timer?.cancel();
      notifyListeners();
      // Keep the capability registered until this editor is disposed. Any
      // outstanding requests then carry an expired/released token and fail.
      unawaited(_release());
    }
  }

  Future<bool> renew() {
    // Режим совместимости: продлевать нечего, и запрет сохранения был бы
    // запретом работать вообще.
    if (_unavailable) return Future.value(true);
    if (_closed || _lost) return Future.value(false);
    return _renewing ??= _renew().whenComplete(() => _renewing = null);
  }

  Future<bool> _renew() async {
    try {
      final ok = await _client
              .rpc('renew_order_edit', params: _params)
              .timeout(const Duration(seconds: 10)) ==
          true;
      if (_closed || _lost) return false;
      ready = ok;
      if (!ok) {
        _lost = true;
        _timer?.cancel();
        message =
            'Блокировка истекла. Изменения остались на экране, но сохранить '
            'их нельзя. Откройте заказ заново, чтобы загрузить актуальные данные.';
      } else {
        message = '';
      }
    } catch (error) {
      if (_closed || _lost) return false;
      // Функции убрали из базы уже после захвата — вести себя как при её
      // отсутствии честнее, чем держать форму запертой навсегда.
      if (OrderEditLockSupport.isNotInstalled(error)) {
        OrderEditLockSupport.installed = false;
        _timer?.cancel();
        _markUnavailable();
        return true;
      }
      ready = false;
      message =
          'Нет связи с сервером. Редактирование приостановлено до проверки блокировки.';
    }
    notifyListeners();
    return ready;
  }

  Future<void> ensureOwned() async {
    if (!await renew()) throw StateError(message);
  }

  Future<void> _release() async {
    try {
      await _client
          .rpc('release_order_edit', params: _params)
          .timeout(const Duration(seconds: 10));
    } catch (_) {
      // The server lease expires after 90 seconds even after an app crash.
    }
  }

  @override
  void dispose() {
    _closed = true;
    _timer?.cancel();
    AuthHelper.sessionRevision.removeListener(_onSessionChanged);
    if (_owned) {
      unawaited(_release().whenComplete(() {
        if (OrderEditTokens.active[orderId] == token) {
          OrderEditTokens.active.remove(orderId);
        }
      }));
    }
    super.dispose();
  }
}
