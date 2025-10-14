import 'package:flutter/material.dart';

/// Shows a modal bottom sheet with deleted records loaded by [loader].
Future<void> showDeletedRecordsModal({
  required BuildContext context,
  required String title,
  required Future<List<Map<String, dynamic>>> Function() loader,
}) async {
  await showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    builder: (ctx) {
      return _DeletedRecordsModal(title: title, loader: loader);
    },
  );
}

class _DeletedRecordsModal extends StatefulWidget {
  const _DeletedRecordsModal({
    required this.title,
    required this.loader,
  });

  final String title;
  final Future<List<Map<String, dynamic>>> Function() loader;

  @override
  State<_DeletedRecordsModal> createState() => _DeletedRecordsModalState();
}

class _DeletedRecordsModalState extends State<_DeletedRecordsModal> {
  late Future<List<Map<String, dynamic>>> _future;

  @override
  void initState() {
    super.initState();
    _future = widget.loader();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SafeArea(
      child: Padding(
        padding: EdgeInsets.only(
          left: 16,
          right: 16,
          top: 16,
          bottom: MediaQuery.of(context).viewInsets.bottom + 16,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    widget.title,
                    style: theme.textTheme.titleLarge,
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.close),
                  onPressed: () => Navigator.of(context).pop(),
                ),
              ],
            ),
            const SizedBox(height: 12),
            FutureBuilder<List<Map<String, dynamic>>>(
              future: _future,
              builder: (context, snapshot) {
                if (snapshot.connectionState == ConnectionState.waiting) {
                  return const Padding(
                    padding: EdgeInsets.symmetric(vertical: 24),
                    child: Center(child: CircularProgressIndicator()),
                  );
                }
                final data = snapshot.data ?? const [];
                if (data.isEmpty) {
                  return const Padding(
                    padding: EdgeInsets.symmetric(vertical: 24),
                    child: Center(child: Text('Нет удалённых записей')),
                  );
                }
                return Flexible(
                  child: ListView.separated(
                    shrinkWrap: true,
                    itemCount: data.length,
                    separatorBuilder: (_, __) => const Divider(height: 1),
                    itemBuilder: (context, index) {
                      final row = data[index];
                      final payload = (row['payload'] as Map<String, dynamic>?) ?? {};
                      final description = _firstNonEmpty(payload, const [
                        'description',
                        'name',
                        'title',
                      ]);
                      final quantity = _firstNonEmpty(payload, const [
                        'quantity',
                        'qty',
                        'counted_qty',
                        'factual',
                      ]);
                      final unit = _firstNonEmpty(payload, const [
                        'unit',
                        'units',
                      ]);
                      final format = payload['format'];
                      final grammage = payload['grammage'];
                      final reason = (row['reason'] ?? '').toString();
                      final deletedAt = (row['deleted_at'] ?? '').toString();
                      return ListTile(
                        title: Text(description.isEmpty ? 'Без названия' : description),
                        subtitle: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            if (quantity.isNotEmpty)
                              Text('Количество: $quantity${unit.isNotEmpty ? ' $unit' : ''}'),
                            if (format != null && '$format'.isNotEmpty)
                              Text('Формат: $format'),
                            if (grammage != null && '$grammage'.isNotEmpty)
                              Text('Грамаж: $grammage'),
                            if (reason.isNotEmpty) Text('Причина: $reason'),
                            if (deletedAt.isNotEmpty) Text('Удалено: $deletedAt'),
                          ],
                        ),
                        isThreeLine: true,
                      );
                    },
                  ),
                );
              },
            ),
          ],
        ),
      ),
    );
  }

  static String _firstNonEmpty(Map<String, dynamic> payload, List<String> keys) {
    for (final key in keys) {
      final value = payload[key];
      if (value == null) continue;
      final text = value.toString().trim();
      if (text.isNotEmpty) {
        return text;
      }
    }
    return '';
  }
}
