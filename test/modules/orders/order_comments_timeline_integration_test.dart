import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:app/modules/orders/order_comment_attachment.dart';
import 'package:app/modules/orders/order_comments_timeline.dart';
import 'package:app/modules/tasks/task_model.dart';

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
          body: OrderCommentsTimeline(
            comments: [comment],
            attachmentsByComment: {
              'c1': [attachment],
            },
          ),
        ),
      );

  testWidgets('рендерится одинаково на экране архива', (tester) async {
    await tester.pumpWidget(host('Архив'));
    expect(find.text('Тестовый комментарий'), findsOneWidget);
    expect(find.text('spec.pdf'), findsOneWidget);
  });

  testWidgets('рендерится одинаково на экране редактирования', (tester) async {
    await tester.pumpWidget(host('Редактирование'));
    expect(find.text('Тестовый комментарий'), findsOneWidget);
    expect(find.text('spec.pdf'), findsOneWidget);
  });
}
