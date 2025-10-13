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
                          leading: const Icon(Icons.report,
                              color: Colors.deepOrangeAccent),
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
                              'Удалено: ${deletedAt != '—' ? deletedAt : '—'}'),
                          subtitle: deletedBy.isNotEmpty
                              ? Text('Пользователь: $deletedBy')
                              : null,
                        ));
                      }
                      if (extra.isNotEmpty) {
                        infoRows.add(ListTile(
                          dense: true,
                          leading: const Icon(Icons.label_outline),
                          title: const Text('Дополнительно'),
                          subtitle: Text(extra.entries
                              .map((e) => '${e.key}: ${e.value}')
                              .join('\n')),
                        ));
                      }
                      final payloadEntries = payload.entries
                          .map((e) => '${e.key}: ${e.value}')
                          .join('\n');

                      return Card(
                        child: ExpansionTile(
                          title: Text(title.isEmpty ? entityId : title),
                          subtitle: Text('ID: $entityId'),
                          children: [
                            if (infoRows.isNotEmpty)
                              ...infoRows
                            else
                              const SizedBox.shrink(),
                            ListTile(
                              dense: true,
                              leading: const Icon(Icons.inventory_2_outlined),
                              title: const Text('Данные записи'),
                              subtitle: Text(payloadEntries.isEmpty
                                  ? '—'
                                  : payloadEntries),
                            ),
                          ],
                        ),
                      );
                    },
                  ),
                ),
    );
  }
}
