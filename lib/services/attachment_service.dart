import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart'
    show TargetPlatform, defaultTargetPlatform, kIsWeb;
import 'package:image_picker/image_picker.dart';
import 'package:mime/mime.dart';
import 'package:path/path.dart' as p;
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:uuid/uuid.dart';

import '../modules/tasks/task_model.dart';
import '../modules/orders/order_comment_attachment.dart';

const String kTaskCommentAttachmentsBucket = 'task-comment-attachments';
const String kTaskCommentAttachmentsTable = 'task_comment_attachments';
const String kOrderCommentAttachmentsBucket = 'order-comment-attachments';
const String kOrderCommentAttachmentsTable = 'order_comment_attachments';

class AttachmentDraft {
  final Uint8List bytes;
  final String fileName;
  final String mimeType;

  const AttachmentDraft({
    required this.bytes,
    required this.fileName,
    required this.mimeType,
  });

  int get sizeBytes => bytes.lengthInBytes;
}

class AttachmentService {
  AttachmentService({SupabaseClient? supabase})
      : _supabase = supabase ?? Supabase.instance.client;

  final SupabaseClient _supabase;
  final Uuid _uuid = const Uuid();


  static bool get shouldUseFilePickerForMedia =>
      kIsWeb ||
      defaultTargetPlatform == TargetPlatform.windows ||
      defaultTargetPlatform == TargetPlatform.macOS ||
      defaultTargetPlatform == TargetPlatform.linux;

  List<int>? _mimeHeader(Uint8List bytes) {
    if (bytes.isEmpty) return null;
    return bytes.take(bytes.length < 16 ? bytes.length : 16).toList();
  }

  Future<Uint8List> _readPickedFileBytes(PlatformFile file) async {
    if (file.bytes != null) return file.bytes!;
    if (file.readStream != null) {
      final builder = BytesBuilder(copy: false);
      await for (final chunk in file.readStream!) {
        builder.add(chunk);
      }
      return builder.takeBytes();
    }
    final path = file.path;
    if (path == null) throw Exception('Не удалось прочитать файл');
    return File(path).readAsBytes();
  }

  Future<AttachmentDraft?> pickAttachmentDraft({required String source}) async {
    if (shouldUseFilePickerForMedia && source != 'file') {
      return pickAttachmentDraft(source: 'file');
    }

    if (source == 'camera') {
      final image = await ImagePicker().pickImage(
        source: ImageSource.camera,
        imageQuality: 85,
      );
      if (image == null) return null;
      final bytes = await image.readAsBytes();
      return AttachmentDraft(
        bytes: bytes,
        fileName: image.name.isNotEmpty ? image.name : p.basename(image.path),
        mimeType: lookupMimeType(image.path, headerBytes: _mimeHeader(bytes)) ??
            'image/jpeg',
      );
    }

    if (source == 'photo') {
      final image = await ImagePicker().pickImage(
        source: ImageSource.gallery,
        imageQuality: 85,
      );
      if (image == null) return null;
      final bytes = await image.readAsBytes();
      return AttachmentDraft(
        bytes: bytes,
        fileName: image.name.isNotEmpty ? image.name : p.basename(image.path),
        mimeType: lookupMimeType(image.path, headerBytes: _mimeHeader(bytes)) ??
            'image/jpeg',
      );
    }

    if (source == 'video') {
      final video = await ImagePicker().pickVideo(source: ImageSource.gallery);
      if (video == null) return null;
      final bytes = await video.readAsBytes();
      return AttachmentDraft(
        bytes: bytes,
        fileName: video.name.isNotEmpty ? video.name : p.basename(video.path),
        mimeType: lookupMimeType(video.path, headerBytes: _mimeHeader(bytes)) ??
            'video/mp4',
      );
    }

    final result = await FilePicker.platform.pickFiles(withReadStream: true);
    if (result == null || result.files.isEmpty) return null;
    final file = result.files.first;
    final bytes = await _readPickedFileBytes(file);
    return AttachmentDraft(
      bytes: bytes,
      fileName: file.name,
      mimeType: lookupMimeType(file.path ?? file.name,
              headerBytes: _mimeHeader(bytes)) ??
          'application/octet-stream',
    );
  }

  String detectFileType(String mimeType, {String? fileName}) {
    final normalized = mimeType.toLowerCase().trim();
    if (normalized.startsWith('image/')) return 'image';
    if (normalized.startsWith('video/')) return 'video';
    if (normalized.startsWith('audio/')) return 'audio';
    final ext = p.extension(fileName ?? '').toLowerCase();
    if (ext == '.jpg' || ext == '.jpeg' || ext == '.png' || ext == '.webp') {
      return 'image';
    }
    if (ext == '.mp4' || ext == '.mov' || ext == '.webm') return 'video';
    return 'file';
  }

  String detectMimeType(String fileName, {List<int>? headerBytes}) {
    return lookupMimeType(fileName, headerBytes: headerBytes) ??
        'application/octet-stream';
  }

  Future<TaskCommentAttachment> uploadTaskCommentAttachment({
    required AttachmentDraft draft,
    required String taskId,
    required String orderId,
    required String stageId,
    required String commentId,
    required String userId,
    Duration signedUrlTtl = const Duration(hours: 12),
  }) async {
    final attachmentId = _uuid.v4();
    final safeName = _sanitizeFileName(draft.fileName);
    final ext = p.extension(safeName);
    final storagePath = [
      orderId,
      taskId,
      commentId,
      ext.isEmpty ? attachmentId : '$attachmentId$ext',
    ].join('/');

    await _uploadBinary(
      bucket: kTaskCommentAttachmentsBucket,
      storagePath: storagePath,
      bytes: draft.bytes,
      mimeType: draft.mimeType,
    );

    try {
      final now = DateTime.now().toUtc();
      final row = await _supabase
          .from(kTaskCommentAttachmentsTable)
          .insert({
            'id': attachmentId,
            'task_id': taskId,
            'order_id': orderId,
            'stage_id': stageId,
            'comment_id': commentId,
            'user_id': userId,
            'file_type': detectFileType(draft.mimeType, fileName: safeName),
            'file_name': safeName,
            'storage_path': storagePath,
            'file_url': null,
            'mime_type': draft.mimeType,
            'size_bytes': draft.sizeBytes,
            'created_at': now.toIso8601String(),
          })
          .select()
          .single();
      return _withSignedUrl(
        TaskCommentAttachment.fromMap(Map<String, dynamic>.from(row)),
        bucket: kTaskCommentAttachmentsBucket,
        signedUrlTtl: signedUrlTtl,
      );
    } catch (_) {
      await removeStorageObject(storagePath);
      rethrow;
    }
  }

  Future<OrderCommentAttachment> uploadOrderCommentAttachment({
    required AttachmentDraft draft,
    required String orderId,
    required String commentId,
    required String userId,
    String attachmentType = 'file',
    Duration signedUrlTtl = const Duration(hours: 12),
  }) async {
    final attachmentId = _uuid.v4();
    final safeName = _sanitizeFileName(draft.fileName);
    final ext = p.extension(safeName);
    final storagePath = [
      orderId,
      commentId,
      ext.isEmpty ? attachmentId : '$attachmentId$ext',
    ].join('/');

    await _uploadBinary(
      bucket: kOrderCommentAttachmentsBucket,
      storagePath: storagePath,
      bytes: draft.bytes,
      mimeType: draft.mimeType,
    );

    try {
      final now = DateTime.now().toUtc();
      final row = await _supabase.from(kOrderCommentAttachmentsTable).insert({
        'id': attachmentId,
        'order_id': orderId,
        'comment_id': commentId,
        'file_name': safeName,
        'storage_path': storagePath,
        'mime_type': draft.mimeType,
        'size_bytes': draft.sizeBytes,
        'attachment_type': attachmentType,
        'uploaded_by': userId,
        'created_at': now.toIso8601String(),
      }).select().single();
      return _withSignedUrl(
        OrderCommentAttachment.fromMap(Map<String, dynamic>.from(row)),
        bucket: kOrderCommentAttachmentsBucket,
        signedUrlTtl: signedUrlTtl,
      );
    } catch (_) {
      await removeStorageObject(storagePath, bucket: kOrderCommentAttachmentsBucket);
      rethrow;
    }
  }

  Future<List<TaskCommentAttachment>> loadTaskCommentAttachments({
    String? taskId,
    String? orderId,
    String? stageId,
    Iterable<String>? commentIds,
    Duration signedUrlTtl = const Duration(hours: 12),
  }) async {
    dynamic query = _supabase.from(kTaskCommentAttachmentsTable).select();
    if (taskId != null && taskId.trim().isNotEmpty) {
      query = query.eq('task_id', taskId.trim());
    }
    if (orderId != null && orderId.trim().isNotEmpty) {
      query = query.eq('order_id', orderId.trim());
    }
    if (stageId != null && stageId.trim().isNotEmpty) {
      query = query.eq('stage_id', stageId.trim());
    }
    final ids = (commentIds ?? const <String>[])
        .map((id) => id.trim())
        .where((id) => id.isNotEmpty)
        .toList(growable: false);
    if (ids.isNotEmpty) {
      query = query.inFilter('comment_id', ids);
    }
    final rows = await query.order('created_at');
    final attachments = <TaskCommentAttachment>[];
    if (rows is List) {
      for (final raw in rows) {
        final map = Map<String, dynamic>.from(raw as Map);
        attachments.add(await _withSignedUrl(
          TaskCommentAttachment.fromMap(map),
          bucket: kTaskCommentAttachmentsBucket,
          signedUrlTtl: signedUrlTtl,
        ));
      }
    }
    return attachments;
  }

  Future<List<OrderCommentAttachment>> loadOrderCommentAttachments({
    required String orderId,
    Iterable<String>? commentIds,
    Duration signedUrlTtl = const Duration(hours: 12),
  }) async {
    dynamic query = _supabase
        .from(kOrderCommentAttachmentsTable)
        .select()
        .eq('order_id', orderId.trim());
    final ids = (commentIds ?? const <String>[])
        .map((id) => id.trim())
        .where((id) => id.isNotEmpty)
        .toList(growable: false);
    if (ids.isNotEmpty) query = query.inFilter('comment_id', ids);
    final rows = await query.order('created_at');
    final attachments = <OrderCommentAttachment>[];
    if (rows is List) {
      for (final raw in rows) {
        attachments.add(await _withSignedUrl(
          OrderCommentAttachment.fromMap(Map<String, dynamic>.from(raw as Map)),
          bucket: kOrderCommentAttachmentsBucket,
          signedUrlTtl: signedUrlTtl,
        ));
      }
    }
    return attachments;
  }

  Future<String> getUrl(
    TaskCommentAttachment attachment, {
    Duration signedUrlTtl = const Duration(hours: 12),
  }) async {
    if ((attachment.fileUrl ?? '').trim().isNotEmpty) {
      return attachment.fileUrl!.trim();
    }
    return _supabase.storage
      .from(kTaskCommentAttachmentsBucket)
      .createSignedUrl(attachment.storagePath, signedUrlTtl.inSeconds);
  }

  Future<String> getOrderAttachmentUrl(
    OrderCommentAttachment attachment, {
    Duration signedUrlTtl = const Duration(hours: 12),
  }) async {
    if ((attachment.fileUrl ?? '').trim().isNotEmpty) {
      return attachment.fileUrl!.trim();
    }
    return _supabase.storage
        .from(kOrderCommentAttachmentsBucket)
        .createSignedUrl(attachment.storagePath, signedUrlTtl.inSeconds);
  }

  Future<void> removeAttachment(TaskCommentAttachment attachment) async {
    await removeStorageObject(attachment.storagePath);
    await _supabase
        .from(kTaskCommentAttachmentsTable)
        .delete()
        .eq('id', attachment.id);
  }

  Future<void> removeStorageObject(
    String storagePath, {
    String bucket = kTaskCommentAttachmentsBucket,
  }) async {
    try {
      await _supabase
          .storage
          .from(bucket)
          .remove([storagePath]);
    } catch (_) {
      // Best-effort rollback cleanup. The original DB/storage error is more important.
    }
  }

  Future<T> _withSignedUrl<T>(
    T attachment, {
    required String bucket,
    required Duration signedUrlTtl,
  }) async {
    if (attachment is TaskCommentAttachment) {
      final url = await _supabase.storage
          .from(bucket)
          .createSignedUrl(attachment.storagePath, signedUrlTtl.inSeconds);
      return attachment.copyWith(fileUrl: url) as T;
    }
    if (attachment is OrderCommentAttachment) {
      final url = await _supabase.storage
          .from(bucket)
          .createSignedUrl(attachment.storagePath, signedUrlTtl.inSeconds);
      return attachment.copyWith(fileUrl: url) as T;
    }
    throw ArgumentError('Unsupported attachment type: ${attachment.runtimeType}');
  }

  Future<void> _uploadBinary({
    required String bucket,
    required String storagePath,
    required Uint8List bytes,
    required String mimeType,
  }) {
    return _supabase.storage.from(bucket).uploadBinary(
          storagePath,
          bytes,
          fileOptions: FileOptions(contentType: mimeType, upsert: false),
        );
  }

  String _sanitizeFileName(String value) {
    final trimmed = value.trim();
    if (trimmed.isEmpty) return 'attachment';
    return trimmed.replaceAll(RegExp(r'[\\/]+'), '_');
  }
}
