import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'forms_provider.dart';

/// Экран для управления нумерациями (формами).
/// Позволяет создавать серии, инкрементировать и устанавливать номера, удалять серии.
class FormsScreen extends StatelessWidget {
  const FormsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return ChangeNotifierProvider(
      create: (_) => FormsProvider()..load(),
      child: const _FormsView(),
    );
  }
}

class _FormsView extends StatefulWidget {
  const _FormsView();

  @override
  State<_FormsView> createState() => _FormsViewState();
}

class _FormsViewState extends State<_FormsView> {
  /// Диалог для создания новой серии.
  Future<void> _addSeries() async {
    final c = TextEditingController();
    final res = await showDialog<String?>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Новая серия'),
        content: TextField(
          controller: c,
          autofocus: true,
          decoration: const InputDecoration(
            labelText: 'Название серии/префикс',
            hintText: 'Например: ФОРМ-2025',
            border: OutlineInputBorder(),
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Отмена')),
          ElevatedButton(onPressed: () => Navigator.pop(ctx, c.text.trim()), child: const Text('Создать')),
        ],
      ),
    );
    final name = (res ?? '').trim();
    if (name.isEmpty) return;
    await context.read<FormsProvider>().createSeries(name);
  }

  @override
  Widget build(BuildContext context) {
    final provider = context.watch<FormsProvider>();
    return Scaffold(
      appBar: AppBar(
        title: const Text('Форма — нумерации'),
        actions: [
          IconButton(onPressed: _addSeries, icon: const Icon(Icons.add), tooltip: 'Добавить серию'),
        ],
      ),
      body: ListView.separated(
        padding: const EdgeInsets.all(8),
        itemCount: provider.series.length,
        separatorBuilder: (_, __) => const Divider(height: 1),
        itemBuilder: (ctx, i) {
          final row = provider.series[i];
          final id = row['id'] as String;
          final series = row['series'] as String;
          final last = row['last_number'] as int? ?? 0;
          final created = row['created_at'] as String? ?? '';
          final updated = row['updated_at'] as String? ?? '';
          return ListTile(
            title: Text(series),
            subtitle: Text('Текущий номер: $last\nСоздано: $created${updated.isNotEmpty ? ' • Изменено: $updated' : ''}'),
            isThreeLine: true,
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                IconButton(
                  tooltip: 'Установить номер',
                  icon: const Icon(Icons.edit),
                  onPressed: () async {
                    final c = TextEditingController(text: last.toString());
                    final res = await showDialog<String?>(
                      context: context,
                      builder: (ctx) => AlertDialog(
                        title: Text('Установить номер для $series'),
                        content: TextField(
                          controller: c,
                          keyboardType: TextInputType.number,
                          decoration: const InputDecoration(
                            labelText: 'Номер',
                            border: OutlineInputBorder(),
                          ),
                        ),
                        actions: [
                          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Отмена')),
                          ElevatedButton(onPressed: () => Navigator.pop(ctx, c.text.trim()), child: const Text('Сохранить')),
                        ],
                      ),
                    );
                    final text = (res ?? '').trim();
                    final n = int.tryParse(text);
                    if (n != null) {
                      await context.read<FormsProvider>().setNumber(id, n);
                    }
                  },
                ),
                IconButton(
                  tooltip: 'Следующий номер',
                  icon: const Icon(Icons.exposure_plus_1),
                  onPressed: () => context.read<FormsProvider>().increment(id),
                ),
                IconButton(
                  tooltip: 'Удалить серию',
                  icon: const Icon(Icons.delete_outline),
                  onPressed: () => context.read<FormsProvider>().remove(id),
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}