import 'dart:async';

import 'package:flutter/material.dart';

import '../chat_mention_candidate.dart';

/// Загрузчик кандидатов (обычно ChatProvider.claimCandidates); функция,
/// а не провайдер — чтобы диалог был тестируем без Supabase.
typedef ClaimCandidatesLoader = Future<List<ChatMentionCandidate>> Function(
    {String query});

/// Диалог выбора сотрудников для претензии: поиск + мультивыбор.
/// Возвращает выбранный список (null — отмена, выбор не менять).
Future<List<ChatMentionCandidate>?> showClaimEmployeePicker(
  BuildContext context, {
  required ClaimCandidatesLoader loadCandidates,
  required List<ChatMentionCandidate> initiallySelected,
}) {
  return showDialog<List<ChatMentionCandidate>>(
    context: context,
    builder: (_) => _ClaimEmployeePickerDialog(
      loadCandidates: loadCandidates,
      initiallySelected: initiallySelected,
    ),
  );
}

class _ClaimEmployeePickerDialog extends StatefulWidget {
  final ClaimCandidatesLoader loadCandidates;
  final List<ChatMentionCandidate> initiallySelected;

  const _ClaimEmployeePickerDialog({
    required this.loadCandidates,
    required this.initiallySelected,
  });

  @override
  State<_ClaimEmployeePickerDialog> createState() =>
      _ClaimEmployeePickerDialogState();
}

class _ClaimEmployeePickerDialogState
    extends State<_ClaimEmployeePickerDialog> {
  final _searchController = TextEditingController();
  List<ChatMentionCandidate> _visible = const [];
  late final Map<String, ChatMentionCandidate> _selected;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _selected = {for (final c in widget.initiallySelected) c.id: c};
    _searchController.addListener(_refresh);
    unawaited(_refresh());
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _refresh() async {
    final query = _searchController.text;
    final list = await widget.loadCandidates(query: query);
    if (!mounted || query != _searchController.text) return;
    setState(() {
      _visible = list;
      _loading = false;
    });
  }

  void _toggle(ChatMentionCandidate candidate, bool selected) {
    setState(() {
      if (selected) {
        _selected[candidate.id] = candidate;
      } else {
        _selected.remove(candidate.id);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Претензия: выбор сотрудников'),
      content: SizedBox(
        width: 420,
        height: 440,
        child: Column(
          children: [
            TextField(
              controller: _searchController,
              autofocus: true,
              decoration: const InputDecoration(
                hintText: 'Поиск сотрудника',
                prefixIcon: Icon(Icons.search),
                isDense: true,
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 8),
            Expanded(
              child: _loading
                  ? const Center(child: CircularProgressIndicator())
                  : _visible.isEmpty
                      ? const Center(child: Text('Никого не найдено'))
                      : ListView.builder(
                          itemCount: _visible.length,
                          itemBuilder: (context, index) {
                            final candidate = _visible[index];
                            return CheckboxListTile(
                              dense: true,
                              controlAffinity:
                                  ListTileControlAffinity.leading,
                              value: _selected.containsKey(candidate.id),
                              title: Text(candidate.displayName),
                              onChanged: (v) =>
                                  _toggle(candidate, v ?? false),
                            );
                          },
                        ),
            ),
            if (_selected.isNotEmpty)
              Align(
                alignment: Alignment.centerLeft,
                child: Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text(
                    'Выбрано: ${_selected.length}',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ),
              ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Отмена'),
        ),
        FilledButton(
          onPressed: () =>
              Navigator.of(context).pop(_selected.values.toList()),
          child: const Text('Готово'),
        ),
      ],
    );
  }
}
