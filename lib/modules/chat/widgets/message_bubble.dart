import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/material.dart';
import '../../../utils/media_viewer.dart';

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

    final media = MediaQuery.of(context);
    final bool isTablet = media.size.shortestSide >= 600 && media.size.shortestSide < 1100;
    final double scale = isTablet ? 0.9 : 1.0;
    double scaled(double value) => value * scale;

    final radius = BorderRadius.only(
      topLeft: Radius.circular(scaled(16)),
      topRight: Radius.circular(scaled(16)),
      bottomLeft: widget.isMine ? Radius.circular(scaled(16)) : Radius.circular(scaled(6)),
      bottomRight: widget.isMine ? Radius.circular(scaled(6)) : Radius.circular(scaled(16)),
    );

    final maxW = media.size.width * 0.75;

    return Padding(
      padding: EdgeInsets.symmetric(vertical: scaled(6), horizontal: scaled(8)),
      child: Column(
        crossAxisAlignment:
            widget.isMine ? CrossAxisAlignment.end : CrossAxisAlignment.start,
        children: [
          Text(
            displayName,
            style: TextStyle(
              fontSize: scaled(12),
              fontWeight: FontWeight.w600,
              color: Colors.black.withOpacity(.55),
            ),
          ),
          SizedBox(height: scaled(4)),
          ConstrainedBox(
            constraints: BoxConstraints(maxWidth: maxW),
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: bubbleColor,
                borderRadius: radius,
                boxShadow: [
                  BoxShadow(
                    blurRadius: scaled(6),
                    spreadRadius: 0,
                    offset: const Offset(0, 1),
                    color: Colors.black.withOpacity(.06),
                  )
                ],
              ),
              child: Padding(
                padding: EdgeInsets.symmetric(vertical: scaled(10), horizontal: scaled(14)),
                child: _buildContent(context, m, scale),
              ),
            ),
          ),
          SizedBox(height: scaled(4)),
          Text(
            _formatTime(m.createdAt),
            style: TextStyle(fontSize: scaled(11), color: Colors.black.withOpacity(.45)),
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

  Widget _buildContent(BuildContext context, ChatMessage m, double scale) {
    switch (m.kind) {
      case 'text':
        return SelectableText(
          m.body ?? '',
          style: TextStyle(fontSize: 15 * scale, height: 1.25),
        );

      case 'image':
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _ImageWidget(
              url: m.fileUrl ?? '',
              mime: m.fileMime,
              title: (m.body ?? '').isNotEmpty ? m.body : 'Фото',
              scale: scale,
            ),
            if ((m.body ?? '').isNotEmpty) ...[
              SizedBox(height: 6 * scale),
              Text(m.body!, style: TextStyle(fontSize: 14 * scale)),
            ]
          ],
        );

      case 'video':
        return _FileTile(
          icon: Icons.videocam,
          title: m.body?.isNotEmpty == true ? m.body! : 'Видео',
          url: m.fileUrl,
          mime: m.fileMime,
          scale: scale,
        );

      case 'audio':
        return _AudioTile(url: m.fileUrl, durationMs: m.durationMs, scale: scale);

      default:
        return _FileTile(
          icon: Icons.insert_drive_file,
          title: m.body?.isNotEmpty == true ? m.body! : 'Файл',
          url: m.fileUrl,
          mime: m.fileMime,
          scale: scale,
        );
    }
  }
}

class _ImageWidget extends StatelessWidget {
  final String url;
  final String? mime;
  final String? title;
  final double scale;
  const _ImageWidget({
    required this.url,
    this.mime,
    this.title,
    this.scale = 1.0,
  });

  @override
  Widget build(BuildContext context) {
    final w = MediaQuery.of(context).size.width * 0.70;
    final h = w * 0.66;
    double scaled(double value) => value * scale;
    return ClipRRect(
      borderRadius: BorderRadius.circular(scaled(12)),
      child: GestureDetector(
        onTap: () {
          if (url.isEmpty) return;
          showMediaPreview(
            context,
            url: url,
            mime: mime,
            title: title,
          );
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
            child: Icon(Icons.broken_image, size: scaled(24)),
          ),
          loadingBuilder: (context, child, loadingProgress) {
            if (loadingProgress == null) return child;
            return SizedBox(
              width: w,
              height: h,
              child: Center(child: CircularProgressIndicator(strokeWidth: scaled(2))),
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
  final String? mime;
  final double scale;

  const _FileTile({
    required this.icon,
    required this.title,
    required this.url,
    this.mime,
    this.scale = 1.0,
  });

  @override
  Widget build(BuildContext context) {
    double scaled(double value) => value * scale;
    return InkWell(
      onTap: url == null
          ? null
          : () => showMediaPreview(
                context,
                url: url!,
                mime: mime,
                title: title,
              ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: scaled(18)),
          SizedBox(width: scaled(8)),
          Flexible(child: Text(title, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: scaled(13)))),
        ],
      ),
    );
  }
}

class _AudioTile extends StatefulWidget {
  final String? url;
  final int? durationMs;
  final double scale;
  const _AudioTile({this.url, this.durationMs, this.scale = 1.0});

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
    final double iconSize = widget.scale * 24;
    final VisualDensity density = widget.scale < 1.0
        ? const VisualDensity(horizontal: -2, vertical: -2)
        : VisualDensity.standard;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        IconButton(
          icon: Icon(_playing ? Icons.stop_circle : Icons.play_arrow),
          iconSize: iconSize,
          visualDensity: density,
          onPressed: _toggle,
        ),
        Text('Голосовое$durText', style: TextStyle(fontSize: 14 * widget.scale)),
      ],
    );
  }
}
