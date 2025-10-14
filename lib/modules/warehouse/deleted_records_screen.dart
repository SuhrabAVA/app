import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

class DeletedRecordsScreen extends StatefulWidget {
  final String entityType;
  final String title;
  final Map<String, String>? extraFilters;

  const DeletedRecordsScreen({
    super.key,
    required this.entityType,
    required this.title,
    this.extraFilters,
  });

  @override
  State<DeletedRecordsScreen> createState() => _DeletedRecordsScreenState();
}

class _DeletedRecordsScreenState extends State<DeletedRecordsScreen> {
  final SupabaseClient _client = Supabase.instance.client;
  bool _loading = true;
  List<Map<String, dynamic>> _records = const [];

  static const Map<String, String> _fieldLabels = {
    'description': 'Наименование',
    'name': 'Наименование',
    'title': 'Заголовок',
    'quantity': 'Количество',
    'qty': 'Количество',
    'amount': 'Количество',
    'count': 'Количество',
    'counted_qty': 'Количество',
    'unit': 'Ед. измерения',
    'units': 'Ед. измерения',
    'format': 'Формат',
    'format_display': 'Формат',
    'grammage': 'Грамаж',
    'grammage_display': 'Грамаж',
    'supplier': 'Поставщик',
    'supplier_name': 'Поставщик',
    'note': 'Примечание',
    'comment': 'Комментарий',
    'reason': 'Причина',
    'table_key': 'Раздел',
    'type': 'Тип',
    'color': 'Цвет',
    'length': 'Длина',
    'width': 'Ширина',
    'height': 'Высота',
    'weight': 'Вес',
    'diameter': 'Диаметр',
    'low_threshold': 'Минимальный остаток',
    'critical_threshold': 'Критический остаток',
    'order_id': 'Заказ',
    'created_at': 'Создано',
    'updated_at': 'Обновлено',
    'date': 'Дата',
    'image_url': 'Ссылка на изображение',
    'image_base64': 'Изображение',
    'by_name': 'Ответственный',
  };

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      PostgrestFilterBuilder<dynamic> query =
          _client.from('warehouse_deleted_records').select();
      query = query.eq('entity_type', widget.entityType);
      if (widget.extraFilters != null) {
        widget.extraFilters!.forEach((key, value) {
          query = query.filter('extra->>$key', 'eq', value);
        });
      }
      final data = await query.order('deleted_at', ascending: false);
      _records = ((data as List?) ?? [])
          .map((e) => Map<String, dynamic>.from(e as Map))
          .toList();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Не удалось загрузить данные: $e')),
        );
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Map<String, dynamic> _parseJson(dynamic value) {
    if (value is Map<String, dynamic>) return value;
    if (value is Map) return Map<String, dynamic>.from(value);
    if (value is String && value.trim().isNotEmpty) {
      try {
        final decoded = jsonDecode(value);
        if (decoded is Map<String, dynamic>) return decoded;
        if (decoded is Map) return Map<String, dynamic>.from(decoded);
      } catch (_) {}
    }
    return <String, dynamic>{};
  }

  String _formatDate(String? iso) {
    if (iso == null || iso.isEmpty) return '—';
    try {
      final dt = DateTime.parse(iso).toLocal();
      return '${dt.year.toString().padLeft(4, '0')}-${dt.month.toString().padLeft(2, '0')}-${dt.day.toString().padLeft(2, '0')} ${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';
    } catch (_) {
      return iso;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.title),
        actions: [
          IconButton(
            onPressed: _load,
            icon: const Icon(Icons.refresh),
            tooltip: 'Обновить',
          )
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _records.isEmpty
              ? const Center(child: Text('Удалённых записей нет'))
              : RefreshIndicator(
                  onRefresh: _load,
                  child: ListView.separated(
                    padding: const EdgeInsets.all(12),
                    itemCount: _records.length,
                    separatorBuilder: (_, __) => const SizedBox(height: 8),
                    itemBuilder: (context, index) {
                      final record = _records[index];
                      final payload = _parseJson(record['payload']);
                      final extra = _parseJson(record['extra']);
                      final reason = record['reason']?.toString();
                      final deletedBy = (record['deleted_by'] ?? '')
                          .toString()
                          .trim();
                      final deletedAt =
                          _formatDate(record['deleted_at']?.toString());
                      final entityId = record['entity_id']?.toString() ?? '—';
                      final title = (payload['description'] ??
                              payload['name'] ??
                              payload['title'] ??
                              entityId)
                          .toString();

                      final infoRows = <Widget>[];
                      if (reason != null && reason.isNotEmpty) {
                        infoRows.add(ListTile(
                          dense: true,
                          leading: const Icon(
                            Icons.report,
                            color: Colors.deepOrangeAccent,
                          ),
                          title: const Text('Причина удаления'),
                          subtitle: Text(reason),
                        ));
                      }
                      if (deletedBy.isNotEmpty ||
                          (deletedAt.isNotEmpty && deletedAt != '—')) {
                        infoRows.add(ListTile(
                          dense: true,
                          leading: const Icon(Icons.person_outline),
                          title: Text(
                            'Удалено: ${deletedAt != '—' ? deletedAt : '—'}',
                          ),
                          subtitle: deletedBy.isNotEmpty
                              ? Text('Пользователь: $deletedBy')
                              : null,
                        ));
                      }
                      if (extra.isNotEmpty) {
                        infoRows.addAll(
                          _buildKeyValueTiles(
                            extra,
                            icon: Icons.label_outline,
                            title: 'Дополнительные данные',
                          ),
                        );
                      }
                      final payloadTiles = _buildPayloadTiles(payload);

                      return Card(
                        child: ExpansionTile(
                          title: Text(title.isEmpty ? entityId : title),
                          subtitle: Text('ID: $entityId'),
                          children: [
                            if (infoRows.isNotEmpty)
                              ...infoRows
                            else
                              const SizedBox.shrink(),
                            if (payloadTiles.isNotEmpty)
                              ...payloadTiles
                            else
                              const ListTile(
                                dense: true,
                                leading: Icon(Icons.inventory_2_outlined),
                                title: Text('Данные записи'),
                                subtitle: Text('—'),
                              ),
                          ],
                        ),
                      );
                    },
                  ),
                ),
    );
  }

  List<Widget> _buildPayloadTiles(Map<String, dynamic> payload) {
    if (payload.isEmpty) {
      return const [];
    }

    final usedKeys = <String>{};
    final rows = <MapEntry<String, String>>[];

    final quantity = _firstNumber(payload,
        const ['quantity', 'qty', 'amount', 'count', 'counted_qty'], usedKeys);
    final unit = _firstString(
        payload, const ['unit', 'units', 'measure'], usedKeys);
    if (quantity != null || (unit != null && unit.isNotEmpty)) {
      final buffer = StringBuffer();
      if (quantity != null) {
        buffer.write(_formatNumber(quantity));
      }
      if (unit != null && unit.trim().isNotEmpty) {
        if (buffer.isNotEmpty) buffer.write(' ');
        buffer.write(unit.trim());
      }
      if (buffer.isNotEmpty) {
        rows.add(MapEntry('Количество', buffer.toString()));
      }
    }

    final formatValue =
        _firstString(payload, const ['format', 'format_display'], usedKeys);
    if (formatValue != null && formatValue.isNotEmpty) {
      rows.add(MapEntry('Формат', formatValue));
    }

    final grammageValue = _firstString(
        payload, const ['grammage', 'grammage_display'], usedKeys);
    if (grammageValue != null && grammageValue.isNotEmpty) {
      rows.add(MapEntry('Грамаж', grammageValue));
    }

    final supplierValue =
        _firstString(payload, const ['supplier', 'supplier_name'], usedKeys);
    if (supplierValue != null && supplierValue.isNotEmpty) {
      rows.add(MapEntry('Поставщик', supplierValue));
    }

    final noteValue = _firstString(
        payload, const ['note', 'comment', 'reason'], usedKeys,
        keepEmpty: false);
    if (noteValue != null && noteValue.isNotEmpty) {
      rows.add(MapEntry('Примечание', noteValue));
    }

    final lowThreshold = _firstNumber(
        payload,
        const ['low_threshold', 'low', 'min_threshold', 'minimal_threshold'],
        usedKeys);
    if (lowThreshold != null) {
      rows.add(MapEntry(
          'Минимальный остаток', _formatNumber(lowThreshold.toDouble())));
    }

    final criticalThreshold = _firstNumber(
        payload,
        const ['critical_threshold', 'critical', 'critical_stock'], usedKeys);
    if (criticalThreshold != null) {
      rows.add(MapEntry('Критический остаток',
          _formatNumber(criticalThreshold.toDouble())));
    }

    final skipKeys = <String>{
      ...usedKeys,
      'description',
      'name',
      'title',
      'payload',
      'id',
    };

    final otherKeys = payload.keys
        .where((k) => !skipKeys.contains(k))
        .toList()
      ..sort((a, b) => a.toString().compareTo(b.toString()));

    for (final key in otherKeys) {
      final value = payload[key];
      if (value == null) {
        continue;
      }
      final text = _formatValue(value, key: key.toString());
      if (text.isEmpty) {
        continue;
      }
      rows.add(MapEntry(_labelForKey(key.toString()), text));
      usedKeys.add(key.toString());
    }

    if (rows.isEmpty) {
      return const [];
    }

    final tiles = <Widget>[
      const ListTile(
        dense: true,
        leading: Icon(Icons.inventory_2_outlined),
        title: Text('Данные записи'),
      ),
    ];

    for (final row in rows) {
      tiles.add(
        ListTile(
          dense: true,
          contentPadding:
              const EdgeInsetsDirectional.only(start: 56, end: 16),
          title: Text(row.key),
          subtitle: SelectableText(row.value),
        ),
      );
    }

    return tiles;
  }

  List<Widget> _buildKeyValueTiles(
    Map<String, dynamic> source, {
    IconData? icon,
    String? title,
    Set<String>? usedKeys,
    Set<String>? skipKeys,
  }) {
    if (source.isEmpty) {
      return const [];
    }

    final rows = <MapEntry<String, String>>[];
    final sortedKeys = source.keys.toList()
      ..sort((a, b) => a.toString().compareTo(b.toString()));

    for (final key in sortedKeys) {
      final keyStr = key.toString();
      if (skipKeys != null && skipKeys.contains(keyStr)) {
        continue;
      }
      if (usedKeys != null && usedKeys.contains(keyStr)) {
        continue;
      }
      final value = source[key];
      if (value == null) {
        continue;
      }
      final text = _formatValue(value, key: keyStr);
      if (text.isEmpty) {
        continue;
      }
      rows.add(MapEntry(_labelForKey(keyStr), text));
      usedKeys?.add(keyStr);
    }

    if (rows.isEmpty) {
      return const [];
    }

    final tiles = <Widget>[];
    if (title != null) {
      tiles.add(
        ListTile(
          dense: true,
          leading: icon != null ? Icon(icon) : null,
          title: Text(title),
        ),
      );
    }

    for (final row in rows) {
      tiles.add(
        ListTile(
          dense: true,
          contentPadding: EdgeInsetsDirectional.only(
            start: title != null ? 56 : 16,
            end: 16,
          ),
          title: Text(row.key),
          subtitle: SelectableText(row.value),
        ),
      );
    }

    return tiles;
  }

  String? _firstString(Map<String, dynamic> source, List<String> keys,
      Set<String> usedKeys,
      {bool keepEmpty = false}) {
    for (final key in keys) {
      final value = source[key];
      if (value == null) continue;
      final text = value.toString().trim();
      if (text.isEmpty && !keepEmpty) {
        continue;
      }
      usedKeys.add(key);
      return text;
    }
    return null;
  }

  double? _firstNumber(
      Map<String, dynamic> source, List<String> keys, Set<String> usedKeys) {
    for (final key in keys) {
      final value = source[key];
      if (value == null) continue;
      double? number;
      if (value is num) {
        number = value.toDouble();
      } else {
        number = double.tryParse(value.toString().replaceAll(',', '.'));
      }
      if (number != null) {
        usedKeys.add(key);
        return number;
      }
    }
    return null;
  }

  String _formatNumber(double value) {
    if (value % 1 == 0) {
      return value.toInt().toString();
    }
    return value.toStringAsFixed(value.abs() >= 100 ? 1 : 2).replaceAll('.', ',');
  }

  String _formatValue(dynamic value, {String? key}) {
    if (value == null) return '';
    if (value is bool) {
      return value ? 'Да' : 'Нет';
    }
    if (value is num) {
      return _formatNumber(value.toDouble());
    }
    if (value is DateTime) {
      return _formatDate(value.toIso8601String());
    }
    if (value is Iterable) {
      final items = value
          .map((e) => _formatValue(e))
          .where((element) => element.isNotEmpty)
          .toList();
      return items.join(', ');
    }
    if (value is Map) {
      final entries = value.entries
          .map((e) =>
              '${_labelForKey(e.key.toString())}: ${_formatValue(e.value)}')
          .where((element) => element.trim().isNotEmpty)
          .join('\n');
      return entries;
    }
    final text = value.toString().trim();
    if (text.isEmpty || text == 'null') {
      return '';
    }
    if (key == 'image_base64') {
      return 'Вложено изображение';
    }
    if (key == 'image_url') {
      return text;
    }
    final formattedDate = _formatDate(text);
    if (formattedDate != text) {
      return formattedDate;
    }
    return text;
  }

  String _labelForKey(String key) {
    if (_fieldLabels.containsKey(key)) {
      return _fieldLabels[key]!;
    }
    final normalized = key.replaceAll(RegExp(r'[_\-]+'), ' ').trim();
    if (normalized.isEmpty) return key;
    return normalized
        .split(' ')
        .map((word) =>
            word.isEmpty ? word : '${word[0].toUpperCase()}${word.substring(1)}')
        .join(' ');
  }
}
