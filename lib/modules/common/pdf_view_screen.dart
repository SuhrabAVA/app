// lib/modules/common/pdf_view_screen.dart
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart'
    show defaultTargetPlatform, TargetPlatform;
import 'dart:typed_data';
import 'package:http/http.dart' as http;
import 'package:pdfx/pdfx.dart';

class PdfViewScreen extends StatefulWidget {
  final String? url;
  final Uint8List? bytes;
  final String title;
  const PdfViewScreen({
    super.key,
    this.url,
    this.bytes,
    required this.title,
  }) : assert(url != null || bytes != null);

  @override
  State<PdfViewScreen> createState() => _PdfViewScreenState();
}

class _PdfViewScreenState extends State<PdfViewScreen> {
  PdfControllerPinch? _pinchController;
  PdfController? _plainController;
  String? _error;
  int _pagesCount = 0;
  int _currentPage = 1;

  bool get _usePlainOnThisPlatform =>
      defaultTargetPlatform == TargetPlatform.windows ||
      defaultTargetPlatform == TargetPlatform.linux ||
      defaultTargetPlatform == TargetPlatform.macOS;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final Future<PdfDocument> doc;
      if (widget.bytes != null) {
        doc = PdfDocument.openData(widget.bytes!);
      } else {
        final res = await http.get(Uri.parse(widget.url!));
        if (res.statusCode != 200) {
          setState(() => _error = 'HTTP ${res.statusCode}');
          return;
        }
        doc = PdfDocument.openData(res.bodyBytes);
      }
      setState(() {
        if (_usePlainOnThisPlatform) {
          _plainController = PdfController(
            document: doc,
            initialPage: _currentPage,
          );
        } else {
          _pinchController = PdfControllerPinch(
            document: doc,
            initialPage: _currentPage,
          );
        }
      });
    } catch (e) {
      setState(() => _error = e.toString());
    }
  }

  @override
  void dispose() {
    _pinchController?.dispose();
    _plainController?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final controller =
        _usePlainOnThisPlatform ? _plainController : _pinchController;
    final viewer = _usePlainOnThisPlatform && controller != null
        ? PdfView(
            controller: controller as PdfController,
            onPageChanged: (page) {
              if (page == null) return;
              if (!mounted) return;
              setState(() => _currentPage = page);
            },
            onDocumentLoaded: (document) {
              if (!mounted) return;
              setState(() => _pagesCount = document.pagesCount);
            },
          )
        : (!_usePlainOnThisPlatform && controller != null
            ? PdfViewPinch(
                controller: controller as PdfControllerPinch,
                onPageChanged: (page) {
                  if (page == null) return;
                  if (!mounted) return;
                  setState(() => _currentPage = page);
                },
                onDocumentLoaded: (document) {
                  if (!mounted) return;
                  setState(() => _pagesCount = document.pagesCount);
                },
              )
            : null);

    return Scaffold(
      appBar: AppBar(title: Text(widget.title)),
      body: viewer == null
          ? (_error != null
              ? Center(child: Text('Не удалось открыть PDF: $_error'))
              : const Center(child: CircularProgressIndicator()))
          : Column(
              children: [
                Expanded(child: viewer),
                if (_pagesCount > 1)
                  SafeArea(
                    top: false,
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
                      child: Row(
                        children: [
                          IconButton(
                            tooltip: 'Предыдущая страница',
                            onPressed: _currentPage > 1
                                ? () => _goToPage(_currentPage - 1)
                                : null,
                            icon: const Icon(Icons.chevron_left),
                          ),
                          Expanded(
                            child: Center(
                              child: Text('Страница $_currentPage из $_pagesCount'),
                            ),
                          ),
                          IconButton(
                            tooltip: 'Следующая страница',
                            onPressed: _currentPage < _pagesCount
                                ? () => _goToPage(_currentPage + 1)
                                : null,
                            icon: const Icon(Icons.chevron_right),
                          ),
                        ],
                      ),
                    ),
                  ),
              ],
            ),
    );
  }

  Future<void> _goToPage(int page) async {
    final target = page.clamp(1, _pagesCount == 0 ? 1 : _pagesCount);
    try {
      if (_usePlainOnThisPlatform && _plainController != null) {
        await _plainController!.animateToPage(
          target,
          duration: const Duration(milliseconds: 180),
          curve: Curves.easeOut,
        );
      } else if (_pinchController != null) {
        await _pinchController!.animateToPage(
          pageNumber: target,
          duration: const Duration(milliseconds: 180),
          curve: Curves.easeOut,
        );
      }
    } catch (_) {
      // no-op
    }
  }
}
