
import 'dart:async';
import 'dart:collection';
import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path/path.dart' as p;
import 'package:provider/provider.dart';
import 'package:record/record.dart';
import 'package:mime/mime.dart';
import '../../analytics/models/claim_model.dart';
import '../../analytics/repositories/claims_repository.dart';
import '../chat_mention_candidate.dart';
import '../chat_message.dart';
import '../chat_provider.dart';
import 'claim_employee_picker.dart';

class ChatInputBar extends StatefulWidget {
  final String roomId;
  final String? senderId;
  final String? senderName;
  final double scale;
  final bool compact;

  /// Тех-лидер/менеджер: фото и видео уходят через превью с возможностью
  /// оформить претензию. Для остальных ролей поведение прежнее.
  final bool canCreateClaim;

  const ChatInputBar({
    super.key,
    required this.roomId,
    required this.senderId,
    required this.senderName,
    this.scale = 1.0,
    this.compact = false,
    this.canCreateClaim = false,
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
  bool _isDisposed = false;

  /// Медиа, ожидающее подтверждения отправки (только при canCreateClaim).
  _PendingAttachment? _pending;

  /// Сотрудники, выбранные для претензии к _pending.
  final List<ChatMentionCandidate> _claimSelection = <ChatMentionCandidate>[];
  final ClaimsRepository _claimsRepo = ClaimsRepository();
  bool _sendingPending = false;

  /// Снимает фото через камеру устройства и отправляет его в чат. Если
  /// пользователь отменяет съёмку, ничего не происходит. Этот метод
  /// позволяет техническому специалисту быстро сделать снимок без выхода
  /// из приложения. Для сохранения совместимости с Web вызовы камеры
  /// доступны только на мобильных платформах.
  Future<void> _takePhoto() async {
    if (_isDisposed || !mounted) return;
    final picker = ImagePicker();
    try {
      final XFile? image = await picker.pickImage(source: ImageSource.camera, imageQuality: 85);
      if (image == null) return;
      final bytes = await image.readAsBytes();
      final mime = lookupMimeType(image.path, headerBytes: _mimeHeader(bytes)) ?? 'image/jpeg';
      if (_isDisposed || !mounted) return;
      await _handlePickedMedia(
        bytes: bytes,
        filename: image.name.isNotEmpty ? image.name : p.basename(image.path),
        mime: mime,
      );
    } catch (error) {
      _showErrorSnackBar('Не удалось отправить фото: $error');
    }
  }

  /// Фото/видео: при canCreateClaim показываем превью с кнопкой «Претензия»,
  /// иначе отправляем сразу (прежнее поведение для остальных ролей).
  Future<void> _handlePickedMedia({
    required Uint8List bytes,
    required String filename,
    required String mime,
  }) async {
    if (widget.canCreateClaim) {
      setState(() {
        _pending = _PendingAttachment(
          bytes: bytes,
          filename: filename,
          mime: mime,
          kind: _kindFromMime(mime),
        );
      });
      return;
    }
    await _sendMediaNow(bytes: bytes, filename: filename, mime: mime);
  }

  Future<void> _sendMediaNow({
    required Uint8List bytes,
    required String filename,
    required String mime,
  }) async {
    final chat = context.read<ChatProvider>();
    final caption = _attachmentCaption();
    if (_isDisposed || !mounted) return;
    await chat.sendFile(
      roomId: widget.roomId,
      senderId: widget.senderId,
      senderName: widget.senderName,
      bytes: bytes,
      filename: filename,
      mime: mime,
      body: caption,
      kind: _kindFromMime(mime),
    );
    _clearAttachmentCaption();
  }

  @override
  void initState() {
    super.initState();
    _controller.addListener(_handleControllerChanged);
    _focusNode.addListener(_handleFocusChanged);
  }

  @override
  void dispose() {
    _isDisposed = true;
    _mentionRequestId++;
    _controller.removeListener(_handleControllerChanged);
    _focusNode.removeListener(_handleFocusChanged);
    _hideMentionOverlay();
    _focusNode.dispose();
    _controller.dispose();
    unawaited(_disposeRecorder());
    super.dispose();
  }

  void _handleFocusChanged() {
    if (_isDisposed || !mounted) return;
    if (!_focusNode.hasFocus) {
      _hideMentionOverlay();
    } else {
      unawaited(_refreshMentionSuggestions());
    }
  }

  /// Отмена pending-вложения: ничего никуда не пишется,
  /// набранный текст остаётся в поле ввода.
  void _cancelPending() {
    if (_isDisposed || !mounted) return;
    setState(() {
      _pending = null;
      _claimSelection.clear();
    });
  }

  Future<void> _openClaimPicker() async {
    if (_isDisposed || !mounted) return;
    final chat = context.read<ChatProvider>();
    final picked = await showClaimEmployeePicker(
      context,
      loadCandidates: chat.claimCandidates,
      initiallySelected: _claimSelection,
    );
    if (picked == null || _isDisposed || !mounted) return;
    setState(() {
      _claimSelection
        ..clear()
        ..addAll(picked);
    });
  }

  /// Отправка pending-медиа. Порядок зафиксирован:
  /// 1) insert претензий (batch); 2) при успехе — сообщение с claim_targets;
  /// при провале insert — сообщение БЕЗ claim_targets + SnackBar.
  /// Если упал сам sendFile после успешного insert — best-effort откат
  /// созданных претензий (требует delete-политику RLS, иначе no-op + лог).
  Future<void> _sendPendingAttachment() async {
    final pending = _pending;
    if (pending == null || _sendingPending || _isDisposed || !mounted) return;
    setState(() => _sendingPending = true);
    final chat = context.read<ChatProvider>();
    final caption = _attachmentCaption();
    final plainCaption = _controller.text.trim();
    final messageId = chat.newMessageId();

    var targets = <ChatClaimTarget>[];
    var createdClaims = const <ClaimModel>[];
    if (_claimSelection.isNotEmpty) {
      try {
        createdClaims = await _claimsRepo.createForChatMessage(
          employeeIds: [for (final c in _claimSelection) c.id],
          messageId: messageId,
          fileUrl: chat.mediaPublicUrl(
              widget.roomId, messageId, pending.filename),
          fileMime: pending.mime,
          description: plainCaption.isEmpty ? null : plainCaption,
          createdBy: widget.senderId,
          authorName: widget.senderName,
        );
        targets = [
          for (final c in _claimSelection)
            ChatClaimTarget(id: c.id, name: c.displayName),
        ];
      } catch (error) {
        debugPrint('Claims insert failed for message $messageId: $error');
        _showErrorSnackBar('Претензии не созданы');
      }
    }

    try {
      await chat.sendFile(
        roomId: widget.roomId,
        senderId: widget.senderId,
        senderName: widget.senderName,
        bytes: pending.bytes,
        filename: pending.filename,
        mime: pending.mime,
        body: caption,
        kind: pending.kind,
        messageId: messageId,
        claimTargets: targets,
      );
      if (_isDisposed || !mounted) return;
      setState(() {
        _pending = null;
        _claimSelection.clear();
      });
      _clearAttachmentCaption();
    } catch (error) {
      if (createdClaims.isNotEmpty) {
        final ids = [for (final c in createdClaims) c.id];
        debugPrint('sendFile failed after claims insert, '
            'rolling back claims $ids: $error');
        try {
          await _claimsRepo.deleteByIds(ids);
        } catch (cleanupError) {
          debugPrint('Claims rollback failed (orphans $ids): $cleanupError');
        }
      }
      _showErrorSnackBar('Не удалось отправить: $error');
    } finally {
      if (!_isDisposed && mounted) {
        setState(() => _sendingPending = false);
      } else {
        _sendingPending = false;
      }
    }
  }

  Future<void> _sendText() async {
    if (_isDisposed || !mounted) return;
    if (_pending != null) {
      // Есть неотправленное вложение: кнопка «Отправить» шлёт его
      // (с подписью из поля ввода), а не отдельное текстовое сообщение.
      await _sendPendingAttachment();
      return;
    }
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
    if (_isDisposed || !mounted) return;
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
    if (_isDisposed || !mounted) return;
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
      final allowedBefore = RegExp(r'[\s.,!?;:()\[\]{}<>"-]');
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
    if (_isDisposed || !mounted || requestId != _mentionRequestId) return;
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
    if (_isDisposed || !mounted) return;
    if (_mentionOverlay == null) {
      final overlayState = Overlay.of(context);
      _mentionOverlay = OverlayEntry(builder: _buildMentionOverlay);
      overlayState.insert(_mentionOverlay!);
    } else {
      _mentionOverlay!.markNeedsBuild();
    }
  }

  void _hideMentionOverlay() {
    final overlay = _mentionOverlay;
    if (overlay != null && overlay.mounted) {
      overlay.remove();
    }
    _mentionOverlay = null;
    _mentionSuggestions = const [];
    _mentionTriggerIndex = null;
  }

  Widget _buildMentionOverlay(BuildContext context) {
    if (_isDisposed || !mounted || _mentionSuggestions.isEmpty) {
      return const SizedBox.shrink();
    }
    final renderBox = _fieldKey.currentContext?.findRenderObject() as RenderBox?;
    if (renderBox == null || !renderBox.attached) {
      return const SizedBox.shrink();
    }
    final size = renderBox.size;
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
    if (_isDisposed || !mounted) return;
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

  String? _attachmentCaption() {
    _cleanupObsoleteMentions();
    var prepared = _controller.text;
    if (_selectedMentions.isNotEmpty) {
      prepared = _applyMentionMarkup(prepared);
    }
    prepared = prepared.trim();
    return prepared.isEmpty ? null : prepared;
  }

  void _clearAttachmentCaption() {
    if (_isDisposed || !mounted) return;
    _controller.clear();
    _selectedMentions.clear();
    _hideMentionOverlay();
  }

  List<int>? _mimeHeader(Uint8List bytes) {
    if (bytes.isEmpty) return null;
    final length = bytes.length > 12 ? 12 : bytes.length;
    return bytes.sublist(0, length);
  }

  String _kindFromMime(String mime) {
    final normalized = mime.toLowerCase().trim();
    if (normalized.startsWith('image/')) return 'image';
    if (normalized.startsWith('video/')) return 'video';
    if (normalized.startsWith('audio/')) return 'audio';
    return 'file';
  }

  Future<Uint8List> _readPickedFileBytes(PlatformFile file) async {
    final bytes = file.bytes;
    if (bytes != null) return bytes;

    final stream = file.readStream;
    if (stream != null) {
      final builder = BytesBuilder(copy: false);
      await for (final chunk in stream) {
        builder.add(chunk);
      }
      return builder.takeBytes();
    }

    final filePath = file.path;
    if (filePath != null) {
      return File(filePath).readAsBytes();
    }

    throw Exception('Не удалось прочитать выбранный файл');
  }

  void _showErrorSnackBar(String message) {
    if (_isDisposed || !mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _pickImage() async {
    if (_isDisposed || !mounted) return;
    final picker = ImagePicker();
    try {
      final x = await picker.pickImage(source: ImageSource.gallery, imageQuality: 85);
      if (x == null) return;
      final bytes = await x.readAsBytes();
      final mime = lookupMimeType(x.path, headerBytes: _mimeHeader(bytes)) ?? 'image/jpeg';
      if (_isDisposed || !mounted) return;
      await _handlePickedMedia(
        bytes: bytes,
        filename: x.name.isNotEmpty ? x.name : p.basename(x.path),
        mime: mime,
      );
    } catch (error) {
      _showErrorSnackBar('Не удалось отправить изображение: $error');
    }
  }

  Future<void> _pickVideo() async {
    if (_isDisposed || !mounted) return;
    final picker = ImagePicker();
    try {
      final x = await picker.pickVideo(source: ImageSource.gallery);
      if (x == null) return;
      final bytes = await x.readAsBytes();
      final mime = lookupMimeType(x.path, headerBytes: _mimeHeader(bytes)) ?? 'video/mp4';
      if (_isDisposed || !mounted) return;
      await _handlePickedMedia(
        bytes: bytes,
        filename: x.name.isNotEmpty ? x.name : p.basename(x.path),
        mime: mime,
      );
    } catch (error) {
      _showErrorSnackBar('Не удалось отправить видео: $error');
    }
  }

  Future<void> _pickAnyFile() async {
    if (_isDisposed || !mounted) return;
    final chat = context.read<ChatProvider>();
    try {
      final res = await FilePicker.platform.pickFiles(withReadStream: true);
      if (res == null || res.files.isEmpty) return;
      final f = res.files.first;
      final bytes = await _readPickedFileBytes(f);
      final mime = lookupMimeType(
            f.path ?? f.name,
            headerBytes: _mimeHeader(bytes),
          ) ??
          'application/octet-stream';
      final caption = _attachmentCaption();
      if (_isDisposed || !mounted) return;
      await chat.sendFile(
        roomId: widget.roomId,
        senderId: widget.senderId,
        senderName: widget.senderName,
        bytes: bytes,
        filename: f.name,
        mime: mime,
        body: caption,
        kind: _kindFromMime(mime),
      );
      _clearAttachmentCaption();
    } catch (error) {
      _showErrorSnackBar('Не удалось отправить файл: $error');
    }
  }

  Future<void> _toggleRecord() async {
    if (_isDisposed || !mounted) return;
    try {
      if (kIsWeb) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Запись аудио не поддерживается в Web')),
        );
        return;
      }
      _recorder ??= AudioRecorder();
      if (!await _recorder!.hasPermission()) {
        if (_isDisposed || !mounted) return;
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
        if (_isDisposed || !mounted) return;
        setState(() => _recording = true);
      }
    } catch (error) {
      _showErrorSnackBar('Не удалось обработать аудиозапись: $error');
    }
  }

  Future<void> _stopRecordingIfNeeded({bool notify = true}) async {
    if (!_recording || _recorder == null) return;
    final chat = mounted && !_isDisposed ? context.read<ChatProvider>() : null;
    final path = await _recorder!.stop();
    if (notify && mounted) {
      setState(() => _recording = false);
    } else {
      _recording = false;
    }
    if (path == null) return;
    if (chat == null || _isDisposed || !mounted) return;
    final file = File(path);
    if (!await file.exists()) return;
    try {
      final bytes = await file.readAsBytes();
      const mime = 'audio/mp4';
      // duration неизвестна: плеер на стороне клиента покажет длину по факту воспроизведения
      await chat.sendFile(
        roomId: widget.roomId,
        senderId: widget.senderId,
        senderName: widget.senderName,
        bytes: bytes,
        filename: p.basename(path),
        mime: mime,
        kind: _kindFromMime(mime),
      );
    } finally {
      try {
        await file.delete();
      } catch (_) {}
    }
  }

  Future<void> _disposeRecorder() async {
    final recorder = _recorder;
    _recorder = null;
    if (recorder == null) return;
    try {
      if (_recording) {
        await recorder.stop();
      }
      await recorder.dispose();
    } catch (_) {
      // Recorder cleanup is best-effort during widget teardown.
    }
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
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (_pending != null) _buildPendingPanel(context),
          Row(
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
        ],
      ),
    );
  }

  /// Превью вложения до отправки: миниатюра, чипы претензии и кнопки
  /// «Претензия» / «Отправить» / «Отмена». Показывается только при
  /// canCreateClaim — остальные роли этого экрана не видят.
  Widget _buildPendingPanel(BuildContext context) {
    final pending = _pending!;
    double scaled(double value) => value * widget.scale;
    final theme = Theme.of(context);
    final isImage = pending.kind == 'image';

    return Container(
      margin: EdgeInsets.only(bottom: scaled(6)),
      padding: EdgeInsets.all(scaled(8)),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceVariant.withOpacity(.5),
        borderRadius: BorderRadius.circular(scaled(10)),
        border: Border.all(color: theme.dividerColor),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(scaled(8)),
                child: isImage
                    ? Image.memory(
                        pending.bytes,
                        width: scaled(64),
                        height: scaled(64),
                        fit: BoxFit.cover,
                        errorBuilder: (_, __, ___) => Icon(
                            Icons.broken_image,
                            size: scaled(40)),
                      )
                    : Container(
                        width: scaled(64),
                        height: scaled(64),
                        color: theme.colorScheme.primary.withOpacity(.12),
                        child: Icon(
                          pending.kind == 'video'
                              ? Icons.videocam
                              : Icons.insert_drive_file,
                          size: scaled(32),
                          color: theme.colorScheme.primary,
                        ),
                      ),
              ),
              SizedBox(width: scaled(10)),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      pending.filename,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: scaled(13),
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    SizedBox(height: scaled(2)),
                    Text(
                      pending.sizeLabel,
                      style: TextStyle(
                        fontSize: scaled(11),
                        color: theme.colorScheme.onSurface.withOpacity(.6),
                      ),
                    ),
                  ],
                ),
              ),
              IconButton(
                tooltip: 'Отмена',
                visualDensity: VisualDensity.compact,
                icon: const Icon(Icons.close),
                onPressed: _sendingPending ? null : _cancelPending,
              ),
            ],
          ),
          if (_claimSelection.isNotEmpty) ...[
            SizedBox(height: scaled(6)),
            Wrap(
              spacing: scaled(6),
              runSpacing: scaled(4),
              children: [
                for (final c in _claimSelection)
                  InputChip(
                    label: Text(c.displayName),
                    visualDensity: VisualDensity.compact,
                    avatar: Icon(Icons.flag_outlined, size: scaled(16)),
                    onDeleted: _sendingPending
                        ? null
                        : () => setState(() => _claimSelection.remove(c)),
                  ),
              ],
            ),
          ],
          SizedBox(height: scaled(6)),
          Row(
            children: [
              OutlinedButton.icon(
                icon: Icon(Icons.flag_outlined, size: scaled(18)),
                label: Text(_claimSelection.isEmpty
                    ? 'Претензия'
                    : 'Претензия (${_claimSelection.length})'),
                onPressed: _sendingPending ? null : _openClaimPicker,
              ),
              const Spacer(),
              TextButton(
                onPressed: _sendingPending ? null : _cancelPending,
                child: const Text('Отмена'),
              ),
              SizedBox(width: scaled(6)),
              FilledButton.icon(
                icon: _sendingPending
                    ? SizedBox(
                        width: scaled(16),
                        height: scaled(16),
                        child: const CircularProgressIndicator(strokeWidth: 2),
                      )
                    : Icon(Icons.send, size: scaled(18)),
                label: const Text('Отправить'),
                onPressed: _sendingPending ? null : _sendPendingAttachment,
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// Медиафайл, выбранный, но ещё не отправленный (превью перед отправкой).
class _PendingAttachment {
  final Uint8List bytes;
  final String filename;
  final String mime;
  final String kind; // image | video

  const _PendingAttachment({
    required this.bytes,
    required this.filename,
    required this.mime,
    required this.kind,
  });

  String get sizeLabel {
    final kb = bytes.length / 1024;
    if (kb < 1024) return '${kb.toStringAsFixed(0)} КБ';
    return '${(kb / 1024).toStringAsFixed(1)} МБ';
  }
}

class _PendingMention {
  final String display;
  final String id;
  const _PendingMention({required this.display, required this.id});
}