import 'package:flutter/material.dart';

import '../tasks/task_model.dart';
import 'order_comment_attachment.dart';

class OrderCommentsTimeline extends StatelessWidget {
  const OrderCommentsTimeline({super.key, required this.comments, required this.attachmentsByComment});

  final List<TaskComment> comments;
  final Map<String, List<OrderCommentAttachment>> attachmentsByComment;

  @override
  Widget build(BuildContext context) {
    if (comments.isEmpty) return const Center(child: Text('Комментариев пока нет'));
    return ListView.builder(
      shrinkWrap: true,
      itemCount: comments.length,
      itemBuilder: (_, i) {
        final c = comments[i];
        return OrderCommentItem(
          comment: c,
          attachments: attachmentsByComment[c.id] ?? const [],
        );
      },
    );
  }
}

class OrderCommentItem extends StatelessWidget {
  const OrderCommentItem({super.key, required this.comment, required this.attachments});
  final TaskComment comment;
  final List<OrderCommentAttachment> attachments;

  @override
  Widget build(BuildContext context) {
    final text = comment.text.trim();
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(text.isEmpty ? '—' : text),
          if (attachments.isNotEmpty) ...[
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: attachments.map((a) => AttachmentPreview(attachment: a)).toList(),
            ),
          ]
        ]),
      ),
    );
  }
}

class AttachmentPreview extends StatelessWidget {
  const AttachmentPreview({super.key, required this.attachment});
  final OrderCommentAttachment attachment;
  @override
  Widget build(BuildContext context) {
    return ActionChip(
      avatar: const Icon(Icons.attach_file, size: 16),
      label: Text(attachment.fileName),
      onPressed: () {
        Navigator.of(context).push(MaterialPageRoute(
          builder: (_) => AttachmentViewerScreen(attachment: attachment),
        ));
      },
    );
  }
}

class AttachmentViewerScreen extends StatelessWidget {
  const AttachmentViewerScreen({super.key, required this.attachment});
  final OrderCommentAttachment attachment;
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(attachment.fileName)),
      body: Center(
        child: Text((attachment.fileUrl ?? '').isEmpty
            ? 'Нет URL для просмотра'
            : attachment.fileUrl!),
      ),
    );
  }
}
