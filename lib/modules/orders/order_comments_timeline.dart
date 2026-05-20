import 'package:flutter/material.dart';

import '../tasks/task_model.dart';
import 'order_comment_attachment.dart';
import 'order_comments_repository.dart';
import '../../utils/media_viewer.dart';

class OrderCommentsSection extends StatefulWidget {
  const OrderCommentsSection({
    super.key,
    required this.orderId,
    this.legacyText = '',
    this.repository,
    this.commentFilter,
  });

  final String orderId;
  final String legacyText;
  final OrderCommentsRepository? repository;
  final bool Function(TaskComment comment)? commentFilter;

  @override
  State<OrderCommentsSection> createState() => _OrderCommentsSectionState();
}

class _OrderCommentsSectionState extends State<OrderCommentsSection> {
  late final OrderCommentsRepository _repository;
  late Future<_OrderCommentsBundle> _future;

  @override
  void initState() {
    super.initState();
    _repository = widget.repository ?? OrderCommentsRepository();
    _future = _load();
  }

  Future<_OrderCommentsBundle> _load() async {
    final comments = await _repository.loadComments(widget.orderId);
    final filtered = widget.commentFilter == null
        ? comments
        : comments.where(widget.commentFilter!).toList();
    final attachments = await _repository
        .loadAttachmentsByCommentIds(filtered.map((e) => e.id).toList());
    final byComment = <String, List<OrderCommentAttachment>>{};
    for (final item in attachments) {
      byComment.putIfAbsent(item.commentId, () => <OrderCommentAttachment>[]).add(item);
    }
    if (filtered.isNotEmpty) {
      return _OrderCommentsBundle(filtered, byComment);
    }
    final legacy = widget.legacyText.trim();
    if (legacy.isEmpty) {
      return const _OrderCommentsBundle([], {});
    }
    return _OrderCommentsBundle(
      [
        TaskComment(
          id: 'legacy-${widget.orderId}',
          userId: '',
          text: legacy,
          timestamp: 0,
          type: 'comment',
        ),
      ],
      const {},
    );
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<_OrderCommentsBundle>(
      future: _future,
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const Center(child: CircularProgressIndicator());
        }
        if (snapshot.hasError) {
          return Center(child: Text('Ошибка загрузки комментариев: ${snapshot.error}'));
        }
        final data = snapshot.data ?? const _OrderCommentsBundle([], {});
        return OrderCommentsTimeline(
          comments: data.comments,
          attachmentsByComment: data.attachmentsByComment,
        );
      },
    );
  }
}

class _OrderCommentsBundle {
  const _OrderCommentsBundle(this.comments, this.attachmentsByComment);

  final List<TaskComment> comments;
  final Map<String, List<OrderCommentAttachment>> attachmentsByComment;
}

class OrderCommentsTimeline extends StatelessWidget {
  const OrderCommentsTimeline({
    super.key,
    required this.comments,
    required this.attachmentsByComment,
    this.emptyLabel = 'Комментариев пока нет',
  });

  final List<TaskComment> comments;
  final Map<String, List<OrderCommentAttachment>> attachmentsByComment;
  final String emptyLabel;

  @override
  Widget build(BuildContext context) {
    if (comments.isEmpty) return Center(child: Text(emptyLabel));
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

  IconData _iconForAttachment() {
    final mime = attachment.mimeType.toLowerCase();
    if (mime.startsWith('image/')) return Icons.image_outlined;
    if (mime.startsWith('video/')) return Icons.videocam_outlined;
    if (mime == 'application/pdf') return Icons.picture_as_pdf_outlined;
    return Icons.attach_file;
  }

  @override
  Widget build(BuildContext context) {
    return ActionChip(
      avatar: Icon(_iconForAttachment(), size: 16),
      label: Text(attachment.fileName),
      onPressed: () async {
        final url = (attachment.fileUrl ?? '').trim();
        if (url.isEmpty) {
          if (!context.mounted) return;
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Файл недоступен для просмотра')),
          );
          return;
        }

        await showMediaPreview(
          context,
          url: url,
          mime: attachment.mimeType,
          title: attachment.fileName,
        );
      },
    );
  }
}
