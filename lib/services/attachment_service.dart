import 'dart:typed_data';

import 'package:mime/mime.dart';
import 'package:path/path.dart' as p;
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:uuid/uuid.dart';

import '../modules/tasks/task_model.dart';

const String kTaskCommentAttachmentsBucket = 'task-comment-attachments';
const String kTaskCommentAttachmentsTable = 'task_comment_attachments';

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

    final storage = _supabase.storage.from(kTaskCommentAttachmentsBucket);
    await storage.uploadBinary(
      storagePath,
      draft.bytes,
      fileOptions: FileOptions(contentType: draft.mimeType, upsert: false),
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
        signedUrlTtl,
      );
    } catch (_) {
      await removeStorageObject(storagePath);
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
          signedUrlTtl,
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

  Future<void> removeAttachment(TaskCommentAttachment attachment) async {
    await removeStorageObject(attachment.storagePath);
    await _supabase
        .from(kTaskCommentAttachmentsTable)
        .delete()
        .eq('id', attachment.id);
  }

  Future<void> removeStorageObject(String storagePath) async {
    try {
      await _supabase
          .storage
          .from(kTaskCommentAttachmentsBucket)
          .remove([storagePath]);
    } catch (_) {
      // Best-effort rollback cleanup. The original DB/storage error is more important.
    }
  }

  Future<TaskCommentAttachment> _withSignedUrl(
    TaskCommentAttachment attachment,
    Duration signedUrlTtl,
  ) async {
    final url = await getUrl(attachment, signedUrlTtl: signedUrlTtl);
    return attachment.copyWith(fileUrl: url);
  }

  String _sanitizeFileName(String value) {
    final trimmed = value.trim();
    if (trimmed.isEmpty) return 'attachment';
    return trimmed.replaceAll(RegExp(r'[\\/]+'), '_');
  }
}
