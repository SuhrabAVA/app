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
    this.formImageUrl,
    this.extraSections = const <Widget>[],
  });

  final OrderModel order;
  final List<Map<String, dynamic>> paints;
  final List<Map<String, dynamic>> files;
  final bool loadingFiles;
  final String? stageTemplateName;
  final String? formImageUrl;
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

  Widget _buildDimensionsValue() {
    final p = order.product;
    final dimensions = <({String label, String value})>[
      if (p.height != null) (label: 'Д', value: _fmtNum(p.height)),
      if (p.width != null) (label: 'Ш', value: _fmtNum(p.width)),
      if (p.depth != null) (label: 'Г', value: _fmtNum(p.depth)),
    ];

    if (dimensions.isEmpty) {
      return const Text('—', textAlign: TextAlign.right);
    }

    return Wrap(
      alignment: WrapAlignment.end,
      spacing: 12,
      runSpacing: 4,
      children: dimensions
          .map(
            (d) => SizedBox(
              width: 30,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  Text(
                    d.label,
                    style: const TextStyle(
                      fontSize: 11,
                      height: 1.1,
                      fontWeight: FontWeight.w600,
                      color: Color(0xFF9CA3AF),
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    d.value,
                    style: const TextStyle(
                      fontSize: 16,
                      height: 1,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
            ),
          )
          .toList(),
    );
  }

  /// Builds a combined row for the "Картон" and "Подрезка" properties. In the
  /// updated design these two fields should appear on one line, separated
  /// evenly across the width of the card. Each side includes its own label
  /// and value. When a value is not provided it falls back to an em dash.
  Widget _buildCardboardTrimRow() {
    final cardboardValue = order.cardboard.isEmpty ? '—' : order.cardboard;
    final trimValue = order.additionalParams.contains('Подрезка') ? 'есть' : 'нет';
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // First half: cardboard
          Expanded(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Картон',
                  style: const TextStyle(
                    fontWeight: FontWeight.w500,
                    color: Color(0xFF9CA3AF),
                  ),
                ),
                const SizedBox(width: 4),
                Expanded(
                  child: Text(
                    cardboardValue,
                    style: const TextStyle(
                      color: Color(0xFF111827),
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          // Second half: trimming
          Expanded(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Подрезка',
                  style: const TextStyle(
                    fontWeight: FontWeight.w500,
                    color: Color(0xFF9CA3AF),
                  ),
                ),
                const SizedBox(width: 4),
                Expanded(
                  child: Text(
                    trimValue,
                    style: const TextStyle(
                      color: Color(0xFF111827),
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  String _additionalDimensions() {
    final p = order.product;
    if (p.widthB == null) return '';
    return _fmtNum(p.widthB);
  }

  String _lengthValue() {
    final p = order.product;
    final hasQty = p.blQuantity != null && p.blQuantity!.isNotEmpty;
    if (p.length != null && hasQty) {
      return '${p.blQuantity}*${_fmtNum(p.length)}';
    }
    if (p.length != null) return _fmtNum(p.length);
    if (hasQty) return p.blQuantity!;
    return '';
  }

  String _materialSummary() {
    final m = order.material;
    if (m == null) return '—';
    final parts = <String>[];
    if (m.name.isNotEmpty) parts.add(m.name);
    if (m.format != null && m.format!.isNotEmpty) parts.add('(${m.format})Ф');
    if (m.grammage != null && m.grammage!.isNotEmpty) {
      parts.add('(${m.grammage})Гр');
    }
    return parts.isEmpty ? '—' : parts.join(' ');
  }

  @override
  Widget build(BuildContext context) {
    final o = order;
    final p = o.product;
    final widthBValue = _additionalDimensions();
    final lengthValue = _lengthValue();
    final paintInfo = paints
        .map((e) => (e['info'] ?? '').toString().trim())
        .where((v) => v.isNotEmpty)
        .toSet()
        .join(', ');
    final paintsWidget = paints.isEmpty
        ? const Text('—')
        : Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (paintInfo.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(bottom: 4),
                  child: Text('Информация: $paintInfo'),
                ),
              ...paints.asMap().entries.map((entry) {
                final index = entry.key;
                final e = entry.value;
                final name = (e['name'] ?? '').toString();
                final qty = e['qty_kg'];
                double? grams;
                if (qty is num) {
                  grams = qty.toDouble() * 1000;
                } else if (qty is String && qty.trim().isNotEmpty) {
                  final parsed = double.tryParse(qty.replaceAll(',', '.'));
                  if (parsed != null) {
                    grams = parsed * 1000;
                  }
                }
                final v = grams == null ? '—' : _formatGrams(grams);
                return Padding(
                  padding: const EdgeInsets.symmetric(vertical: 2.0),
                  child: Text('${index + 1}. $name — $v'),
                );
              }),
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
                        _buildInfoRow(
                          'Дата заказа',
                          '${_fmtDate(o.orderDate)} - ${_fmtDate(o.dueDate)}',
                        ),
                        _buildInfoRow(
                            'Заказчик', o.customer.isEmpty ? '—' : o.customer),
                        _buildInfoRow('Тип продукта',
                            p.type.isEmpty ? '—' : p.type),
                        _buildInfoRow('Тираж',
                            p.quantity > 0 ? p.quantity.toString() : '—'),
                        _buildInfoRowWidget('Размеры', _buildDimensionsValue()),
                        _buildInfoRow(
                            'Ручки', o.handle.isEmpty ? '—' : o.handle),
                        // Use a combined row for "Картон" and "Подрезка" to align them on one
                        // line with their own labels and values. This replaces two separate
                        // rows in the old design.
                        _buildCardboardTrimRow(),
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
                              Text(
                                '${o.isOldForm ? 'Старая форма' : 'Новая форма'}: ${o.newFormNo?.toString() ?? '—'}',
                              ),
                              if (formImageUrl != null &&
                                  formImageUrl!.trim().isNotEmpty)
                                Padding(
                                  padding: const EdgeInsets.only(top: 8),
                                  child: ClipRRect(
                                    borderRadius: BorderRadius.circular(8),
                                    child: Image.network(
                                      formImageUrl!,
                                      height: 90,
                                      fit: BoxFit.cover,
                                      errorBuilder: (_, __, ___) =>
                                          const Text('Изображение формы недоступно'),
                                    ),
                                  ),
                                ),
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
                        _buildInfoRow('Материал', _materialSummary()),
                        if (widthBValue.isNotEmpty)
                          _buildInfoRow('Ширина B', widthBValue),
                        if (lengthValue.isNotEmpty)
                          _buildInfoRow('Длина L', lengthValue),
                        _buildInfoRow('Приладка',
                            o.makeready > 0 ? _fmtNum(o.makeready) : '—'),
                        _buildInfoRow('ВАЛ', o.val > 0 ? _fmtNum(o.val) : '—'),
                        _buildInfoRow(
                            'Комментарий',
                            o.comments.isEmpty ? '—' : o.comments),
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
                fontWeight: FontWeight.w500,
                color: Color(0xFF9CA3AF),
              ),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: DefaultTextStyle(
              // Apply a bold style to the value portion. According to the
              // updated design, all content following the colon (i.e. the
              // values) should be emphasized with a heavier font weight.
              style: const TextStyle(
                color: Color(0xFF111827),
                fontWeight: FontWeight.w600,
              ),
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
    final fileName = (f['filename'] ?? f['name'] ?? 'Файл.pdf')
        .toString()
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    final objectPath = (f['objectPath'] ?? f['path'] ?? '').toString();
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4.0),
      child: Row(
        children: [
          const Icon(Icons.picture_as_pdf, size: 18),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              fileName.isEmpty ? 'Файл.pdf' : fileName,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
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
