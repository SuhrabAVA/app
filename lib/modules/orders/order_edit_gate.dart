import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'order_edit_lease.dart';
import 'order_model.dart';

/// Состояние шлюза. Разделено явно: «блокировки нет на сервере» и «заказ занят
/// другим» выглядели одинаково (`ready == false`), из-за чего форма в режиме
/// совместимости запиралась пустым экраном, стоило скрыть предупреждение.
enum _GateMode { loading, editing, compatibility, busy, failed }

/// No form (including its async initializers) exists before acquisition and reload.
class OrderEditGate extends StatefulWidget {
  const OrderEditGate({
    super.key,
    required this.orderId,
    required this.builder,
    this.fallbackBuilder,
    this.initialOrder,
    this.client,
  });
  final String orderId;
  final Widget Function(OrderModel order, OrderEditLease lease) builder;
  final Widget Function(OrderModel order)? fallbackBuilder;
  final OrderModel? initialOrder;
  final SupabaseClient? client;

  @override
  State<OrderEditGate> createState() => _OrderEditGateState();
}

class _OrderEditGateState extends State<OrderEditGate>
    with WidgetsBindingObserver {
  late OrderEditLease _lease;
  late final SupabaseClient _client;
  Widget? _editor;
  String? _error;
  String? _warning;
  _GateMode _mode = _GateMode.loading;
  bool _checkingResume = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _client = widget.client ?? Supabase.instance.client;
    _lease = OrderEditLease(widget.orderId, client: _client)
      ..addListener(_changed);
    _open();
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) async {
    if (state == AppLifecycleState.resumed && _mode == _GateMode.editing) {
      setState(() => _checkingResume = true);
      await _lease.renew();
      if (mounted) setState(() => _checkingResume = false);
    }
  }

  Future<OrderModel?> _reload() async {
    final row = await _client
        .from('orders')
        .select()
        .eq('id', widget.orderId)
        .maybeSingle()
        .timeout(const Duration(seconds: 10));
    return row == null ? null : OrderModel.fromMap(row);
  }

  Future<void> _open() async {
    try {
      final status = await _lease.acquire();
      if (!mounted) return;
      if (status == OrderEditLeaseStatus.busy) {
        setState(() => _mode = _GateMode.busy);
        return;
      }
      final fresh = await _reload();
      if (!mounted) return;
      if (status == OrderEditLeaseStatus.acquired) {
        if (fresh == null) {
          setState(() {
            _mode = _GateMode.failed;
            _error = 'Заказ не найден: возможно, его удалили.';
          });
          return;
        }
        setState(() {
          _editor = widget.builder(fresh, _lease);
          _mode = _GateMode.editing;
        });
        return;
      }
      // Серверной блокировки нет. Заказ всё равно нужно открыть: без неё
      // приложение работает ровно так же, как до появления блокировки.
      final stale = fresh ?? widget.initialOrder;
      if (widget.fallbackBuilder == null || stale == null) {
        setState(() {
          _mode = _GateMode.failed;
          _error = 'Заказ не найден: возможно, его удалили.';
        });
        return;
      }
      setState(() {
        _editor = widget.fallbackBuilder!(stale);
        _mode = _GateMode.compatibility;
        _warning = 'Блокировка редактирования ещё не установлена на сервере. '
            'Не открывайте этот заказ одновременно на двух устройствах.';
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _mode = _GateMode.failed;
        _error = 'Не удалось проверить блокировку или загрузить заказ: $error';
      });
    }
  }

  Future<void> _retry() async {
    _lease.removeListener(_changed);
    _lease.dispose();
    setState(() {
      _lease = OrderEditLease(widget.orderId, client: _client)
        ..addListener(_changed);
      _mode = _GateMode.loading;
      _error = null;
    });
    await _open();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _lease.removeListener(_changed);
    _lease.dispose();
    super.dispose();
  }

  Widget _message(String text, {bool retry = false}) => Scaffold(
        appBar: AppBar(title: const Text('Редактирование заказа')),
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(text, textAlign: TextAlign.center),
                if (retry) ...[
                  const SizedBox(height: 16),
                  TextButton(
                      onPressed: _retry, child: const Text('Повторить')),
                ],
              ],
            ),
          ),
        ),
      );

  @override
  Widget build(BuildContext context) {
    switch (_mode) {
      case _GateMode.loading:
        return Scaffold(
          appBar: AppBar(title: const Text('Редактирование заказа')),
          body: const Center(child: CircularProgressIndicator()),
        );
      case _GateMode.busy:
        return _message(_lease.message, retry: true);
      case _GateMode.failed:
        return _message(_error ?? 'Не удалось открыть заказ.', retry: true);
      case _GateMode.compatibility:
        // Блокировки нет — форма работает целиком. Предупреждение только
        // сообщает об этом и закрывается без последствий.
        return Column(children: [
          if (_warning != null)
            Material(
              child: MaterialBanner(
                content: Text(_warning!),
                leading: const Icon(Icons.warning_amber_rounded),
                actions: [
                  TextButton(
                    onPressed: () => setState(() => _warning = null),
                    child: const Text('Скрыть'),
                  ),
                ],
              ),
            ),
          Expanded(child: _editor!),
        ]);
      case _GateMode.editing:
        final locked = !_lease.ready || _checkingResume;
        return Stack(children: [
          AbsorbPointer(absorbing: locked, child: _editor!),
          if (locked)
            Positioned.fill(
                child: ColoredBox(
              color:
                  Theme.of(context).colorScheme.surface.withValues(alpha: 0.9),
              child: Center(
                  child: Material(
                      child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(mainAxisSize: MainAxisSize.min, children: [
                  Text(
                      _checkingResume
                          ? 'Проверяем блокировку…'
                          : _lease.message,
                      textAlign: TextAlign.center),
                  const SizedBox(height: 16),
                  TextButton(
                      onPressed: () => Navigator.of(context).maybePop(),
                      child: const Text('Закрыть редактор')),
                ]),
              ))),
            )),
        ]);
    }
  }
}
