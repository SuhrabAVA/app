// lib/services/storage_service.dart
import 'dart:io' show File;
import 'package:file_picker/file_picker.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'doc_db.dart';
/// Единый клиент Supabase
final supabase = Supabase.instance.client;
final DocDB _docDb = DocDB();
/// Имя приватного бакета
const String kOrderBucket = 'order-attachments';

/// =======================
/// ВСПОМОГАТЕЛЬНЫЕ ФУНКЦИИ
/// =======================

String _sanitizeFileName(String name) {
  final trimmed = name.trim().isEmpty ? 'document.pdf' : name.trim();
  // только буквы/цифры/подчёркивание/точка/дефис
  return trimmed.replaceAll(RegExp(r'[^\w\.\-]+'), '_');
}

String _buildObjectPath(String orderId, String safeName) {
  final ts = DateTime.now().millisecondsSinceEpoch;
  return 'orders/$orderId/${ts}_$safeName';
}

void _ensureAuthed() {
  if (supabase.auth.currentUser == null) {
    // Бросаем обычное исключение без statusCode — совместимо с любым SDK
    throw Exception('Не авторизован. Войдите в аккаунт перед загрузкой.');
  }
}

/// =======================
///  ОСНОВНЫЕ ОПЕРАЦИИ
/// =======================

/// Выбор и загрузка PDF в Supabase Storage (через FilePicker).
/// Возвращает objectPath (например: "orders/ORD-2025-000123/172..._spec.pdf")
Future<String> uploadOrderPdf({
  required String orderId,
  String? customFileName,
}) async {
  _ensureAuthed();

  final picked = await FilePicker.platform.pickFiles(
    type: FileType.custom,
    allowedExtensions: const ['pdf'],
    withData: true, // важно для Web
  );
  if (picked == null || picked.files.isEmpty) {
    throw Exception('Файл не выбран');
  }
  final file = picked.files.single;
  return uploadPickedOrderPdf(
      orderId: orderId, file: file, customFileName: customFileName);
}

/// Загрузка уже выбранного PDF (PlatformFile) в бакет.
/// Возвращает objectPath.
Future<String> uploadPickedOrderPdf({
  required String orderId,
  required PlatformFile file,
  String? customFileName,
}) async {
  _ensureAuthed();

  final safeName = _sanitizeFileName(
    customFileName?.isNotEmpty == true
        ? customFileName!
        : (file.name.isNotEmpty ? file.name : 'document.pdf'),
  );
  final objectPath = _buildObjectPath(orderId, safeName);

  // собственно загрузка
  try {
    if (file.bytes != null) {
      await supabase.storage.from(kOrderBucket).uploadBinary(
            objectPath,
            file.bytes!,
            fileOptions: const FileOptions(
              upsert: true,
              contentType: 'application/pdf',
            ),
          );
    } else if (file.path != null) {
      await supabase.storage.from(kOrderBucket).upload(
            objectPath,
            File(file.path!),
            fileOptions: const FileOptions(
              upsert: true,
              contentType: 'application/pdf',
            ),
          );
    } else {
      throw Exception('Не удалось прочитать файл');
    }
  } on StorageException catch (e) {
    // пробрасываем SDK-ошибку как есть (403 при RLS, и т.д.)
    rethrow;
  }

  // метаданные (не критично для успешной загрузки)
  try {
    await linkOrderPdf(
      orderId: orderId,
      objectPath: objectPath,
      fileName: safeName,
      sizeBytes: file.size,
    );
  } catch (_) {
    // файл загружен — метаданные можно дозаписать позже
  }

  return objectPath;
}

/// UPSERT метаданных в таблицу order_files по уникальному object_path
Future<Map<String, dynamic>> linkOrderPdf({
  required String orderId,
  required String objectPath,
  required String fileName,
  int? sizeBytes,
}) async {
  _ensureAuthed();

  final userId = supabase.auth.currentUser!.id;
  final row = await _docDb.insert('order_files', {
    'orderId': orderId,
    'objectPath': objectPath,
    'filename': fileName,
    'mimeType': 'application/pdf',
    'sizeBytes': sizeBytes,
    'createdBy': userId,
  });
  final data = Map<String, dynamic>.from(row['data'] ?? {});
  data['id'] = row['id'];
  return data;
}

/// Приватная подписанная ссылка
Future<String> getSignedUrl(String objectPath,
    {int expiresInSeconds = 3600}) async {
  _ensureAuthed();
  final url = await supabase.storage
      .from(kOrderBucket)
      .createSignedUrl(objectPath, expiresInSeconds);
  return url;
}

/// Удаление файла и метаданных по object_path
Future<void> deleteOrderFile(String objectPath) async {
  _ensureAuthed();
  await supabase.storage.from(kOrderBucket).remove([objectPath]);
  final rows = await _docDb.whereEq('order_files', 'objectPath', objectPath);
  for (final r in rows) {
    await _docDb.deleteById(r['id'] as String);
  }
}

/// Список файлов заказа по метаданным
Future<List<Map<String, dynamic>>> listOrderFiles(String orderId) async {
  _ensureAuthed();
  final normalizedOrderId = orderId.trim();
  final matched = <Map<String, dynamic>>[];

  // Текущий формат.
  matched.addAll(await _docDb.whereEq('order_files', 'orderId', normalizedOrderId));

  // Исторические/альтернативные форматы хранения идентификатора заказа.
  matched.addAll(await _docDb.whereEq('order_files', 'order_id', normalizedOrderId));
  matched.addAll(await _docDb.whereEq('order_files', 'orderid', normalizedOrderId));

  // Для совместимости со старыми данными делаем мягкий fallback:
  // иногда id заказа записывался в неожиданный ключ (или с пробелами).
  if (matched.isEmpty) {
    final allOrderFiles = await _docDb.list('order_files');
    matched.addAll(
      allOrderFiles.where((row) {
        final data = Map<String, dynamic>.from(row['data'] ?? {});
        final candidates = <String>[
          (data['orderId'] ?? '').toString().trim(),
          (data['order_id'] ?? '').toString().trim(),
          (data['orderid'] ?? '').toString().trim(),
          (data['orderCode'] ?? '').toString().trim(),
          (data['order_code'] ?? '').toString().trim(),
        ];
        return candidates.contains(normalizedOrderId);
      }),
    );
  }

  // Дедупликация: один и тот же файл может встретиться из разных веток поиска.
  final byIdentity = <String, Map<String, dynamic>>{};
  for (final row in matched) {
    final data = Map<String, dynamic>.from(row['data'] ?? {});
    final id = row['id']?.toString() ?? '';
    final objectPath = (data['objectPath'] ?? data['object_path'] ?? data['path'] ?? '')
        .toString()
        .trim();
    final key = objectPath.isNotEmpty ? objectPath : id;
    if (key.isEmpty) continue;
    data['id'] = id;
    final existingObjectPath = data['objectPath']?.toString().trim() ?? '';
    if (!data.containsKey('objectPath') || existingObjectPath.isEmpty) {
      data['objectPath'] = objectPath;
    }
    final existingFilename = data['filename']?.toString().trim() ?? '';
    if (!data.containsKey('filename') || existingFilename.isEmpty) {
      data['filename'] = (data['fileName'] ?? data['name'] ?? '').toString();
    }
    byIdentity[key] = data;
  }

  final files = byIdentity.values.toList();
  files.sort((a, b) {
    final at = DateTime.tryParse((a['createdAt'] ?? a['created_at'] ?? '').toString());
    final bt = DateTime.tryParse((b['createdAt'] ?? b['created_at'] ?? '').toString());
    if (at != null && bt != null) return bt.compareTo(at);
    if (at != null) return -1;
    if (bt != null) return 1;
    return 0;
  });
  return files;
}
