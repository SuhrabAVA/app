// lib/modules/common/pdf_view_screen.dart
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/foundation.dart'
    show defaultTargetPlatform, TargetPlatform;
import 'package:flutter/material.dart';
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

  /// Размер области просмотра. Меняется при повороте планшета — тогда лист
  /// нужно вписать заново.
  Size? _viewSize;

  bool get _usePlainOnThisPlatform =>
      defaultTargetPlatform == TargetPlatform.windows ||
      defaultTargetPlatform == TargetPlatform.linux ||
      defaultTargetPlatform == TargetPlatform.macOS;

  /// Насколько мелко разрешено уводить лист.
  ///
  /// Единица масштаба у pdfx — «лист по ширине экрана». Вертикальный лист на
  /// горизонтальном экране при таком масштабе не помещается по высоте, и
  /// прежний нижний предел 1.0 не давал его уменьшить: нижний край уходил за
  /// экран навсегда.
  static const double _minPinchScale = 0.1;
  static const double _maxPinchScale = 12;

  @override
  void initState() {
    super.initState();
    _load();
  }

  /// Растр страницы для простого просмотрщика (десктоп).
  ///
  /// По умолчанию pdfx рендерит в JPEG при двукратном увеличении. На бланках
  /// заказа это заметно: JPEG размывает тонкие линии и оставляет ореолы вокруг
  /// цифр. PNG сжимает без потерь, а тройной масштаб держит текст резким при
  /// увеличении.
  static Future<PdfPageImage?> _renderSharp(PdfPage page) => page.render(
        width: page.width * 3,
        height: page.height * 3,
        format: PdfPageImageFormat.png,
        backgroundColor: '#ffffff',
      );

  /// Страница для десктопного просмотрщика с расширенным диапазоном масштаба.
  ///
  /// `contained` — это лист, целиком вписанный в экран при любой ориентации.
  /// Разрешаем уходить и ниже него, и заметно выше: у pdfx верхний предел был
  /// всего трёхкратным, мелкий шрифт на бланке так не рассмотреть.
  static PhotoViewGalleryPageOptions _pageBuilder(
    BuildContext context,
    Future<PdfPageImage> pageImage,
    int index,
    PdfDocument document,
  ) =>
      PhotoViewGalleryPageOptions(
        imageProvider: PdfPageImageProvider(pageImage, index, document.id),
        minScale: PhotoViewComputedScale.contained * 0.4,
        maxScale: PhotoViewComputedScale.contained * 8,
        initialScale: PhotoViewComputedScale.contained * 1.0,
        // Фильтрация при увеличении: без неё растр «мылится» лесенкой.
        filterQuality: FilterQuality.high,
        heroAttributes: PhotoViewHeroAttributes(tag: '${document.id}-$index'),
      );

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

  /// Вписать текущую страницу целиком — и по ширине, и по высоте.
  ///
  /// Считаем сами, а не через `calculatePageFitMatrix`: тот вписывает только
  /// по ширине, из-за чего горизонтальный лист на вертикальном экране (и
  /// наоборот) вылезал за нижнюю границу.
  void _fitPage() {
    final controller = _pinchController;
    final size = _viewSize;
    if (controller == null || size == null) return;
    if (size.width <= 0 || size.height <= 0) return;

    Rect? rect;
    try {
      rect = controller.getPageRect(_currentPage);
    } catch (_) {
      // Разметка ещё не посчитана — вписывать нечего.
      return;
    }
    if (rect == null || rect.width <= 0 || rect.height <= 0) return;

    // Небольшой воздух по краям, чтобы лист не упирался в рамку экрана.
    const gap = 12.0;
    final scale = math.min(
      (size.width - gap) / rect.width,
      (size.height - gap) / rect.height,
    );
    if (!scale.isFinite || scale <= 0) return;

    // Матрица pdfx: экран = перенос + масштаб × документ. Значит центр листа
    // совмещаем с центром области просмотра.
    controller.value = Matrix4.identity()
      ..translateByDouble(
        size.width / 2 - scale * rect.center.dx,
        size.height / 2 - scale * rect.center.dy,
        0,
        1,
      )
      ..scaleByDouble(scale, scale, 1, 1);
  }

  void _scheduleFitPage() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _fitPage();
    });
  }

  /// Приблизить/отдалить кнопкой — на планшете щипком попадают не всегда,
  /// а в перчатках тем более.
  void _zoomBy(double factor) {
    final controller = _pinchController;
    final size = _viewSize;
    if (controller == null || size == null) return;
    final current = controller.value.getMaxScaleOnAxis();
    final next = (current * factor).clamp(_minPinchScale, _maxPinchScale);
    if (next == current) return;

    // Масштабируем вокруг центра экрана, чтобы точка внимания не убегала.
    final center = Offset(size.width / 2, size.height / 2);
    final matrix = controller.value.clone();
    final tx = matrix.row0[3];
    final ty = matrix.row1[3];
    final docCenter = Offset(
      (center.dx - tx) / current,
      (center.dy - ty) / current,
    );
    controller.value = Matrix4.identity()
      ..translateByDouble(
        center.dx - next * docCenter.dx,
        center.dy - next * docCenter.dy,
        0,
        1,
      )
      ..scaleByDouble(next, next, 1, 1);
  }

  @override
  Widget build(BuildContext context) {
    final controller =
        _usePlainOnThisPlatform ? _plainController : _pinchController;
    final viewer = _usePlainOnThisPlatform && controller != null
        ? PdfView(
            controller: controller as PdfController,
            renderer: _renderSharp,
            builders: const PdfViewBuilders<DefaultBuilderOptions>(
              options: DefaultBuilderOptions(),
              pageBuilder: _pageBuilder,
            ),
            onPageChanged: (page) {
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
                minScale: _minPinchScale,
                maxScale: _maxPinchScale,
                onPageChanged: (page) {
                  if (!mounted) return;
                  setState(() => _currentPage = page);
                },
                onDocumentLoaded: (document) {
                  if (!mounted) return;
                  setState(() => _pagesCount = document.pagesCount);
                  // Первый показ — лист целиком, независимо от того, как
                  // держат планшет.
                  _scheduleFitPage();
                },
              )
            : null);

    return Scaffold(
      appBar: AppBar(
        title: Text(widget.title),
        actions: _usePlainOnThisPlatform || controller == null
            ? null
            : [
                IconButton(
                  tooltip: 'Отдалить',
                  onPressed: () => _zoomBy(1 / 1.4),
                  icon: const Icon(Icons.zoom_out),
                ),
                IconButton(
                  tooltip: 'Вписать страницу целиком',
                  onPressed: _fitPage,
                  icon: const Icon(Icons.fit_screen),
                ),
                IconButton(
                  tooltip: 'Приблизить',
                  onPressed: () => _zoomBy(1.4),
                  icon: const Icon(Icons.zoom_in),
                ),
              ],
      ),
      body: viewer == null
          ? (_error != null
              ? Center(child: Text('Не удалось открыть PDF: $_error'))
              : const Center(child: CircularProgressIndicator()))
          : Column(
              children: [
                Expanded(
                  child: LayoutBuilder(
                    builder: (context, constraints) {
                      final size = constraints.biggest;
                      if (_viewSize != size) {
                        final hadSize = _viewSize != null;
                        _viewSize = size;
                        // Планшет повернули — вписываем лист заново.
                        if (hadSize) _scheduleFitPage();
                      }
                      return viewer;
                    },
                  ),
                ),
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
                              child:
                                  Text('Страница $_currentPage из $_pagesCount'),
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
        // Соседняя страница тоже должна открыться целиком, а не по ширине.
        _scheduleFitPage();
      }
    } catch (_) {
      // no-op
    }
  }
}
