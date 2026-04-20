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
          _plainController = PdfController(document: doc);
        } else {
          _pinchController = PdfControllerPinch(document: doc);
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
        ? PdfView(controller: controller as PdfController)
        : (!_usePlainOnThisPlatform && controller != null
            ? PdfViewPinch(controller: controller as PdfControllerPinch)
            : null);

    return Scaffold(
      appBar: AppBar(title: Text(widget.title)),
      body: viewer ??
          (_error != null
              ? Center(child: Text('Не удалось открыть PDF: $_error'))
              : const Center(child: CircularProgressIndicator())),
    );
  }
}
