import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../services/storage_service.dart' as storage;
import 'order_model.dart';

class OrderDetailsCard extends StatelessWidget {
  const OrderDetailsCard({
    super.key,
    required this.order,
    required this.paints,
    required this.files,
    required this.loadingFiles,
    required this.stageTemplateName,
    this.extraSections = const <Widget>[],
  });

  final OrderModel order;
  final List<Map<String, dynamic>> paints;
  final List<Map<String, dynamic>> files;
  final bool loadingFiles;
  final String? stageTemplateName;
  final List<Widget> extraSections;

  String _fmtDate(DateTime? d) =>
      d == null ? '—' : DateFormat('dd.MM.yyyy').format(d);

  String _fmtNum(num? v) =>
      v == null ? '—' : (v % 1 == 0 ? v.toInt().toString() : v.toString());

  String _formatGrams(double grams) {
    final precision = grams % 1 == 0 ? 0 : 2;
    final fixed = grams.toStringAsFixed(precision);
    final trimmed =
        fixed.replaceFirst(RegExp(r'0+$'), '').replaceFirst(RegExp(r'\.$'), '');
    return '$trimmed г';
  }

  String _dimensionsSummary() {
    final p = order.product;
    final parts = <String>[];
    if (p.width != null || p.height != null || p.depth != null) {
      final dims = [p.width, p.height, p.depth]
          .where((v) => v != null)
          .map((v) => _fmtNum(v))
          .join(' × ');
      if (dims.isNotEmpty) parts.add(dims);
    }
    return parts.isEmpty ? '—' : parts.join(', ');
  }

  String _additionalDimensions() {
    final p = order.product;
    final parts = <String>[];
    if (p.widthB != null) parts.add('Ширина b: ${_fmtNum(p.widthB)}');
    if (p.blQuantity != null && p.blQuantity!.isNotEmpty) {
      parts.add('Количество: ${p.blQuantity}');
    }
    if (p.length != null) parts.add('Длина L: ${_fmtNum(p.length)}');
    return parts.join(', ');
  }

  String _materialSummary() {
    final m = order.material;
    if (m == null) return '—';
    final parts = <String>[];
    if (m.name.isNotEmpty) parts.add(m.name);
    if (m.format != null && m.format!.isNotEmpty) parts.add('Формат: ${m.format}');
    if (m.grammage != null && m.grammage!.isNotEmpty) {
      parts.add('Грамаж: ${m.grammage}');
    }
    if (m.unit != null && m.unit!.isNotEmpty) parts.add('Ед.: ${m.unit}');
    if (m.quantity != null) parts.add('Кол-во: ${_fmtNum(m.quantity)}');
    return parts.isEmpty ? '—' : parts.join(', ');
  }

  @override
  Widget build(BuildContext context) {
    final o = order;
    final p = o.product;
    final additionalDimensions = _additionalDimensions();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _buildLabelRow(
          label: 'Дата',
          child: Row(
            children: [
              Expanded(child: _valueBlock('Дата заказа', _fmtDate(o.orderDate))),
              const SizedBox(width: 8),
              Expanded(
                child: _valueBlock('Срок выполнения', _fmtDate(o.dueDate)),
              ),
            ],
          ),
        ),
        _buildLabelRow(label: 'Заказчик', child: Text(o.customer)),
        _buildLabelRow(
            label: 'Тип', child: Text(p.type.isEmpty ? '—' : p.type)),
        _buildLabelRow(
            label: 'Тираж',
            child: Text(p.quantity > 0 ? p.quantity.toString() : '—')),
        _buildLabelRow(label: 'Размеры', child: Text(_dimensionsSummary())),
        _buildLabelRow(
          label: 'Ручки и картон',
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Ручки: ${o.handle}'),
              Text('Картон: ${o.cardboard}'),
            ],
          ),
        ),
        const Divider(height: 3),
        _buildLabelRow(
          label: 'Краски',
          child: paints.isEmpty
              ? const Text('—')
              : Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: paints.map((e) {
                    final name = (e['name'] ?? '').toString();
                    final qty = e['qty_kg'];
                    final memo = (e['info'] ?? '').toString();
                    double? grams;
                    if (qty is num) {
                      grams = qty.toDouble() * 1000;
                    } else if (qty is String && qty.trim().isNotEmpty) {
                      final parsed = double.tryParse(qty.replaceAll(',', '.'));
                      if (parsed != null) {
                        grams = parsed * 1000;
                      }
                    }
                    final v = (grams == null)
                        ? (memo.isEmpty ? '—' : memo)
                        : '${_formatGrams(grams)}${memo.isNotEmpty ? ' ($memo)' : ''}';
                    return Padding(
                      padding: const EdgeInsets.symmetric(vertical: 2.0),
                      child: Text('$name: $v'),
                    );
                  }).toList(),
                ),
        ),
        const Divider(height: 3),
        _buildLabelRow(
          label: 'Форма',
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Код формы: ${o.formCode ?? '—'}'),
              Text('Серия: ${o.formSeries ?? '—'}'),
              Text('Номер: ${o.newFormNo?.toString() ?? '—'}'),
              Text('Старая форма: ${o.isOldForm ? 'Да' : 'Нет'}'),
            ],
          ),
        ),
        const Divider(height: 3),
        _buildLabelRow(
          label: 'Склад и материалы',
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(_materialSummary()),
              if (p.parameters.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 2.0),
                  child: Text('Параметры: ${p.parameters}'),
                ),
              if (p.leftover != null) Text('Лишнее: ${_fmtNum(p.leftover)}'),
            ],
          ),
        ),
        if (additionalDimensions.isNotEmpty)
          _buildLabelRow(
            label: 'Доп. размеры',
            child: Text(additionalDimensions),
          ),
        const Divider(height: 3),
        _buildLabelRow(
          label: 'Приладка',
          child: Text(o.makeready > 0 ? _fmtNum(o.makeready) : '—'),
        ),
        _buildLabelRow(
          label: 'Комментарий',
          child: Text(o.comments.isEmpty ? '—' : o.comments),
        ),
        _buildLabelRow(
          label: 'Очередь',
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Статус: ${o.status}'),
              Text(
                'Шаблон этапов: ${stageTemplateName ?? o.stageTemplateId ?? '—'}',
              ),
            ],
          ),
        ),
        _buildLabelRow(
          label: 'Договоры',
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Договор подписан: ${o.contractSigned ? 'Да' : 'Нет'}'),
              Text('Оплата: ${o.paymentDone ? 'Проведена' : 'Нет'}'),
            ],
          ),
        ),
        _buildLabelRow(
          label: 'Менеджер',
          child: Text(o.manager.isEmpty ? '—' : o.manager),
        ),
        const Divider(height: 3),
        _buildLabelRow(
          label: 'Файлы',
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (loadingFiles) const LinearProgressIndicator(),
              if (!loadingFiles && files.isEmpty)
                const Text('Нет приложенных файлов'),
              ...files.map((f) => _fileTile(context, f)).toList(),
            ],
          ),
        ),
        if (extraSections.isNotEmpty) ...[
          const Divider(height: 3),
          ...extraSections,
        ],
      ],
    );
  }

  Widget _valueBlock(String title, String value) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title,
          style: const TextStyle(fontSize: 12, color: Colors.black54),
        ),
        const SizedBox(height: 2),
        Text(value, style: const TextStyle(fontWeight: FontWeight.w600)),
      ],
    );
  }

  Widget _buildLabelRow({
    required String label,
    required Widget child,
    double labelWidth = 150,
  }) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: labelWidth,
            child: Text(
              label,
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(child: child),
        ],
      ),
    );
  }

  Widget _fileTile(BuildContext context, Map<String, dynamic> f) {
    final fileName = (f['filename'] ?? f['name'] ?? 'Файл.pdf').toString();
    final objectPath = (f['objectPath'] ?? f['path'] ?? '').toString();
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4.0),
      child: Row(
        children: [
          const Icon(Icons.picture_as_pdf, size: 18),
          const SizedBox(width: 8),
          Expanded(child: Text(fileName)),
          TextButton.icon(
            onPressed: objectPath.isEmpty
                ? null
                : () async {
                    final url = await storage.getSignedUrl(objectPath);
                    if (!context.mounted) return;
                    showDialog(
                      context: context,
                      builder: (_) => AlertDialog(
                        title: Text(fileName),
                        content:
                            const Text('Открыть PDF во внешнем просмотрщике?'),
                        actions: [
                          TextButton(
                            onPressed: () => Navigator.pop(context),
                            child: const Text('Отмена'),
                          ),
                          TextButton(
                            onPressed: () async {
                              Navigator.pop(context);
                              try {
                                await launchUrl(
                                  Uri.parse(url),
                                  mode: LaunchMode.externalApplication,
                                );
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
        ],
      ),
    );
  }
}
