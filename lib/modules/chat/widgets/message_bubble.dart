import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../chat_message.dart';

class MessageBubble extends StatefulWidget {
  final ChatMessage m;
  final bool isMine;

  const MessageBubble({
    super.key,
    required this.m,
    required this.isMine,
  });

  @override
  State<MessageBubble> createState() => _MessageBubbleState();
}

class _MessageBubbleState extends State<MessageBubble> {
  final _player = AudioPlayer();

  @override
  void dispose() {
    _player.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final m = widget.m;

    final displayName = (() {
      final n = (m.senderName ?? '').trim();
      if (n.isNotEmpty) return n;
      return widget.isMine ? 'Вы' : 'Сотрудник';
    })();

    final bubbleColor = widget.isMine
        ? Theme.of(context).colorScheme.primaryContainer.withOpacity(.6)
        : Theme.of(context).colorScheme.surfaceVariant.withOpacity(.9);

    final radius = BorderRadius.only(
      topLeft: const Radius.circular(16),
      topRight: const Radius.circular(16),
      bottomLeft: widget.isMine ? const Radius.circular(16) : const Radius.circular(6),
      bottomRight: widget.isMine ? const Radius.circular(6) : const Radius.circular(16),
    );

    final maxW = MediaQuery.of(context).size.width * 0.75;

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 8),
      child: Column(
        crossAxisAlignment:
            widget.isMine ? CrossAxisAlignment.end : CrossAxisAlignment.start,
        children: [
          // Имя автора
          Text(
            displayName,
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: Colors.black.withOpacity(.55),
            ),
          ),
          const SizedBox(height: 4),

          // Пузырь
          ConstrainedBox(
            constraints: BoxConstraints(maxWidth: maxW),
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: bubbleColor,
                borderRadius: radius,
                boxShadow: [
                  BoxShadow(
                    blurRadius: 6,
                    spreadRadius: 0,
                    offset: const Offset(0, 1),
                    color: Colors.black.withOpacity(.06),
                  )
                ],
              ),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 14),
                child: _buildContent(context, m),
              ),
            ),
          ),

          // Время
          const SizedBox(height: 4),
          Text(
            _formatTime(m.createdAt),
            style: TextStyle(fontSize: 11, color: Colors.black.withOpacity(.45)),
          ),
        ],
      ),
    );
  }

  String _formatTime(DateTime dt) {
    final h = dt.hour.toString().padLeft(2, '0');
    final m = dt.minute.toString().padLeft(2, '0');
    return '$h:$m';
  }

  Widget _buildContent(BuildContext context, ChatMessage m) {
    switch (m.kind) {
      case 'text':
        return SelectableText(
          m.body ?? '',
          style: const TextStyle(fontSize: 15, height: 1.25),
        );

      case 'image':
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _ImageWidget(url: m.fileUrl ?? ''),
            if ((m.body ?? '').isNotEmpty) ...[
              const SizedBox(height: 6),
              Text(m.body!),
            ]
          ],
        );

      case 'video':
        return _FileTile(
          icon: Icons.videocam,
          title: m.body?.isNotEmpty == true ? m.body! : 'Видео',
          url: m.fileUrl,
        );

      case 'audio':
        return _AudioTile(url: m.fileUrl, durationMs: m.durationMs);

      default:
        return _FileTile(
          icon: Icons.insert_drive_file,
          title: m.body?.isNotEmpty == true ? m.body! : 'Файл',
          url: m.fileUrl,
        );
    }
  }
}

class _ImageWidget extends StatelessWidget {
  final String url;
  const _ImageWidget({required this.url});

  @override
  Widget build(BuildContext context) {
    final w = MediaQuery.of(context).size.width * 0.70;
    final h = w * 0.66;
    return ClipRRect(
      borderRadius: BorderRadius.circular(12),
      child: GestureDetector(
        onTap: () {
          if (url.isEmpty) return;
          launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
        },
        child: Image.network(
          url,
          fit: BoxFit.cover,
          width: w,
          height: h,
          errorBuilder: (c, e, s) => Container(
            width: w,
            height: h,
            color: Colors.black12,
            alignment: Alignment.center,
            child: const Icon(Icons.broken_image),
          ),
          loadingBuilder: (context, child, loadingProgress) {
            if (loadingProgress == null) return child;
            return SizedBox(
              width: w,
              height: h,
              child: const Center(child: CircularProgressIndicator(strokeWidth: 2)),
            );
          },
        ),
      ),
    );
  }
}

class _FileTile extends StatelessWidget {
  final String? url;
  final String title;
  final IconData icon;

  const _FileTile({required this.icon, required this.title, required this.url});

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: url == null ? null : () => launchUrl(Uri.parse(url!), mode: LaunchMode.externalApplication),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 18),
          const SizedBox(width: 8),
          Flexible(child: Text(title, overflow: TextOverflow.ellipsis)),
        ],
      ),
    );
  }
}

class _AudioTile extends StatefulWidget {
  final String? url;
  final int? durationMs;
  const _AudioTile({this.url, this.durationMs});

  @override
  State<_AudioTile> createState() => _AudioTileState();
}

class _AudioTileState extends State<_AudioTile> {
  final _player = AudioPlayer();
  bool _playing = false;

  @override
  void dispose() {
    _player.dispose();
    super.dispose();
  }

  Future<void> _toggle() async {
    if (widget.url == null || widget.url!.isEmpty) return;
    if (_playing) {
      await _player.stop();
      setState(() => _playing = false);
    } else {
      await _player.play(UrlSource(widget.url!));
      setState(() => _playing = true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final dur = widget.durationMs;
    final durText = (dur != null && dur > 0)
        ? ' ${Duration(milliseconds: dur).inSeconds}s'
        : '';
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        IconButton(
          icon: Icon(_playing ? Icons.stop_circle : Icons.play_arrow),
          onPressed: _toggle,
        ),
        Text('Голосовое$durText'),
      ],
    );
  }
}
