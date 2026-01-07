
import 'dart:async';
import 'dart:collection';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path/path.dart' as p;
import 'package:provider/provider.dart';
import 'package:record/record.dart';
import 'package:mime/mime.dart';
import '../chat_mention_candidate.dart';
import '../chat_provider.dart';

class ChatInputBar extends StatefulWidget {
  final String roomId;
  final String? senderId;
  final String? senderName;
  final double scale;
  final bool compact;

  const ChatInputBar({
    super.key,
    required this.roomId,
    required this.senderId,
    required this.senderName,
    this.scale = 1.0,
    this.compact = false,
  });

  @override
  State<ChatInputBar> createState() => _ChatInputBarState();
}

class _ChatInputBarState extends State<ChatInputBar> {
  final _controller = TextEditingController();
  AudioRecorder? _recorder;
  bool _recording = false;
  final FocusNode _focusNode = FocusNode();
  final LayerLink _mentionLink = LayerLink();
  final GlobalKey _fieldKey = GlobalKey();
  OverlayEntry? _mentionOverlay;
  List<ChatMentionCandidate> _mentionSuggestions = const [];
  int? _mentionTriggerIndex;
  final List<_PendingMention> _selectedMentions = <_PendingMention>[];
  int _mentionRequestId = 0;

  /// Снимает фото через камеру устройства и отправляет его в чат. Если
  /// пользователь отменяет съёмку, ничего не происходит. Этот метод
  /// позволяет техническому специалисту быстро сделать снимок без выхода
  /// из приложения. Для сохранения совместимости с Web вызовы камеры
  /// доступны только на мобильных платформах.
  Future<void> _takePhoto() async {
    final picker = ImagePicker();
    try {
      final XFile? image = await picker.pickImage(source: ImageSource.camera, imageQuality: 85);
      if (image == null) return;
      final bytes = await image.readAsBytes();
      final mime = lookupMimeType(image.path) ?? 'image/jpeg';
      await context.read<ChatProvider>().sendFile(
            roomId: widget.roomId,
            senderId: widget.senderId,
            senderName: widget.senderName,
            bytes: bytes,
            filename: p.basename(image.path),
            mime: mime,
            kind: 'image',
          );
    } catch (_) {
      // Игнорируем ошибки камеры
    }
  }

  @override
  void initState() {
    super.initState();
    _controller.addListener(_handleControllerChanged);
    _focusNode.addListener(() {
      if (!_focusNode.hasFocus) {
        _hideMentionOverlay();
      } else {
        unawaited(_refreshMentionSuggestions());
      }
    });
  }

  @override
  void dispose() {
    _controller.removeListener(_handleControllerChanged);
    _hideMentionOverlay();
    _focusNode.dispose();
    _controller.dispose();
    _stopRecordingIfNeeded(notify: false);
    super.dispose();
  }

  Future<void> _sendText() async {
    _cleanupObsoleteMentions();
    var prepared = _controller.text;
    if (prepared.trim().isEmpty) return;
    if (_selectedMentions.isNotEmpty) {
      prepared = _applyMentionMarkup(prepared);
    }
    prepared = prepared.trim();
    if (prepared.isEmpty) return;
    final chat = context.read<ChatProvider>();
    await chat.sendText(
      roomId: widget.roomId,
      senderId: widget.senderId,
      senderName: widget.senderName,
      text: prepared,
    );
    _controller.clear();
    _selectedMentions.clear();
    _hideMentionOverlay();
  }

  void _handleControllerChanged() {
    _cleanupObsoleteMentions();
    unawaited(_refreshMentionSuggestions());
  }

  void _cleanupObsoleteMentions() {
    if (_selectedMentions.isEmpty) return;
    final text = _controller.text;
    if (text.isEmpty) {
      if (_selectedMentions.isNotEmpty) {
        _selectedMentions.clear();
      }
      return;
    }
    final uniqueDisplays = _selectedMentions.map((m) => m.display).toSet();
    final countsInText = <String, int>{};
    for (final display in uniqueDisplays) {
      countsInText[display] = _countOccurrences(text, display);
    }
    final filtered = <_PendingMention>[];
    final used = <String, int>{};
    for (final mention in _selectedMentions) {
      final display = mention.display;
      final available = countsInText[display] ?? 0;
      if (available <= 0) continue;
      final current = used.update(display, (value) => value + 1, ifAbsent: () => 1);
      if (current <= available) {
        filtered.add(mention);
      }
    }
    if (filtered.length != _selectedMentions.length) {
      _selectedMentions
        ..clear()
        ..addAll(filtered);
    }
  }

  int _countOccurrences(String source, String pattern) {
    if (pattern.isEmpty || source.isEmpty) return 0;
    var count = 0;
    var index = source.indexOf(pattern);
    while (index != -1) {
      count++;
      index = source.indexOf(pattern, index + pattern.length);
    }
    return count;
  }

  String _applyMentionMarkup(String text) {
    if (_selectedMentions.isEmpty) return text;
    final queues = <String, Queue<String>>{};
    for (final mention in _selectedMentions) {
      final queue = queues.putIfAbsent(mention.display, () => Queue<String>());
      queue.add(mention.id);
    }
    if (queues.isEmpty) return text;
    final order = queues.keys.toList()
      ..sort((a, b) => b.length.compareTo(a.length));
    final buffer = StringBuffer();
    var index = 0;
    while (index < text.length) {
      final atIndex = text.indexOf('@', index);
      if (atIndex == -1) {
        buffer.write(text.substring(index));
        break;
      }
      buffer.write(text.substring(index, atIndex));
      var replaced = false;
      for (final display in order) {
        if (display.isEmpty) continue;
        final queue = queues[display];
        if (queue == null || queue.isEmpty) continue;
        if (text.startsWith(display, atIndex)) {
          final id = queue.removeFirst();
          final markup = '@{${display.substring(1)}|$id}';
          buffer.write(markup);
          index = atIndex + display.length;
          replaced = true;
          break;
        }
      }
      if (!replaced) {
        buffer.write('@');
        index = atIndex + 1;
      }
    }
    return buffer.toString();
  }

  Future<void> _refreshMentionSuggestions() async {
    final requestId = ++_mentionRequestId;
    if (!_focusNode.hasFocus) {
      _hideMentionOverlay();
      return;
    }
    final selection = _controller.selection;
    if (!selection.isValid) {
      _hideMentionOverlay();
      return;
    }
    final cursor = selection.end;
    if (cursor < 0) {
      _hideMentionOverlay();
      return;
    }
    final text = _controller.text;
    if (cursor > text.length) {
      _hideMentionOverlay();
      return;
    }
    final prefix = text.substring(0, cursor);
    final atIndex = prefix.lastIndexOf('@');
    if (atIndex == -1) {
      _hideMentionOverlay();
      return;
    }
    if (atIndex > 0) {
      final before = prefix.substring(atIndex - 1, atIndex);
      final allowedBefore = RegExp("[\s.,!?;:()\[\]{}<>\"-]");
      if (!allowedBefore.hasMatch(before)) {
        _hideMentionOverlay();
        return;
      }
    }
    final querySegment = text.substring(atIndex + 1, cursor);
    if (querySegment.contains(RegExp(r'[\r\n]'))) {
      _hideMentionOverlay();
      return;
    }
    final chat = context.read<ChatProvider>();
    final suggestions = await chat.mentionCandidates(query: querySegment.trimLeft());
    if (!mounted || requestId != _mentionRequestId) return;
    if (suggestions.isEmpty) {
      _hideMentionOverlay();
      return;
    }
    setState(() {
      _mentionTriggerIndex = atIndex;
      _mentionSuggestions = suggestions;
    });
    _showMentionOverlay();
  }

  void _showMentionOverlay() {
    if (_mentionOverlay == null) {
      final overlayState = Overlay.of(context);
      if (overlayState == null) return;
      _mentionOverlay = OverlayEntry(builder: _buildMentionOverlay);
      overlayState.insert(_mentionOverlay!);
    } else {
      _mentionOverlay!.markNeedsBuild();
    }
  }

  void _hideMentionOverlay() {
    _mentionOverlay?.remove();
    _mentionOverlay = null;
    _mentionSuggestions = const [];
    _mentionTriggerIndex = null;
  }

  Widget _buildMentionOverlay(BuildContext context) {
    if (_mentionSuggestions.isEmpty) {
      return const SizedBox.shrink();
    }
    final renderBox = _fieldKey.currentContext?.findRenderObject() as RenderBox?;
    final size = renderBox?.size ?? Size.zero;
    final width = size.width > 0 ? size.width : MediaQuery.of(context).size.width * 0.6;
    final offsetY = size.height + 4 * widget.scale;
    final density = widget.compact
        ? const VisualDensity(horizontal: -2, vertical: -2)
        : VisualDensity.standard;
    return Positioned(
      width: width,
      child: CompositedTransformFollower(
        link: _mentionLink,
        showWhenUnlinked: false,
        offset: Offset(0, offsetY),
        child: Material(
          elevation: 4,
          borderRadius: BorderRadius.circular(8),
          clipBehavior: Clip.antiAlias,
          child: ConstrainedBox(
            constraints: BoxConstraints(maxHeight: 240 * widget.scale),
            child: ListView.builder(
              padding: EdgeInsets.zero,
              shrinkWrap: true,
              itemCount: _mentionSuggestions.length,
              itemBuilder: (context, index) {
                final candidate = _mentionSuggestions[index];
                return ListTile(
                  dense: true,
                  visualDensity: density,
                  title: Text(candidate.displayName),
                  onTap: () => _insertMention(candidate),
                );
              },
            ),
          ),
        ),
      ),
    );
  }

  void _insertMention(ChatMentionCandidate candidate) {
    final trigger = _mentionTriggerIndex;
    if (trigger == null) return;
    final selection = _controller.selection;
    if (!selection.isValid) return;
    var start = trigger;
    var end = selection.end;
    if (end < start) {
      final tmp = start;
      start = end;
      end = tmp;
    }
    final text = _controller.text;
    if (start < 0 || start > text.length) return;
    if (end < 0 || end > text.length) return;
    final before = text.substring(0, start);
    final after = text.substring(end);
    final mentionText = '@${candidate.displayName}';
    final nextChar = after.isNotEmpty ? after[0] : null;
    final needsSpaceAfter =
        nextChar == null ? true : !RegExp(r'[\s.,!?;:()]').hasMatch(nextChar);
    final insertion = mentionText + (needsSpaceAfter ? ' ' : '');
    final updated = '$before$insertion$after';
    _controller.value = TextEditingValue(
      text: updated,
      selection: TextSelection.collapsed(offset: before.length + insertion.length),
    );
    _selectedMentions.add(_PendingMention(display: mentionText, id: candidate.id));
    _hideMentionOverlay();
    _cleanupObsoleteMentions();
  }

  Future<void> _pickImage() async {
    final picker = ImagePicker();
    final x = await picker.pickImage(source: ImageSource.gallery, imageQuality: 85);
    if (x == null) return;
    final bytes = await x.readAsBytes();
    final mime = lookupMimeType(x.path) ?? 'image/jpeg';
    await context.read<ChatProvider>().sendFile(
          roomId: widget.roomId,
          senderId: widget.senderId,
          senderName: widget.senderName,
          bytes: bytes,
          filename: p.basename(x.path),
          mime: mime,
          kind: 'image',
        );
  }

  Future<void> _pickVideo() async {
    final picker = ImagePicker();
    final x = await picker.pickVideo(source: ImageSource.gallery);
    if (x == null) return;
    final bytes = await x.readAsBytes();
    final mime = lookupMimeType(x.path) ?? 'video/mp4';
    await context.read<ChatProvider>().sendFile(
          roomId: widget.roomId,
          senderId: widget.senderId,
          senderName: widget.senderName,
          bytes: bytes,
          filename: p.basename(x.path),
          mime: mime,
          kind: 'video',
        );
  }

  Future<void> _pickAnyFile() async {
    final res = await FilePicker.platform.pickFiles(withReadStream: true);
    if (res == null || res.files.isEmpty) return;
    final f = res.files.first;
    final bytes = f.bytes ?? await File(f.path!).readAsBytes();
    final mime = lookupMimeType(
          f.path ?? f.name,
          headerBytes:
              f.bytes?.sublist(0, (f.bytes?.length ?? 0) > 12 ? 12 : (f.bytes?.length ?? 0)),
        ) ??
        'application/octet-stream';
    String kind = 'file';
    if ((mime).startsWith('image/')) kind = 'image';
    else if (mime.startsWith('video/')) kind = 'video';
    else if (mime.startsWith('audio/')) kind = 'audio';
    await context.read<ChatProvider>().sendFile(
          roomId: widget.roomId,
          senderId: widget.senderId,
          senderName: widget.senderName,
          bytes: bytes,
          filename: f.name,
          mime: mime,
          kind: kind,
        );
  }

  Future<void> _toggleRecord() async {
    if (kIsWeb) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Запись аудио не поддерживается в Web')),
      );
      return;
    }
    _recorder ??= AudioRecorder();
    if (!await _recorder!.hasPermission()) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Нет разрешения на запись')),
      );
      return;
    }
    if (_recording) {
      await _stopRecordingIfNeeded();
    } else {
      final dir = Directory.systemTemp.createTempSync('chat_audio_');
      final path = p.join(dir.path, 'voice_${DateTime.now().millisecondsSinceEpoch}.m4a');
      await _recorder!.start(const RecordConfig(encoder: AudioEncoder.aacLc), path: path);
      setState(() => _recording = true);
    }
  }

  Future<void> _stopRecordingIfNeeded({bool notify = true}) async {
    if (!_recording || _recorder == null) return;
    final path = await _recorder!.stop();
    if (notify && mounted) {
      setState(() => _recording = false);
    } else {
      _recording = false;
    }
    if (path == null) return;
    final file = File(path);
    if (!await file.exists()) return;
    final bytes = await file.readAsBytes();
    // duration неизвестна: плеер на стороне клиента покажет длину по факту воспроизведения
    await context.read<ChatProvider>().sendFile(
          roomId: widget.roomId,
          senderId: widget.senderId,
          senderName: widget.senderName,
          bytes: bytes,
          filename: p.basename(path),
          mime: 'audio/mp4',
          kind: 'audio',
        );
    // очистка
    try { await file.delete(); } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    double scaled(double value) => value * widget.scale;
    final double iconSize = scaled(widget.compact ? 22 : 24);
    final VisualDensity density =
        widget.compact ? const VisualDensity(horizontal: -2, vertical: -2) : VisualDensity.standard;
    final double gap = scaled(6);
    final EdgeInsets inputPadding =
        EdgeInsets.symmetric(horizontal: scaled(12), vertical: scaled(widget.compact ? 8 : 10));

    return SafeArea(
      top: false,
      child: Row(
        children: [
          IconButton(
            tooltip: 'Камера',
            visualDensity: density,
            iconSize: iconSize,
            icon: const Icon(Icons.camera_alt_outlined),
            onPressed: _takePhoto,
          ),
          IconButton(
            tooltip: 'Фото',
            visualDensity: density,
            iconSize: iconSize,
            icon: const Icon(Icons.image_outlined),
            onPressed: _pickImage,
          ),
          IconButton(
            tooltip: 'Видео',
            visualDensity: density,
            iconSize: iconSize,
            icon: const Icon(Icons.videocam_outlined),
            onPressed: _pickVideo,
          ),
          IconButton(
            tooltip: 'Файл',
            visualDensity: density,
            iconSize: iconSize,
            icon: const Icon(Icons.attach_file),
            onPressed: _pickAnyFile,
          ),
          Expanded(
            child: CompositedTransformTarget(
              link: _mentionLink,
              child: TextField(
                key: _fieldKey,
                focusNode: _focusNode,
                controller: _controller,
                textInputAction: TextInputAction.newline,
                minLines: 1,
                maxLines: 5,
                decoration: InputDecoration(
                  hintText: 'Сообщение',
                  border: const OutlineInputBorder(),
                  isDense: true,
                  contentPadding: inputPadding,
                ),
                onTap: () => unawaited(_refreshMentionSuggestions()),
              ),
            ),
          ),
          SizedBox(width: gap),
          IconButton(
            tooltip: _recording ? 'Стоп' : 'Голосовое',
            visualDensity: density,
            iconSize: iconSize,
            icon: Icon(_recording ? Icons.stop_circle : Icons.mic_none),
            onPressed: _toggleRecord,
          ),
          IconButton(
            tooltip: 'Отправить',
            visualDensity: density,
            iconSize: iconSize,
            icon: const Icon(Icons.send),
            onPressed: _sendText,
          ),
        ],
      ),
    );
  }
}

class _PendingMention {
  final String display;
  final String id;
  const _PendingMention({required this.display, required this.id});
}
