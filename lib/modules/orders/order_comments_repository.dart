import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:uuid/uuid.dart';

import '../tasks/task_model.dart';
import 'order_comment_attachment.dart';

class OrderCommentsRepository {
  OrderCommentsRepository({SupabaseClient? supabase})
      : _supabase = supabase ?? Supabase.instance.client;

  final SupabaseClient _supabase;
  static const _uuid = Uuid();

  Future<List<TaskComment>> loadComments(String orderId) async {
    final rows = await _supabase
        .from('tasks')
        .select('comments')
        .eq('order_id', orderId);
    final result = <TaskComment>[];
    for (final row in rows as List<dynamic>) {
      final comments = row['comments'];
      if (comments is! Map) continue;
      comments.forEach((key, value) {
        if (value is Map<String, dynamic>) {
          result.add(TaskComment.fromMap(value, key.toString()));
        } else if (value is Map) {
          result.add(TaskComment.fromMap(Map<String, dynamic>.from(value), key.toString()));
        }
      });
    }
    result.sort((a, b) => a.timestamp.compareTo(b.timestamp));
    return result;
  }

  Future<List<OrderCommentAttachment>> loadAttachmentsByCommentIds(List<String> commentIds) async {
    if (commentIds.isEmpty) return const [];
    final rows = await _supabase
        .from('task_comment_attachments')
        .select('*')
        .inFilter('comment_id', commentIds);
    return (rows as List<dynamic>)
        .map((e) => OrderCommentAttachment.fromMap(Map<String, dynamic>.from(e as Map)))
        .toList();
  }

  Future<TaskComment> sendComment({
    required String taskId,
    required String userId,
    required String text,
    String type = 'comment',
  }) async {
    final task = await _supabase.from('tasks').select('comments').eq('id', taskId).single();
    final commentsRaw = task['comments'];
    final Map<String, dynamic> comments = commentsRaw is Map
        ? Map<String, dynamic>.from(commentsRaw)
        : <String, dynamic>{};
    final commentId = _uuid.v4();
    final comment = TaskComment(
      id: commentId,
      userId: userId,
      text: text,
      timestamp: DateTime.now(),
      type: type,
    );
    comments[commentId] = comment.toMap();
    await _supabase.from('tasks').update({'comments': comments}).eq('id', taskId);
    return comment;
  }

  Future<void> attachFiles(List<Map<String, dynamic>> rows) async {
    if (rows.isEmpty) return;
    await _supabase.from('task_comment_attachments').insert(rows);
  }
}
