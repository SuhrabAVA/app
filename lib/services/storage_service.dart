// lib/services/storage_service.dart
import 'dart:io' show File;
import 'package:file_picker/file_picker.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// Единый клиент Supabase
final supabase = Supabase.instance.client;

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
  final rows = await supabase
      .from('order_files')
      .upsert({
        'order_id': orderId,
        'object_path': objectPath, // должен быть UNIQUE
        'filename': fileName,
        'mime_type': 'application/pdf',
        'size_bytes': sizeBytes,
        'created_by': userId,
      }, onConflict: 'object_path')
      .select()
      .single();

  return (rows as Map<String, dynamic>);
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
  await supabase.from('order_files').delete().eq('object_path', objectPath);
}

/// Список файлов заказа по метаданным
Future<List<Map<String, dynamic>>> listOrderFiles(String orderId) async {
  _ensureAuthed();
  final res = await supabase
      .from('order_files')
      .select()
      .eq('order_id', orderId)
      .order('created_at', ascending: false);
  return (res as List).cast<Map<String, dynamic>>();
}
