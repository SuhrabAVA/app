
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:mime/mime.dart';
import 'package:path/path.dart' as p;
import 'package:provider/provider.dart';
import 'package:record/record.dart';
import 'package:mime/mime.dart';
import '../chat_provider.dart';

class ChatInputBar extends StatefulWidget {
  final String roomId;
  final String? senderId;
  final String? senderName;

  const ChatInputBar({
    super.key,
    required this.roomId,
    required this.senderId,
    required this.senderName,
  });

  @override
  State<ChatInputBar> createState() => _ChatInputBarState();
}

class _ChatInputBarState extends State<ChatInputBar> {
  final _controller = TextEditingController();
  final _recorder = AudioRecorder();
  bool _recording = false;

  @override
  void dispose() {
    _controller.dispose();
    _stopRecordingIfNeeded();
    super.dispose();
  }

  Future<void> _sendText() async {
    final text = _controller.text.trim();
    if (text.isEmpty) return;
    final chat = context.read<ChatProvider>();
    await chat.sendText(
      roomId: widget.roomId,
      senderId: widget.senderId,
      senderName: widget.senderName,
      text: text,
    );
    _controller.clear();
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
    headerBytes: f.bytes?.sublist(0, (f.bytes?.length ?? 0) > 12 ? 12 : (f.bytes?.length ?? 0)),
    ) ?? 'application/octet-stream';
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
    if (!await _recorder.hasPermission()) {
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
      await _recorder.start(const RecordConfig(encoder: AudioEncoder.aacLc), path: path);
      setState(() => _recording = true);
    }
  }

  Future<void> _stopRecordingIfNeeded() async {
    if (!_recording) return;
    final path = await _recorder.stop();
    setState(() => _recording = false);
    if (path == null) return;
    final file = File(path);
    if (!await file.exists()) return;
    final bytes = await file.readAsBytes();
    final length = await file.length();
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
    return SafeArea(
      top: false,
      child: Row(
        children: [
          IconButton(
            tooltip: 'Фото',
            icon: const Icon(Icons.image_outlined),
            onPressed: _pickImage,
          ),
          IconButton(
            tooltip: 'Видео',
            icon: const Icon(Icons.videocam_outlined),
            onPressed: _pickVideo,
          ),
          IconButton(
            tooltip: 'Файл',
            icon: const Icon(Icons.attach_file),
            onPressed: _pickAnyFile,
          ),
          Expanded(
            child: TextField(
              controller: _controller,
              textInputAction: TextInputAction.newline,
              minLines: 1,
              maxLines: 5,
              decoration: const InputDecoration(
                hintText: 'Сообщение',
                border: OutlineInputBorder(),
                isDense: true,
                contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              ),
            ),
          ),
          const SizedBox(width: 6),
          IconButton(
            tooltip: _recording ? 'Стоп' : 'Голосовое',
            icon: Icon(_recording ? Icons.stop_circle : Icons.mic_none),
            onPressed: _toggleRecord,
          ),
          IconButton(
            tooltip: 'Отправить',
            icon: const Icon(Icons.send),
            onPressed: _sendText,
          ),
        ],
      ),
    );
  }
}
