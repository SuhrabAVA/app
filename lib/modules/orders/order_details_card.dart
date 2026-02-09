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
    if (p.widthB != null) parts.add('Ширина Б: ${_fmtNum(p.widthB)}');
    final hasQty = p.blQuantity != null && p.blQuantity!.isNotEmpty;
    if (p.length != null) {
      parts.add(
        hasQty
            ? 'Длина: ${p.blQuantity}*${_fmtNum(p.length)}'
            : 'Длина: ${_fmtNum(p.length)}',
      );
    } else if (hasQty) {
      parts.add('Количество: ${p.blQuantity}');
    }
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
    return parts.isEmpty ? '—' : parts.join(', ');
  }

  String _statusLabel(String? status) {
    final normalized = (status ?? '').trim();
    switch (normalized) {
      case 'newOrder':
        return 'Новый';
      case 'inWork':
        return 'В работе';
      case 'completed':
        return 'Завершен';
      default:
        return normalized.isEmpty ? '—' : normalized;
    }
  }

  @override
  Widget build(BuildContext context) {
    final o = order;
    final p = o.product;
    final additionalDimensions = _additionalDimensions();
    final paintsWidget = paints.isEmpty
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
          );
    final materialWidget = Column(
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
    );

    return LayoutBuilder(
      builder: (context, constraints) {
        const spacing = 16.0;
        final maxWidth = constraints.maxWidth;
        final columns = maxWidth >= 900
            ? 3
            : maxWidth >= 760
                ? 2
                : 1;
        final sectionWidth = columns == 1
            ? maxWidth
            : (maxWidth - spacing * (columns - 1)) / columns;

        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Wrap(
              spacing: spacing,
              runSpacing: spacing,
              children: [
                SizedBox(
                  width: sectionWidth,
                  child: _buildSectionCard(
                    title: 'Основная информация',
                    icon: Icons.description_outlined,
                    backgroundColor: const Color(0xFFE7FBF3),
                    accentColor: const Color(0xFF21B37B),
                    child: Column(
                      children: [
                        _buildInfoRow('Дата заказа', _fmtDate(o.orderDate)),
                        _buildInfoRow(
                            'Срок выполнения', _fmtDate(o.dueDate)),
                        _buildInfoRow(
                            'Заказчик', o.customer.isEmpty ? '—' : o.customer),
                        _buildInfoRow('Тип продукта',
                            p.type.isEmpty ? '—' : p.type),
                        _buildInfoRow('Тираж',
                            p.quantity > 0 ? p.quantity.toString() : '—'),
                        _buildInfoRow('Размеры', _dimensionsSummary()),
                        _buildInfoRow(
                            'Ручки', o.handle.isEmpty ? '—' : o.handle),
                        _buildInfoRow(
                            'Картон', o.cardboard.isEmpty ? '—' : o.cardboard),
                        _buildInfoRow(
                          'Подрезка',
                          o.additionalParams.contains('Подрезка') ? 'Да' : 'Нет',
                        ),
                      ],
                    ),
                  ),
                ),
                SizedBox(
                  width: sectionWidth,
                  child: _buildSectionCard(
                    title: 'Печать',
                    icon: Icons.print_outlined,
                    backgroundColor: const Color(0xFFFFF4DE),
                    accentColor: const Color(0xFFF4A12F),
                    child: Column(
                      children: [
                        _buildInfoRowWidget('Краски', paintsWidget),
                        _buildInfoRowWidget(
                          'Форма',
                          Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text('Код формы: ${o.formCode ?? '—'}'),
                              Text('Серия: ${o.formSeries ?? '—'}'),
                              Text('Номер: ${o.newFormNo?.toString() ?? '—'}'),
                              Text(
                                  'Старая форма: ${o.isOldForm ? 'Да' : 'Нет'}'),
                            ],
                          ),
                        ),
                        _buildInfoRowWidget(
                          'Файлы',
                          Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              if (loadingFiles)
                                const Padding(
                                  padding: EdgeInsets.only(bottom: 8.0),
                                  child: LinearProgressIndicator(),
                                ),
                              if (!loadingFiles && files.isEmpty)
                                const Text('Нет приложенных файлов'),
                              ...files.map((f) => _fileTile(context, f)).toList(),
                            ],
                          ),
                          alignEnd: false,
                        ),
                      ],
                    ),
                  ),
                ),
                SizedBox(
                  width: sectionWidth,
                  child: _buildSectionCard(
                    title: 'Бобинорезка',
                    icon: Icons.content_cut,
                    backgroundColor: const Color(0xFFEFEAFF),
                    accentColor: const Color(0xFF7A4CF0),
                    child: Column(
                      children: [
                        _buildInfoRowWidget('Материал', materialWidget),
                        if (additionalDimensions.isNotEmpty)
                          _buildInfoRow(
                              'Доп. размеры', additionalDimensions),
                        _buildInfoRow('Приладка',
                            o.makeready > 0 ? _fmtNum(o.makeready) : '—'),
                        _buildInfoRow(
                            'Комментарий',
                            o.comments.isEmpty ? '—' : o.comments),
                        _buildInfoRowWidget(
                          'Очередь',
                          Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text('Статус: ${_statusLabel(o.status)}'),
                              Text(
                                'Шаблон этапов: ${stageTemplateName ?? o.stageTemplateId ?? '—'}',
                              ),
                            ],
                          ),
                        ),
                        _buildInfoRow(
                            'Менеджер',
                            o.manager.isEmpty ? '—' : o.manager),
                      ],
                    ),
                  ),
                ),
              ],
            ),
            if (extraSections.isNotEmpty) ...[
              const SizedBox(height: 16),
              _buildSectionCard(
                title: 'Дополнительно',
                icon: Icons.info_outline,
                backgroundColor: const Color(0xFFF6F7FB),
                accentColor: const Color(0xFF5B6B8A),
                child: Column(children: extraSections),
              ),
            ],
          ],
        );
      },
    );
  }

  Widget _buildInfoRow(String label, String value) {
    return _buildInfoRowWidget(
      label,
      Text(value, textAlign: TextAlign.right),
    );
  }

  Widget _buildInfoRowWidget(String label, Widget child,
      {bool alignEnd = true}) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Text(
              label,
              style: const TextStyle(
                fontWeight: FontWeight.w600,
                color: Color(0xFF1F2A37),
              ),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: DefaultTextStyle(
              style: const TextStyle(color: Color(0xFF111827)),
              child: alignEnd
                  ? Align(
                      alignment: Alignment.centerRight,
                      child: SizedBox(width: double.infinity, child: child),
                    )
                  : child,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSectionCard({
    required String title,
    required IconData icon,
    required Color backgroundColor,
    required Color accentColor,
    required Widget child,
  }) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: backgroundColor,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: accentColor.withOpacity(0.35)),
        boxShadow: [
          BoxShadow(
            color: accentColor.withOpacity(0.12),
            blurRadius: 12,
            offset: const Offset(0, 6),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: accentColor,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Icon(icon, color: Colors.white, size: 20),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  title,
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w700,
                    color: accentColor.withOpacity(0.95),
                  ),
                ),
              ),
            ],
          ),
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 10),
            child: Divider(height: 1),
          ),
          child,
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
