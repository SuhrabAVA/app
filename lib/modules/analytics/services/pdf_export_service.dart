import 'dart:convert';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';

/// Сервис «экспорта в PDF».
///
/// В pubspec проекта НЕТ полноценного пакета для печати PDF,
/// поэтому реализация выполняет два шага:
///
///   1. Снимает изображение текущей области аналитики (RepaintBoundary)
///      и копирует его как PNG в системный буфер обмена (data:image/png).
///   2. Показывает пользователю подсказку: для сохранения в PDF удобнее
///      всего использовать системную печать (Ctrl+P / Cmd+P).
///
/// Когда в проект будет добавлен пакет `printing` или `pdf` — здесь
/// можно расширить функциональность без изменения остальной аналитики.
class PdfExportService {
  PdfExportService();

  Future<bool> printArea({
    required BuildContext context,
    required GlobalKey boundaryKey,
    String? documentTitle,
  }) async {
    try {
      final boundary = boundaryKey.currentContext?.findRenderObject();
      if (boundary is! RenderRepaintBoundary) {
        _showHint(context);
        return false;
      }
      final image = await boundary.toImage(pixelRatio: 2.0);
      final byteData = await image.toByteData(format: ui.ImageByteFormat.png);
      if (byteData == null) {
        _showHint(context);
        return false;
      }
      final bytes = byteData.buffer.asUint8List();
      await Clipboard.setData(
        ClipboardData(text: 'data:image/png;base64,${base64Encode(bytes)}'),
      );
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              'Снимок «${documentTitle ?? 'аналитика'}» скопирован в буфер обмена. '
              'Чтобы сохранить PDF, используйте системную печать (Ctrl+P).',
            ),
            duration: const Duration(seconds: 5),
          ),
        );
      }
      return true;
    } catch (_) {
      _showHint(context);
      return false;
    }
  }

  void _showHint(BuildContext context) {
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text(
          'Чтобы получить PDF, используйте системную печать (Ctrl+P).',
        ),
      ),
    );
  }
}
