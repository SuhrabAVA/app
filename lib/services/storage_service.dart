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

// =======================
// PDF ФАЙЛЫ ФОРМ СКЛАДА
// =======================
// Восстановлено из сессии c96025b5 (19.06): PDF формы хранятся в том же
// бакете [kOrderBucket] под префиксом forms/<formId>/..., метаданные — в
// коллекции 'form_files'. Двусторонняя связь форма↔заказ: PDF заказа
// линкуется в форму как source='order' (без физического копирования файла).

const String _kFormFilesCollection = 'form_files';

String _buildFormObjectPath(String formId, String safeName) {
  final ts = DateTime.now().millisecondsSinceEpoch;
  return 'forms/$formId/${ts}_$safeName';
}

/// Загружает один PDF в бакет [kOrderBucket] по пути forms/<formId>/...
/// и сохраняет метаданные с source='form'. Возвращает objectPath.
Future<String> uploadPickedFormPdf({
  required String formId,
  required PlatformFile file,
}) async {
  _ensureAuthed();
  final safeName = _sanitizeFileName(
    file.name.isNotEmpty ? file.name : 'document.pdf',
  );
  final objectPath = _buildFormObjectPath(formId, safeName);
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
  } on StorageException {
    rethrow;
  }
  try {
    await linkFormPdf(
      formId: formId,
      objectPath: objectPath,
      fileName: safeName,
      sizeBytes: file.size,
      source: 'form',
    );
  } catch (_) {
    // метаданные можно дозаписать позже — файл уже загружен
  }
  return objectPath;
}

/// Сохраняет метаданные PDF файла, связанного с формой.
/// [source]: 'form' — файл загружен напрямую к форме;
///           'order' — ссылка на PDF заказа (физически не копируется).
Future<Map<String, dynamic>> linkFormPdf({
  required String formId,
  required String objectPath,
  required String fileName,
  int? sizeBytes,
  String source = 'form',
}) async {
  _ensureAuthed();
  final userId = supabase.auth.currentUser!.id;
  final row = await _docDb.insert(_kFormFilesCollection, {
    'formId': formId,
    'objectPath': objectPath,
    'filename': fileName,
    'mimeType': 'application/pdf',
    'sizeBytes': sizeBytes,
    'source': source,
    'createdBy': userId,
  });
  final data = Map<String, dynamic>.from(row['data'] ?? {});
  data['id'] = row['id'];
  return data;
}

/// Возвращает список PDF файлов формы (source='form' и source='order').
Future<List<Map<String, dynamic>>> listFormFiles(String formId) async {
  _ensureAuthed();
  final rows =
      await _docDb.whereEq(_kFormFilesCollection, 'formId', formId.trim());
  final byIdentity = <String, Map<String, dynamic>>{};
  for (final row in rows) {
    final data = Map<String, dynamic>.from(row['data'] ?? {});
    final id = row['id']?.toString() ?? '';
    final objectPath =
        (data['objectPath'] ?? data['path'] ?? '').toString().trim();
    final key = objectPath.isNotEmpty ? objectPath : id;
    if (key.isEmpty) continue;
    data['id'] = id;
    if ((data['filename'] ?? '').toString().isEmpty) {
      data['filename'] = (data['fileName'] ?? data['name'] ?? '').toString();
    }
    byIdentity[key] = data;
  }
  final files = byIdentity.values.toList();
  files.sort((a, b) {
    final at =
        DateTime.tryParse((a['createdAt'] ?? a['created_at'] ?? '').toString());
    final bt =
        DateTime.tryParse((b['createdAt'] ?? b['created_at'] ?? '').toString());
    if (at != null && bt != null) return bt.compareTo(at);
    if (at != null) return -1;
    if (bt != null) return 1;
    return 0;
  });
  return files;
}

/// Удаляет PDF файл формы.
/// source='form' → удаляет из Storage и из documents.
/// source='order' → удаляет только запись (объект принадлежит заказу).
Future<void> deleteFormFile(Map<String, dynamic> fileRow) async {
  _ensureAuthed();
  final source = (fileRow['source'] ?? 'form').toString();
  final objectPath =
      (fileRow['objectPath'] ?? fileRow['path'] ?? '').toString();
  final id = fileRow['id']?.toString() ?? '';
  if (source == 'form' && objectPath.isNotEmpty) {
    try {
      await supabase.storage.from(kOrderBucket).remove([objectPath]);
    } catch (_) {}
  }
  if (id.isNotEmpty) {
    await _docDb.deleteById(id);
  }
}

/// Ищет id формы по реквизитам, привязанным к заказу.
/// Возвращает null если форма не найдена.
Future<String?> findFormIdByOrderFormRef({
  String? formCode,
  String? formSeries,
  int? formNo,
}) async {
  if (formCode != null && formCode.trim().isNotEmpty) {
    final res = await supabase
        .from('forms')
        .select('id')
        .eq('code', formCode.trim())
        .maybeSingle();
    final id = res?['id']?.toString();
    if (id != null && id.isNotEmpty) return id;
  }
  if (formSeries != null && formSeries.trim().isNotEmpty && formNo != null) {
    final res = await supabase
        .from('forms')
        .select('id')
        .eq('series', formSeries.trim())
        .eq('number', formNo)
        .maybeSingle();
    final id = res?['id']?.toString();
    if (id != null && id.isNotEmpty) return id;
  }
  return null;
}