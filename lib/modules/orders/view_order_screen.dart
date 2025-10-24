import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'order_model.dart';
import '../../services/storage_service.dart' as storage;
import 'package:url_launcher/url_launcher.dart';

import 'orders_repository.dart';

class ViewOrderScreen extends StatefulWidget {
  final OrderModel order;
  const ViewOrderScreen({super.key, required this.order});

  @override
  State<ViewOrderScreen> createState() => _ViewOrderScreenState();
}

class _ViewOrderScreenState extends State<ViewOrderScreen> {
  final _date = DateFormat('dd.MM.yyyy');
  bool _loadingFiles = false;
  List<Map<String, dynamic>> _files = const [];
  List<Map<String, dynamic>> _paints = const [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loadingFiles = true);
    try {
      final repo = OrdersRepository();
      final paints = await repo.getPaints(widget.order.id);
      final files = await storage.listOrderFiles(widget.order.id);
      setState(() {
        _paints = paints;
        _files = files;
      });
    } catch (_) {
      // ignore
    } finally {
      if (mounted) setState(() => _loadingFiles = false);
    }
  }

  String _fmtDate(DateTime? d) => d == null ? '—' : _date.format(d);
  String _fmtNum(num? v) =>
      v == null ? '—' : (v % 1 == 0 ? v.toInt().toString() : v.toString());

  String _formatGrams(double grams) {
    final precision = grams % 1 == 0 ? 0 : 2;
    final fixed = grams.toStringAsFixed(precision);
    final trimmed = fixed
        .replaceFirst(RegExp(r'0+$'), '')
        .replaceFirst(RegExp(r'\.$'), '');
    return '$trimmed г';
  }

  @override
  Widget build(BuildContext context) {
    final o = widget.order;
    final p = o.product;
    final m = o.material;
    return Scaffold(
      appBar: AppBar(title: Text('Заказ ${o.id}')),
      body: RefreshIndicator(
        onRefresh: _load,
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            _section('Основное', [
              _kv('Заказчик', o.customer),
              _kv('Менеджер', o.manager.isEmpty ? '—' : o.manager),
              _kv('Дата заказа', _fmtDate(o.orderDate)),
              _kv('Срок', _fmtDate(o.dueDate)),
              _kv('Статус', o.status),
              _kv('Комментарии', o.comments.isEmpty ? '—' : o.comments),
              _kv('Договор подписан', o.contractSigned ? 'Да' : 'Нет'),
              _kv('Оплата', o.paymentDone ? 'Проведена' : 'Нет'),
            ]),
            _section('Продукт', [
              _kv('Вид изделия', p.type),
              _kv('Тираж', p.quantity.toString()),
              _kv('Ширина', _fmtNum(p.width)),
              _kv('Высота', _fmtNum(p.height)),
              _kv('Глубина', _fmtNum(p.depth)),
              _kv('Ширина b', _fmtNum(p.widthB)),
              _kv('Длина L (м)', _fmtNum(p.length)),
              _kv('Параметры', p.parameters.isEmpty ? '—' : p.parameters),
            ]),
            _section('Форма', [
              _kv('Код формы', o.formCode ?? '—'),
              _kv('Серия', o.formSeries ?? '—'),
              _kv('Номер', o.newFormNo?.toString() ?? '—'),
              _kv('Старая форма', o.isOldForm ? 'Да' : 'Нет'),
            ]),
            _section('Материал', [
              _kv('Наименование', m?.name ?? '—'),
              _kv('Формат', m?.format ?? '—'),
              _kv('Грамаж', m?.grammage ?? '—'),
              _kv('Ед.', m?.unit ?? '—'),
              _kv('Кол-во', _fmtNum(m?.quantity)),
            ]),
            _section('Канцелярия', [
              _kv('Ручки', o.handle),
              _kv('Картон', o.cardboard),
            ]),
            _paints.isEmpty
                ? const SizedBox.shrink()
                : _section(
                    'Краски',
                    _paints.map((e) {
                      final name = (e['name'] ?? '').toString();
                      final qty = e['qty_kg'];
                      final memo = (e['info'] ?? '').toString();
                      double? grams;
                      if (qty is num) {
                        grams = qty.toDouble() * 1000;
                      } else if (qty is String && qty.trim().isNotEmpty) {
                        final parsed =
                            double.tryParse(qty.replaceAll(',', '.'));
                        if (parsed != null) {
                          grams = parsed * 1000;
                        }
                      }
                      final v = (grams == null)
                          ? (memo.isEmpty ? '—' : memo)
                          : '${_formatGrams(grams)}${memo.isNotEmpty ? ' ($memo)' : ''}';
                      return _kv(name, v);
                    }).toList()),
            _section('Файлы', [
              if (_loadingFiles) const LinearProgressIndicator(),
              if (!_loadingFiles && _files.isEmpty)
                const Text('Нет приложенных файлов'),
              ..._files.map((f) => _fileTile(f)).toList(),
            ]),
          ],
        ),
      ),
    );
  }

  Widget _section(String title, List<Widget> children) {
    return Card(
      elevation: 1,
      margin: const EdgeInsets.only(bottom: 16),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title,
                style:
                    const TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
            const SizedBox(height: 12),
            ...children,
          ],
        ),
      ),
    );
  }

  Widget _kv(String k, String v) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
              width: 180,
              child: Text(k, style: const TextStyle(color: Colors.black54))),
          const SizedBox(width: 12),
          Expanded(child: Text(v)),
        ],
      ),
    );
  }

  Widget _fileTile(Map<String, dynamic> f) {
    final fileName = (f['filename'] ?? f['name'] ?? 'Файл.pdf').toString();
    final objectPath = (f['objectPath'] ?? f['path'] ?? '').toString();
    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: const Icon(Icons.picture_as_pdf),
      title: Text(fileName),
      trailing: TextButton.icon(
        onPressed: objectPath.isEmpty
            ? null
            : () async {
                final url = await storage.getSignedUrl(objectPath);
                // ignore: use_build_context_synchronously
                showDialog(
                  context: context,
                  builder: (_) => AlertDialog(
                    title: Text(fileName),
                    content: Text('Открыть PDF во внешнем просмотрщике?'),
                    actions: [
                      TextButton(
                          onPressed: () => Navigator.pop(context),
                          child: const Text('Отмена')),
                      TextButton(
                        onPressed: () async {
                          Navigator.pop(context);
                          // Use url_launcher
                          try {
                            await launchUrl(Uri.parse(url),
                                mode: LaunchMode.externalApplication);
                          } catch (_) {}
                        },
                        child: const Text('Открыть'),
                      ),
                    ],
                  ),
                );
              },
        icon: const Icon(Icons.open_in_new),
        label: const Text('Открыть'),
      ),
      subtitle: Text(objectPath),
    );
  }
}
