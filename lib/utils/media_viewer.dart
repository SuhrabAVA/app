import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:pdfx/pdfx.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:video_player/video_player.dart';

/// Opens a fullscreen page with an interactive image preview.
Future<void> showImagePreview(
  BuildContext context, {
  Uint8List? bytes,
  String? imageUrl,
  String? title,
}) async {
  if ((bytes == null || bytes.isEmpty) && (imageUrl == null || imageUrl.isEmpty)) {
    return;
  }

  await Navigator.of(context).push(
    MaterialPageRoute(
      builder: (_) => _ImagePreviewPage(
        bytes: bytes,
        imageUrl: imageUrl,
        title: title,
      ),
      fullscreenDialog: true,
    ),
  );
}

/// Opens a fullscreen viewer for media referenced by [url].
///
/// Supports images, videos and PDF documents. Unsupported types are
/// delegated to the platform using [url_launcher].
Future<void> showMediaPreview(
  BuildContext context, {
  required String url,
  String? mime,
  String? title,
}) async {
  if (url.isEmpty) return;

  final mimeLower = mime?.toLowerCase();
  final lowerUrl = url.toLowerCase();

  if (mimeLower != null && mimeLower.startsWith('image/')) {
    await showImagePreview(context, imageUrl: url, title: title);
    return;
  }

  if ((mimeLower != null && mimeLower.startsWith('video/')) ||
      lowerUrl.endsWith('.mp4') ||
      lowerUrl.endsWith('.mov') ||
      lowerUrl.endsWith('.webm')) {
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => _VideoPreviewPage(url: url, title: title),
        fullscreenDialog: true,
      ),
    );
    return;
  }

  if (mimeLower == 'application/pdf' || lowerUrl.endsWith('.pdf')) {
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => _PdfPreviewPage(url: url, title: title),
        fullscreenDialog: true,
      ),
    );
    return;
  }

  final uri = Uri.tryParse(url);
  if (uri != null) {
    await launchUrl(uri, mode: LaunchMode.externalApplication);
  }
}

class _ImagePreviewPage extends StatelessWidget {
  final Uint8List? bytes;
  final String? imageUrl;
  final String? title;

  const _ImagePreviewPage({
    this.bytes,
    this.imageUrl,
    this.title,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    Widget? child;
    if (bytes != null && bytes!.isNotEmpty) {
      child = Image.memory(bytes!, fit: BoxFit.contain);
    } else if (imageUrl != null && imageUrl!.isNotEmpty) {
      child = Image.network(
        imageUrl!,
        fit: BoxFit.contain,
        loadingBuilder: (context, widget, event) {
          if (event == null) return widget;
          return const Center(child: CircularProgressIndicator());
        },
        errorBuilder: (_, __, ___) => const Center(
          child: Icon(Icons.broken_image, size: 64, color: Colors.white70),
        ),
      );
    }

    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        iconTheme: theme.iconTheme.copyWith(color: Colors.white),
        title: Text(title ?? 'Просмотр', style: const TextStyle(color: Colors.white)),
      ),
      body: child == null
          ? const Center(child: Icon(Icons.image_not_supported, color: Colors.white54, size: 56))
          : Center(
              child: InteractiveViewer(
                maxScale: 5,
                child: child,
              ),
            ),
    );
  }
}

class _VideoPreviewPage extends StatefulWidget {
  final String url;
  final String? title;

  const _VideoPreviewPage({required this.url, this.title});

  @override
  State<_VideoPreviewPage> createState() => _VideoPreviewPageState();
}

class _VideoPreviewPageState extends State<_VideoPreviewPage> {
  VideoPlayerController? _controller;
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    VideoPlayerController? controller;
    try {
      controller = VideoPlayerController.networkUrl(Uri.parse(widget.url));
      await controller.initialize();
      controller.setLooping(true);
      if (!mounted) {
        await controller.dispose();
        return;
      }
      setState(() {
        _controller = controller;
        _loading = false;
      });
      await controller.play();
    } catch (e) {
      if (controller != null) {
        await controller.dispose();
      }
      if (!mounted) return;
      setState(() {
        _error = e.toString();
        _loading = false;
      });
    }
  }

  @override
  void dispose() {
    _controller?.dispose();
    super.dispose();
  }

  void _togglePlay() {
    final controller = _controller;
    if (controller == null) return;
    if (!controller.value.isInitialized) return;
    setState(() {
      if (controller.value.isPlaying) {
        controller.pause();
      } else {
        controller.play();
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        iconTheme: theme.iconTheme.copyWith(color: Colors.white),
        title: Text(widget.title ?? 'Видео', style: const TextStyle(color: Colors.white)),
      ),
      body: Center(
        child: _loading
            ? const CircularProgressIndicator()
            : _error != null
                ? Padding(
                    padding: const EdgeInsets.all(24.0),
                    child: Text(
                      'Не удалось воспроизвести видео:\n$_error',
                      style: const TextStyle(color: Colors.white70),
                      textAlign: TextAlign.center,
                    ),
                  )
                : _controller == null
                    ? const SizedBox.shrink()
                    : GestureDetector(
                        onTap: _togglePlay,
                        child: Stack(
                          alignment: Alignment.center,
                          children: [
                            AspectRatio(
                              aspectRatio: _controller!.value.aspectRatio == 0
                                  ? 16 / 9
                                  : _controller!.value.aspectRatio,
                              child: VideoPlayer(_controller!),
                            ),
                            if (!_controller!.value.isPlaying)
                              const Icon(Icons.play_arrow, size: 72, color: Colors.white70),
                          ],
                        ),
                      ),
      ),
    );
  }
}

class _PdfPreviewPage extends StatefulWidget {
  final String url;
  final String? title;

  const _PdfPreviewPage({required this.url, this.title});

  @override
  State<_PdfPreviewPage> createState() => _PdfPreviewPageState();
}

class _PdfPreviewPageState extends State<_PdfPreviewPage> {
  PdfControllerPinch? _controller;
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final response = await http.get(Uri.parse(widget.url));
      if (response.statusCode != 200) {
        throw Exception('HTTP ${response.statusCode}');
      }
      final documentFuture = PdfDocument.openData(response.bodyBytes);
      final document = await documentFuture;
      if (!mounted) {
        await document.close();
        return;
      }
      setState(() {
        _controller = PdfControllerPinch(document: documentFuture);
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
        _loading = false;
      });
    }
  }

  @override
  void dispose() {
    _controller?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        iconTheme: theme.iconTheme.copyWith(color: Colors.white),
        title: Text(widget.title ?? 'Документ', style: const TextStyle(color: Colors.white)),
      ),
      body: Center(
        child: _loading
            ? const CircularProgressIndicator()
            : _error != null
                ? Padding(
                    padding: const EdgeInsets.all(24.0),
                    child: Text(
                      'Не удалось открыть PDF:\n$_error',
                      style: const TextStyle(color: Colors.white70),
                      textAlign: TextAlign.center,
                    ),
                  )
                : _controller == null
                    ? const SizedBox.shrink()
                    : PdfViewPinch(
                        controller: _controller!,
                        builders: PdfViewPinchBuilders(
                          options: PdfViewOptions(),
                          documentLoaderBuilder: (_) => const Center(child: CircularProgressIndicator()),
                          pageLoaderBuilder: (_) => const Center(child: CircularProgressIndicator()),
                          errorBuilder: (_, error) => Center(
                            child: Text(
                              'Ошибка загрузки страницы: $error',
                              style: const TextStyle(color: Colors.white70),
                              textAlign: TextAlign.center,
                            ),
                          ),
                        ),
                      ),
      ),
    );
  }
}
