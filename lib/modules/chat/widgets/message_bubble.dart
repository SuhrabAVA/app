import 'dart:async';

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
    final mediaWidth = MediaQuery.of(context).size.width;
    final baseWidth = mediaWidth * 0.55;
    final minWidth = 140.0 * scale;
    final maxWidth = mediaWidth * 0.65;
    final double w = baseWidth.clamp(minWidth, maxWidth).toDouble();
    final double h = w * 0.66;
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
  final AudioPlayer _player = AudioPlayer();
  Duration _duration = Duration.zero;
  Duration _position = Duration.zero;
  PlayerState _playerState = PlayerState.stopped;
  bool _sourcePrepared = false;

  StreamSubscription<Duration>? _durationSub;
  StreamSubscription<Duration>? _positionSub;
  StreamSubscription<void>? _completeSub;
  StreamSubscription<PlayerState>? _stateSub;

  bool get _isPlaying => _playerState == PlayerState.playing;

  @override
  void initState() {
    super.initState();
    final presetMs = widget.durationMs;
    if (presetMs != null && presetMs > 0) {
      _duration = Duration(milliseconds: presetMs);
    }
    _durationSub = _player.onDurationChanged.listen((event) {
      if (!mounted) return;
      if (event.inMilliseconds <= 0) return;
      setState(() => _duration = event);
    });
    _positionSub = _player.onPositionChanged.listen((event) {
      if (!mounted) return;
      setState(() => _position = event);
    });
    _stateSub = _player.onPlayerStateChanged.listen((state) {
      if (!mounted) return;
      setState(() => _playerState = state);
    });
    _completeSub = _player.onPlayerComplete.listen((_) {
      if (!mounted) return;
      setState(() {
        _playerState = PlayerState.stopped;
        _position = Duration.zero;
      });
    });

    if ((widget.url ?? '').isNotEmpty) {
      unawaited(_prepareSource());
    }
  }

  @override
  void dispose() {
    _durationSub?.cancel();
    _positionSub?.cancel();
    _stateSub?.cancel();
    _completeSub?.cancel();
    _player.dispose();
    super.dispose();
  }

  Future<void> _prepareSource() async {
    if (_sourcePrepared) return;
    final url = widget.url;
    if (url == null || url.isEmpty) return;
    try {
      await _player.setSourceUrl(url);
      _sourcePrepared = true;
    } catch (_) {}
  }

  Future<void> _toggle() async {
    final url = widget.url;
    if (url == null || url.isEmpty) return;
    if (_isPlaying) {
      await _player.pause();
      return;
    }
    await _prepareSource();
    if (_playerState == PlayerState.paused &&
        _position > Duration.zero &&
        (_duration == Duration.zero || _position < _duration)) {
      await _player.resume();
    } else {
      await _player.play(UrlSource(url));
      _sourcePrepared = true;
    }
  }

  Future<void> _seekTo(double value) async {
    final url = widget.url;
    if (url == null || url.isEmpty) return;
    final target = Duration(milliseconds: value.round());
    await _prepareSource();
    setState(() => _position = target);
    try {
      await _player.seek(target);
    } catch (_) {}
  }

  String _format(Duration d) {
    if (d.inMilliseconds <= 0) return '00:00';
    final minutes = d.inMinutes;
    final seconds = d.inSeconds % 60;
    return '${minutes.toString().padLeft(2, '0')}:${seconds.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final totalMs = _duration.inMilliseconds > 0
        ? _duration.inMilliseconds
        : (widget.durationMs ?? 0);
    final sliderEnabled = totalMs > 0;
    final sliderMax = sliderEnabled ? totalMs.toDouble() : 1.0;
    final currentMs = sliderEnabled
        ? _position.inMilliseconds.clamp(0, totalMs).toDouble()
        : 0.0;
    final totalDuration = sliderEnabled ? Duration(milliseconds: totalMs) : Duration.zero;
    final currentDuration = Duration(milliseconds: currentMs.round());
    final textStyle = TextStyle(
      fontSize: 12 * widget.scale,
      color: theme.colorScheme.onSurface.withOpacity(.6),
    );

    return Row(
      mainAxisSize: MainAxisSize.max,
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Container(
          width: 42 * widget.scale,
          height: 42 * widget.scale,
          decoration: BoxDecoration(
            color: theme.colorScheme.primary.withOpacity(.15),
            shape: BoxShape.circle,
          ),
          child: IconButton(
            icon: Icon(_isPlaying ? Icons.pause : Icons.play_arrow),
            color: theme.colorScheme.primary,
            onPressed: _toggle,
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(),
            splashRadius: 24 * widget.scale,
          ),
        ),
        SizedBox(width: 12 * widget.scale),
        Expanded(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Голосовое сообщение',
                style: TextStyle(
                  fontSize: 13 * widget.scale,
                  fontWeight: FontWeight.w600,
                  color: theme.colorScheme.onSurface.withOpacity(.75),
                ),
              ),
              SizedBox(height: 6 * widget.scale),
              SliderTheme(
                data: SliderTheme.of(context).copyWith(
                  trackHeight: 3 * widget.scale,
                  thumbShape: RoundSliderThumbShape(enabledThumbRadius: 6 * widget.scale),
                  overlayShape: RoundSliderOverlayShape(overlayRadius: 10 * widget.scale),
                  activeTrackColor: theme.colorScheme.primary,
                  thumbColor: theme.colorScheme.primary,
                  inactiveTrackColor: theme.colorScheme.primary.withOpacity(.2),
                ),
                child: Slider(
                  min: 0,
                  max: sliderMax,
                  value: sliderEnabled ? currentMs : 0.0,
                  onChanged: sliderEnabled
                      ? (value) => setState(
                            () => _position = Duration(milliseconds: value.round()),
                          )
                      : null,
                  onChangeEnd: sliderEnabled ? _seekTo : null,
                ),
              ),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(_format(currentDuration), style: textStyle),
                  Text(_format(totalDuration), style: textStyle),
                ],
              ),
            ],
          ),
        ),
      ],
    );
  }
}
