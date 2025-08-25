// lib/services/storage_service.dart
import 'dart:io';
import 'package:file_picker/file_picker.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// Один общий клиент Supabase
final supabase = Supabase.instance.client;

/// Имя бакета из SQL-скрипта
const String kOrderBucket = 'order-attachments';

/// Выбор и загрузка PDF в Supabase Storage.
/// Возвращает objectPath (путь в бакете), например:
/// "orders/<orderId>/1724567890123_invoice.pdf"
Future<String> uploadOrderPdf({
  required String orderId, // <-- ВАЖНО: тот же тип, что и orders.id (у нас text/String)
  String? customFileName,  // можно передать своё имя файла (безопаснее без пробелов)
}) async {
  // Выбор PDF
  final result = await FilePicker.platform.pickFiles(
    type: FileType.custom,
    allowedExtensions: ['pdf'],
    withData: true, // для Web и на случай, если путь не доступен
  );
  if (result == null || result.files.isEmpty) {
    throw Exception('Файл не выбран');
  }

  final file = result.files.single;

  // Имя файла
  final fileName = customFileName?.trim().isNotEmpty == true
      ? customFileName!.trim()
      : (file.name.isNotEmpty ? file.name : 'document.pdf');

  // Нормализуем имя (убираем потенциально проблемные символы)
  final safeName = fileName.replaceAll(RegExp(r'[^\w\.\-]+'), '_');

  // Куда положим в бакете
  final objectPath =
      'orders/$orderId/${DateTime.now().millisecondsSinceEpoch}_$safeName';

  // Собственно загрузка
  // ВАЖНО: всегда указываем contentType = application/pdf
  if (file.bytes != null) {
    // Bytes-путь (Web / иногда Desktop)
    await supabase.storage.from(kOrderBucket).uploadBinary(
          objectPath,
          file.bytes!,
          fileOptions: const FileOptions(
            upsert: true,
            contentType: 'application/pdf',
          ),
        );
  } else if (file.path != null) {
    // Файловый путь (Windows/Mac/Linux/Android)
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

  // Попробуем записать метаданные (не обязательно, но удобно)
  try {
    await linkOrderPdf(
      orderId: orderId,
      objectPath: objectPath,
      fileName: safeName,
      sizeBytes: file.size,
    );
  } catch (e) {
    // Не падаем из-за метаданных — файл уже загружен
    // Можешь залогировать где-то у себя
  }

  return objectPath;
}

/// Загрузка уже выбранного PDF-файла в Supabase Storage.
/// Принимает [PlatformFile], полученный, например, через FilePicker.
/// Возвращает [objectPath] загруженного файла.
Future<String> uploadPickedOrderPdf({
  required String orderId,
  required PlatformFile file,
  String? customFileName,
}) async {
  final fileName = customFileName?.trim().isNotEmpty == true
      ? customFileName!.trim()
      : (file.name.isNotEmpty ? file.name : 'document.pdf');

  final safeName = fileName.replaceAll(RegExp(r'[^\w\.\-]+'), '_');
  final objectPath =
      'orders/$orderId/${DateTime.now().millisecondsSinceEpoch}_$safeName';

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

  try {
    await linkOrderPdf(
      orderId: orderId,
      objectPath: objectPath,
      fileName: safeName,
      sizeBytes: file.size,
    );
  } catch (_) {
    // файл загружен, метаданные не критичны
  }

  return objectPath;
}

/// Запись метаданных в таблицу order_files (создана SQL-скриптом)
Future<void> linkOrderPdf({
  required String orderId,
  required String objectPath,
  required String fileName,
  int? sizeBytes,
}) async {
  final userId = supabase.auth.currentUser?.id;
  await supabase.from('order_files').insert({
    'order_id': orderId,
    'object_path': objectPath,
    'filename': fileName,
    'mime_type': 'application/pdf',
    'size_bytes': sizeBytes,
    'created_by': userId,
  });
}

/// Получить подписанную ссылку (если бакет приватный — мы его так и сделали)
/// [expiresInSeconds] — время жизни ссылки, по умолчанию 1 час.
Future<String> getSignedUrl(String objectPath, {int expiresInSeconds = 3600}) async {
  final url = await supabase.storage
      .from(kOrderBucket)
      .createSignedUrl(objectPath, expiresInSeconds);
  return url;
}

/// Удалить файл из бакета
Future<void> deleteOrderFile(String objectPath) async {
  await supabase.storage.from(kOrderBucket).remove([objectPath]);

  // По желанию удалим и метаданные
  await supabase.from('order_files').delete().eq('object_path', objectPath);
}

/// Получить список файлов заказа из таблицы метаданных
Future<List<Map<String, dynamic>>> listOrderFiles(String orderId) async {
  final res = await supabase
      .from('order_files')
      .select()
      .eq('order_id', orderId)
      .order('created_at', ascending: false);
  // Возвращаем как список map
  return (res as List).cast<Map<String, dynamic>>();
}
