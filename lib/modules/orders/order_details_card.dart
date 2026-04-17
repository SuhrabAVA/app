import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../services/storage_service.dart' as storage;
import 'material_model.dart';
import 'order_model.dart';

class OrderDetailsCard extends StatelessWidget {
  const OrderDetailsCard({
    super.key,
    required this.order,
    required this.paints,
    required this.files,
    required this.stageTemplateName,
    this.formImageUrl,
    this.extraSections = const <Widget>[],
  });

  final OrderModel order;
  final List<Map<String, dynamic>> paints;
  final List<Map<String, dynamic>> files;
  final String? stageTemplateName;
  final String? formImageUrl;
  final List<Widget> extraSections;

  String _fmtDate(DateTime? d) =>
      d == null ? '—' : DateFormat('dd.MM.yyyy').format(d);

  String _fmtNum(num? v) =>
      v == null ? '—' : (v % 1 == 0 ? v.toInt().toString() : v.toString());

  static const double _compactCellScale = 0.8;
  static const double _compactTextScale = 0.65;

  String _trimTrailingFractionZeros(String value) {
    if (!value.contains('.')) return value;
    return value
        .replaceFirst(RegExp(r'0+$'), '')
        .replaceFirst(RegExp(r'\.$'), '');
  }

  String _formatGrams(double grams) {
    final precision = grams % 1 == 0 ? 0 : 2;
    final fixed = grams.toStringAsFixed(precision);
    final trimmed = _trimTrailingFractionZeros(fixed);
    return '$trimmed г';
  }

  bool _isImageFile(String fileName, String objectPath) {
    final normalized = '$fileName $objectPath'.toLowerCase();
    return normalized.endsWith('.png') ||
        normalized.endsWith('.jpg') ||
        normalized.endsWith('.jpeg') ||
        normalized.endsWith('.webp') ||
        normalized.endsWith('.gif') ||
        normalized.endsWith('.bmp') ||
        normalized.endsWith('.heic') ||
        normalized.endsWith('.heif') ||
        normalized.contains('.png?') ||
        normalized.contains('.jpg?') ||
        normalized.contains('.jpeg?') ||
        normalized.contains('.webp?') ||
        normalized.contains('.gif?') ||
        normalized.contains('.bmp?') ||
        normalized.contains('.heic?') ||
        normalized.contains('.heif?');
  }

  Future<void> _showImagePreview(
    BuildContext context,
    String imageUrl, {
    String title = 'Просмотр изображения',
  }) async {
    if (!context.mounted) return;

    await showDialog<void>(
      context: context,
      builder: (_) => Dialog(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 900, maxHeight: 700),
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 8, 8),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontWeight: FontWeight.w600),
                      ),
                    ),
                    IconButton(
                      tooltip: 'Закрыть',
                      onPressed: () => Navigator.pop(context),
                      icon: const Icon(Icons.close),
                    ),
                  ],
                ),
              ),
              const Divider(height: 1),
              Expanded(
                child: InteractiveViewer(
                  minScale: 0.6,
                  maxScale: 5,
                  child: Center(
                    child: Image.network(
                      imageUrl,
                      fit: BoxFit.contain,
                      errorBuilder: (_, __, ___) => const Padding(
                        padding: EdgeInsets.all(24),
                        child: Text('Не удалось загрузить изображение'),
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildDimensionsValue({bool compact = false}) {
    final p = order.product;
    final dimensions = <({String label, String value})>[
      if (p.width != null) (label: 'Д', value: _fmtNum(p.width)),
      if (p.height != null) (label: 'Ш', value: _fmtNum(p.height)),
      if (p.depth != null) (label: 'Г', value: _fmtNum(p.depth)),
    ];

    if (dimensions.isEmpty) {
      return Text(
        '—',
        textAlign: TextAlign.right,
        style: compact ? const TextStyle(fontSize: 14 * _compactTextScale) : null,
      );
    }

    final labelFontSize = compact ? 11 * _compactTextScale : 11.0;
    final valueFontSize = compact ? 16 * _compactTextScale : 16.0;
    final cellWidth = compact ? 30 * _compactCellScale : 30.0;
    final verticalGap = compact ? 2 * _compactCellScale : 2.0;

    return Wrap(
      alignment: WrapAlignment.end,
      spacing: compact ? 12 * _compactCellScale : 12,
      runSpacing: compact ? 4 * _compactCellScale : 4,
      children: dimensions
          .map(
            (d) => SizedBox(
              width: cellWidth,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  Text(
                    d.label,
                    style: TextStyle(
                      fontSize: labelFontSize,
                      height: 1.1,
                      fontWeight: FontWeight.w600,
                      color: Color(0xFF9CA3AF),
                    ),
                  ),
                  SizedBox(height: verticalGap),
                  Text(
                    d.value,
                    style: TextStyle(
                      fontSize: valueFontSize,
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
  Widget _buildCardboardTrimRow({bool compact = false}) {
    final cardboardValue = order.cardboard.isEmpty ? '—' : order.cardboard;
    final trimValue = order.additionalParams.contains('Подрезка') ? 'есть' : 'нет';
    final rowPadding = compact ? 6 * _compactCellScale : 6.0;
    final splitGap = compact ? 12 * _compactCellScale : 12.0;
    final textGap = compact ? 4 * _compactCellScale : 4.0;
    final textStyle = TextStyle(fontSize: compact ? 14 * _compactTextScale : null);
    return Padding(
      padding: EdgeInsets.symmetric(vertical: rowPadding),
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
                  style: TextStyle(
                    fontSize: compact ? 14 * _compactTextScale : null,
                    fontWeight: FontWeight.w500,
                    color: Color(0xFF9CA3AF),
                  ),
                ),
                SizedBox(width: textGap),
                Expanded(
                  child: Text(
                    cardboardValue,
                    style: textStyle.copyWith(
                      color: Color(0xFF111827),
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ],
            ),
          ),
          SizedBox(width: splitGap),
          // Second half: trimming
          Expanded(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Подрезка',
                  style: TextStyle(
                    fontSize: compact ? 14 * _compactTextScale : null,
                    fontWeight: FontWeight.w500,
                    color: Color(0xFF9CA3AF),
                  ),
                ),
                SizedBox(width: textGap),
                Expanded(
                  child: Text(
                    trimValue,
                    style: textStyle.copyWith(
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

  double? _paperExtraDouble(MaterialModel material, String key) {
    final value = material.extra?[key];
    if (value is num) return value.toDouble();
    if (value is String) {
      final normalized = value.trim().replaceAll(',', '.');
      if (normalized.isEmpty) return null;
      return double.tryParse(normalized);
    }
    return null;
  }

  String? _paperExtraString(MaterialModel material, String key) {
    final value = material.extra?[key];
    final text = value?.toString().trim() ?? '';
    return text.isEmpty ? null : text;
  }

  String _paperWidthValue(MaterialModel material, int index) {
    if (index == 0) {
      final value = order.product.widthB;
      return value == null ? '' : _fmtNum(value);
    }
    final value = _paperExtraDouble(material, 'widthB');
    return value == null ? '' : _fmtNum(value);
  }

  String _paperLengthValue(MaterialModel material, int index) {
    if (index == 0) {
      final value = order.product.length;
      return value == null ? '' : _fmtNum(value);
    }
    final value = _paperExtraDouble(material, 'lengthL');
    return value == null ? '' : _fmtNum(value);
  }

  String _paperQuantityValue(MaterialModel material, int index) {
    if (index == 0) {
      final value = order.product.blQuantity?.trim() ?? '';
      return value;
    }
    return _paperExtraString(material, 'blQuantity') ?? '';
  }

  @override
  Widget build(BuildContext context) {
    final o = order;
    final p = o.product;
    final materials = o.paperMaterials.isNotEmpty
        ? o.paperMaterials
        : <MaterialModel>[
            if (o.material != null) o.material!,
          ];
    final paintInfo = paints
        .map((e) => (e['info'] ?? '').toString().trim())
        .where((v) => v.isNotEmpty)
        .toSet()
        .join(', ');
    final paintInfoFromParams = RegExp(
      r'Информация для красок:\s*([^;]+)',
      caseSensitive: false,
    ).firstMatch(p.parameters);
    final fallbackPaintInfo = (paintInfoFromParams?.group(1) ?? '').trim();
    final paintInfoValue =
        paintInfo.isNotEmpty ? paintInfo : fallbackPaintInfo;
    final paintsWidget = paints.isEmpty
        ? const Text('—')
        : Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
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
                  child: Text(
                    '${index + 1}. $name — $v',
                    style: const TextStyle(fontSize: 10),
                  ),
                );
              }),
            ],
          );

    return LayoutBuilder(
      builder: (context, constraints) {
        final media = MediaQuery.of(context);
        final bool isTablet = media.size.shortestSide >= 600 && media.size.shortestSide < 1100;
        const spacing = 16.0;
        final maxWidth = constraints.maxWidth;
        final columns = isTablet
            ? 3
            : maxWidth >= 560
                ? 3
                : maxWidth >= 380
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
                          compact: true,
                        ),
                        _buildInfoRow('Заказчик', o.customer.isEmpty ? '—' : o.customer,
                            compact: true),
                        _buildInfoRow('Тип продукта', p.type.isEmpty ? '—' : p.type,
                            compact: true),
                        _buildInfoRow('Тираж', p.quantity > 0 ? p.quantity.toString() : '—',
                            compact: true),
                        _buildInfoRowWidget('Размеры', _buildDimensionsValue(compact: true),
                            compact: true),
                        _buildInfoRowWidget(
                          'Ручки',
                          _buildSingleLineValue(o.handle.isEmpty ? '—' : o.handle),
                          compact: true,
                        ),
                        // Use a combined row for "Картон" and "Подрезка" to align them on one
                        // line with their own labels and values. This replaces two separate
                        // rows in the old design.
                        _buildCardboardTrimRow(compact: true),
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
                        _buildInfoRowWidget('Краски', paintsWidget, compact: true),
                        _buildInfoRowWidget(
                          'Форма',
                          Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(_formDisplayText(o)),
                              if (formImageUrl != null &&
                                  formImageUrl!.trim().isNotEmpty)
                                Padding(
                                  padding: const EdgeInsets.only(top: 8),
                                  child: InkWell(
                                    onTap: () => _showImagePreview(
                                      context,
                                      formImageUrl!,
                                      title: 'Форма ${o.newFormNo?.toString() ?? ''}'
                                          .trim(),
                                    ),
                                    borderRadius: BorderRadius.circular(8),
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
                                ),
                            ],
                          ),
                          compact: true,
                        ),
                        _buildInfoRowWidget(
                          'Файлы',
                          Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              if (files.isEmpty)
                                Text(
                                  'Нет приложенных файлов',
                                ),
                              ...files
                                  .map((f) => _fileTile(context, f, compact: true))
                                  .toList(),
                            ],
                          ),
                          alignEnd: false,
                          compact: true,
                        ),
                        if (paintInfoValue.isNotEmpty)
                          _buildInfoRow('Комментарий', paintInfoValue, compact: true),
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
                        if (materials.isEmpty)
                          _buildInfoRow('Материал', '—', compact: true)
                        else
                          ...materials.asMap().entries.expand((entry) {
                            final index = entry.key;
                            final material = entry.value;
                            final parts = <String>[];
                            if (material.name.isNotEmpty) parts.add(material.name);
                            if (material.format != null &&
                                material.format!.isNotEmpty) {
                              parts.add(material.format!);
                            }
                            if (material.grammage != null &&
                                material.grammage!.isNotEmpty) {
                              parts.add('${material.grammage} гр');
                            }
                            final materialLine =
                                parts.isEmpty ? '—' : parts.join(' ');
                            final widthValue = _paperWidthValue(material, index);
                            final qtyValue = _paperQuantityValue(material, index);
                            final lenValue = _paperLengthValue(material, index);
                            final details = <String>[materialLine];
                            if (widthValue.isNotEmpty) {
                              details.add('Ш: $widthValue');
                            }
                            if (qtyValue.isNotEmpty || lenValue.isNotEmpty) {
                              if (qtyValue.isNotEmpty && lenValue.isNotEmpty) {
                                details.add('Д: $qtyValue * $lenValue L');
                              } else if (qtyValue.isNotEmpty) {
                                details.add('Д: $qtyValue');
                              } else {
                                details.add('Д: $lenValue L');
                              }
                            }
                            return <Widget>[
                              _buildInfoRow(
                                'Бумага №${index + 1}',
                                details.join('\n'),
                                compact: true,
                              ),
                            ];
                          }),
                        _buildInfoRow('Приладка',
                            o.makeready > 0 ? _fmtNum(o.makeready) : '—',
                            compact: true),
                        _buildInfoRow('ВАЛ', o.val > 0 ? _fmtNum(o.val) : '—',
                            compact: true),
                        _buildInfoRow(
                            'Комментарий',
                            o.comments.isEmpty ? '—' : o.comments,
                            compact: true),
                        _buildInfoRow(
                            'Менеджер',
                            o.manager.isEmpty ? '—' : o.manager,
                            compact: true),
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


  Widget _buildSingleLineValue(String value) {
    return SizedBox(
      width: double.infinity,
      child: FittedBox(
        fit: BoxFit.scaleDown,
        alignment: Alignment.centerRight,
        child: Text(
          value,
          maxLines: 1,
          overflow: TextOverflow.visible,
        ),
      ),
    );
  }

  Widget _buildInfoRow(String label, String value, {bool compact = false}) {
    return _buildInfoRowWidget(
      label,
      Text(
        value,
        textAlign: TextAlign.right,
        style: compact ? const TextStyle(fontSize: 14 * _compactTextScale) : null,
      ),
      compact: compact,
    );
  }

  Widget _buildInfoRowWidget(String label, Widget child,
      {bool alignEnd = true, bool compact = false}) {
    final verticalPadding = compact ? 6 * _compactCellScale : 6.0;
    final labelFontSize = compact ? 14 * _compactTextScale : null;
    final valueFontSize = compact ? 14 * _compactTextScale : null;
    final gap = compact ? 12 * _compactCellScale : 12.0;
    return Padding(
      padding: EdgeInsets.symmetric(vertical: verticalPadding),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Text(
              label,
              style: TextStyle(
                fontSize: labelFontSize,
                fontWeight: FontWeight.w500,
                color: Color(0xFF9CA3AF),
              ),
            ),
          ),
          SizedBox(width: gap),
          Expanded(
            child: DefaultTextStyle(
              // Apply a bold style to the value portion. According to the
              // updated design, all content following the colon (i.e. the
              // values) should be emphasized with a heavier font weight.
              style: const TextStyle(
                color: Color(0xFF111827),
                fontWeight: FontWeight.w600,
              ).copyWith(fontSize: valueFontSize),
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

  Widget _fileTile(BuildContext context, Map<String, dynamic> f,
      {bool compact = false}) {
    final fileName = (f['filename'] ?? f['name'] ?? 'Файл.pdf')
        .toString()
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    final objectPath = (f['objectPath'] ?? f['path'] ?? '').toString();
    final isImage = _isImageFile(fileName, objectPath);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4.0),
      child: Row(
        children: [
          Icon(isImage ? Icons.image_outlined : Icons.picture_as_pdf,
              size: compact ? 14 : 18),
          SizedBox(width: compact ? 6 : 8),
          Expanded(
            child: Text(
              fileName.isEmpty ? 'Файл.pdf' : fileName,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style:
                  compact ? const TextStyle(fontSize: 14 * _compactTextScale) : null,
            ),
          ),
          TextButton.icon(
            style: compact
                ? TextButton.styleFrom(
                    textStyle: const TextStyle(fontSize: 14 * _compactTextScale),
                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
                    minimumSize: const Size(0, 24),
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    visualDensity: const VisualDensity(
                      horizontal: VisualDensity.minimumDensity,
                      vertical: VisualDensity.minimumDensity,
                    ),
                  )
                : null,
            onPressed: objectPath.isEmpty
                ? null
                : () async {
                    final url = await storage.getSignedUrl(objectPath);
                    if (!context.mounted) return;
                    if (isImage) {
                      await _showImagePreview(
                        context,
                        url,
                        title: fileName.isEmpty ? 'Изображение' : fileName,
                      );
                      return;
                    }
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
            icon: Icon(Icons.open_in_new, size: compact ? 14 : 18),
            label: const Text('Открыть'),
          ),
        ],
      ),
    );
  }

  String _formDisplayText(OrderModel order) {
    if (!order.hasForm) return 'Форма не используется';
    final typeLabel = order.isOldForm ? 'Старая форма' : 'Новая форма';
    final formNo = order.newFormNo?.toString();
    if (formNo != null && formNo.isNotEmpty) {
      return '$typeLabel: $formNo';
    }
    final code = order.formCode?.trim();
    if (code != null && code.isNotEmpty) {
      return '$typeLabel: $code';
    }
    final series = order.formSeries?.trim();
    if (series != null && series.isNotEmpty) {
      return '$typeLabel: $series';
    }
    return '$typeLabel: —';
  }
}
