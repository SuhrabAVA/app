import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../../utils/media_viewer.dart';
import '../models/claim_model.dart';
import '../utils/analytics_colors.dart';

/// Диалог со списком претензий сотрудника за выбранный месяц.
/// Показывает ВСЕ претензии (source 'order' и 'chat'); у чат-претензий —
/// миниатюра/иконка медиа с открытием через media_viewer.
Future<void> showClaimsListDialog(
  BuildContext context, {
  required String employeeName,
  required String monthLabel,
  required List<ClaimModel> claims,
}) {
  final sorted = [...claims]
    ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
  return showDialog<void>(
    context: context,
    builder: (_) => Dialog(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 560, maxHeight: 600),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 4),
              child: Text(
                'Претензии за $monthLabel — $employeeName',
                style:
                    const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
              ),
            ),
            Flexible(
              child: sorted.isEmpty
                  ? const Padding(
                      padding: EdgeInsets.all(24),
                      child: Text('Претензий за этот месяц нет'),
                    )
                  : ListView.separated(
                      shrinkWrap: true,
                      padding: const EdgeInsets.symmetric(
                          horizontal: 8, vertical: 8),
                      itemCount: sorted.length,
                      separatorBuilder: (_, __) => const Divider(height: 1),
                      itemBuilder: (context, i) => _ClaimTile(claim: sorted[i]),
                    ),
            ),
            Align(
              alignment: Alignment.centerRight,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
                child: TextButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: const Text('Закрыть'),
                ),
              ),
            ),
          ],
        ),
      ),
    ),
  );
}

class _ClaimTile extends StatelessWidget {
  final ClaimModel claim;

  const _ClaimTile({required this.claim});

  static final _dateFormat = DateFormat('dd.MM.yyyy HH:mm');

  bool get _isChat => claim.source == 'chat';

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final description = (claim.description ?? '').trim();
    final author = (claim.authorName ?? claim.createdBy ?? '').trim();

    return ListTile(
      leading: _leading(context),
      title: Text(
        description.isEmpty ? 'Без текста' : description,
        style: TextStyle(
          fontSize: 13,
          color: description.isEmpty
              ? theme.colorScheme.onSurface.withOpacity(.5)
              : null,
        ),
      ),
      subtitle: Padding(
        padding: const EdgeInsets.only(top: 4),
        child: Wrap(
          spacing: 8,
          runSpacing: 4,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            _sourceChip(theme),
            Text(
              _dateFormat.format(claim.createdAt.toLocal()),
              style: const TextStyle(fontSize: 12),
            ),
            if (author.isNotEmpty)
              Text('Автор: $author', style: const TextStyle(fontSize: 12)),
          ],
        ),
      ),
    );
  }

  Widget _sourceChip(ThemeData theme) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: _isChat
            ? theme.colorScheme.errorContainer.withOpacity(.6)
            : AnalyticsColors.blue.withOpacity(.12),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        _isChat ? 'Чат' : 'Заказ',
        style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w600),
      ),
    );
  }

  Widget _leading(BuildContext context) {
    final url = claim.fileUrl ?? '';
    if (!_isChat || url.isEmpty) {
      return const CircleAvatar(
        radius: 20,
        child: Icon(Icons.assignment_outlined, size: 20),
      );
    }
    final mime = (claim.fileMime ?? '').toLowerCase();
    final isImage = mime.startsWith('image/');
    return InkWell(
      borderRadius: BorderRadius.circular(8),
      onTap: () => showMediaPreview(
        context,
        url: url,
        mime: claim.fileMime,
        title: claim.description,
      ),
      child: isImage
          ? ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: Image.network(
                url,
                width: 44,
                height: 44,
                fit: BoxFit.cover,
                errorBuilder: (_, __, ___) => const SizedBox(
                  width: 44,
                  height: 44,
                  child: Icon(Icons.broken_image, size: 22),
                ),
              ),
            )
          : SizedBox(
              width: 44,
              height: 44,
              child: Icon(
                mime.startsWith('video/') ? Icons.videocam : Icons.attachment,
                size: 26,
              ),
            ),
    );
  }
}
