import 'package:app/modules/orders/order_comment_attachment.dart';
import 'package:app/modules/orders/order_comments_repository.dart';
import 'package:app/modules/orders/order_comments_timeline.dart';
import 'package:app/modules/tasks/task_model.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

class _FakeOrderCommentsRepository extends OrderCommentsRepository {
  _FakeOrderCommentsRepository(this._comments, this._attachments);

  final List<TaskComment> _comments;
  final List<OrderCommentAttachment> _attachments;

  @override
  Future<List<TaskComment>> loadComments(String orderId) async => _comments;

  @override
  Future<List<OrderCommentAttachment>> loadAttachmentsByCommentIds(List<String> commentIds) async {
    return _attachments.where((a) => commentIds.contains(a.commentId)).toList();
  }
}

void main() {
  final comment = TaskComment(
    id: 'c1',
    userId: 'u1',
    text: 'Тестовый комментарий',
    timestamp: DateTime(2026, 1, 1),
  );
  final attachment = OrderCommentAttachment(
    id: 'a1',
    orderId: 'o1',
    commentId: 'c1',
    fileName: 'spec.pdf',
    storagePath: 'path/spec.pdf',
    mimeType: 'application/pdf',
    sizeBytes: 100,
    attachmentType: 'file',
    uploadedBy: 'u1',
    createdAt: DateTime(2026, 1, 1),
  );

  Widget host(String title) => MaterialApp(
        home: Scaffold(
          appBar: AppBar(title: Text(title)),
          body: OrderCommentsSection(
            orderId: 'o1',
            repository: _FakeOrderCommentsRepository([comment], [attachment]),
          ),
        ),
      );

  testWidgets('рендерится одинаково на экране архива', (tester) async {
    await tester.pumpWidget(host('Архив'));
    await tester.pumpAndSettle();
    expect(find.text('Тестовый комментарий'), findsOneWidget);
    expect(find.text('spec.pdf'), findsOneWidget);
  });

  testWidgets('рендерится одинаково на экране редактирования', (tester) async {
    await tester.pumpWidget(host('Редактирование'));
    await tester.pumpAndSettle();
    expect(find.text('Тестовый комментарий'), findsOneWidget);
    expect(find.text('spec.pdf'), findsOneWidget);
  });

  testWidgets('комментарий без вложений рендерится как текст', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: OrderCommentsSection(
            orderId: 'o2',
            legacyText: 'Legacy-only comment',
            repository: _FakeOrderCommentsRepository(const [], const []),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Legacy-only comment'), findsOneWidget);
  });
}
