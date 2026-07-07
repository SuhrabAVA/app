import 'package:flutter/material.dart';

import '../tasks/task_model.dart';
import 'order_comment_attachment.dart';
import 'order_comments_repository.dart';
import 'order_generation_switcher.dart';
import 'order_restart_history_repository.dart';
import 'restart_history_service.dart';
import '../../utils/media_viewer.dart';

class OrderCommentsSection extends StatefulWidget {
  const OrderCommentsSection({
    super.key,
    required this.orderId,
    this.legacyText = '',
    this.repository,
    this.historyService,
    this.commentFilter,
  });

  final String orderId;
  final String legacyText;
  final OrderCommentsRepository? repository;
  final RestartHistoryService? historyService;
  final bool Function(TaskComment comment)? commentFilter;

  @override
  State<OrderCommentsSection> createState() => _OrderCommentsSectionState();
}

class _OrderCommentsSectionState extends State<OrderCommentsSection> {
  late final OrderCommentsRepository _repository;
  late final RestartHistoryService _historyService;
  // Ленивая загрузка: future создаётся при первом выборе поколения.
  final Map<String, Future<_OrderCommentsBundle>> _bundlesByOrderId = {};
  List<OrderGenerationEntry> _generations = const [];
  bool _loadingGenerations = false;
  late String _selectedOrderId;

  @override
  void initState() {
    super.initState();
    _repository = widget.repository ?? OrderCommentsRepository();
    _historyService = widget.historyService ??
        RestartHistoryService(SupabaseOrderRestartHistoryRepository());
    _selectedOrderId = widget.orderId;
    _bundlesByOrderId[widget.orderId] = _load(widget.orderId);
    _loadGenerations();
  }

  Future<void> _loadGenerations() async {
    setState(() => _loadingGenerations = true);
    final chain = await _historyService.loadGenerationChain(widget.orderId);
    if (!mounted) return;
    setState(() {
      _generations = chain;
      _loadingGenerations = false;
    });
  }

  Future<_OrderCommentsBundle> _bundleFor(String orderId) {
    return _bundlesByOrderId.putIfAbsent(orderId, () => _load(orderId));
  }

  Future<_OrderCommentsBundle> _load(String orderId) async {
    final comments = await _repository.loadComments(orderId);
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
    // Легаси-текст относится только к заказу, открытому в модуле.
    final legacy = orderId == widget.orderId ? widget.legacyText.trim() : '';
    if (legacy.isEmpty) {
      return const _OrderCommentsBundle([], {});
    }
    return _OrderCommentsBundle(
      [
        TaskComment(
          id: 'legacy-$orderId',
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
    final isHistorySelected = _selectedOrderId != widget.orderId;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
          child: OrderGenerationSwitcher(
            generations: _generations,
            currentOrderId: widget.orderId,
            selectedOrderId: _selectedOrderId,
            loading: _loadingGenerations,
            onSelected: (orderId) =>
                setState(() => _selectedOrderId = orderId),
          ),
        ),
        Expanded(
          child: FutureBuilder<_OrderCommentsBundle>(
            future: _bundleFor(_selectedOrderId),
            builder: (context, snapshot) {
              if (snapshot.connectionState == ConnectionState.waiting) {
                return const Center(child: CircularProgressIndicator());
              }
              if (snapshot.hasError) {
                return Center(
                    child: Text(
                        'Ошибка загрузки комментариев: ${snapshot.error}'));
              }
              final data = snapshot.data ?? const _OrderCommentsBundle([], {});
              return OrderCommentsTimeline(
                comments: data.comments,
                attachmentsByComment: data.attachmentsByComment,
                emptyLabel: isHistorySelected
                    ? 'Комментариев по этому заказу нет'
                    : 'Комментариев пока нет',
              );
            },
          ),
        ),
      ],
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