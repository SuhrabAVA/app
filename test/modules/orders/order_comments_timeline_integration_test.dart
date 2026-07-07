import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sheet_clone/modules/orders/order_comment_attachment.dart';
import 'package:sheet_clone/modules/orders/order_comments_repository.dart';
import 'package:sheet_clone/modules/orders/order_comments_timeline.dart';
import 'package:sheet_clone/modules/orders/order_restart_history_repository.dart';
import 'package:sheet_clone/modules/orders/restart_history_service.dart';
import 'package:sheet_clone/modules/tasks/task_model.dart';

class _FakeOrderCommentsRepository implements OrderCommentsRepository {
  _FakeOrderCommentsRepository(this._commentsByOrder, this._attachments);

  final Map<String, List<TaskComment>> _commentsByOrder;
  final List<OrderCommentAttachment> _attachments;

  @override
  Future<List<TaskComment>> loadComments(String orderId) async =>
      _commentsByOrder[orderId] ?? const [];

  @override
  Future<List<OrderCommentAttachment>> loadAttachmentsByCommentIds(
      List<String> commentIds) async {
    return _attachments.where((a) => commentIds.contains(a.commentId)).toList();
  }

  @override
  Future<TaskComment> sendComment({
    required String taskId,
    required String userId,
    required String text,
    String type = 'comment',
  }) async =>
      throw UnimplementedError();

  @override
  Future<void> attachFiles(List<Map<String, dynamic>> rows) async {}
}

class _FakeHistoryRepository implements OrderRestartHistoryRepository {
  _FakeHistoryRepository({this.chain = const []});

  final List<OrderGenerationEntry> chain;

  @override
  Future<OrderRestartHistoryEntry?> loadOrderById(String orderId) async => null;

  @override
  Future<List<OrderRestartHistoryEntry>> loadRestartHistoryChainViaRpc(
    String orderId, {
    int limit = 200,
  }) async =>
      const [];

  @override
  Future<List<OrderGenerationEntry>> loadGenerationChain(
          String orderId) async =>
      chain;
}

TaskComment _comment(String id, String text) => TaskComment(
      id: id,
      type: 'comment',
      text: text,
      userId: 'u1',
      timestamp: DateTime(2026, 1, 1).millisecondsSinceEpoch,
    );

void main() {
  final comment = _comment('c1', 'Тестовый комментарий');
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

  RestartHistoryService historyService(
          [List<OrderGenerationEntry> chain = const []]) =>
      RestartHistoryService(_FakeHistoryRepository(chain: chain));

  Widget host(String title) => MaterialApp(
        home: Scaffold(
          appBar: AppBar(title: Text(title)),
          body: OrderCommentsSection(
            orderId: 'o1',
            repository: _FakeOrderCommentsRepository(
              {
                'o1': [comment],
              },
              [attachment],
            ),
            historyService: historyService(),
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
            repository: _FakeOrderCommentsRepository(const {}, const []),
            historyService: historyService(),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Legacy-only comment'), findsOneWidget);
  });

  testWidgets('без предыдущих поколений переключатель не показывается',
      (tester) async {
    await tester.pumpWidget(host('Без возобновлений'));
    await tester.pumpAndSettle();
    expect(find.byType(ChoiceChip), findsNothing);
    expect(find.text('Текущий заказ'), findsNothing);
  });

  testWidgets(
      'с цепочкой поколений: вкладки по дате создания, история только чтение',
      (tester) async {
    final chain = [
      OrderGenerationEntry(
        id: 'gen0',
        generation: 0,
        orderDate: DateTime(2026, 3, 12),
        isCurrent: false,
      ),
      const OrderGenerationEntry(id: 'o1', generation: 1, isCurrent: true),
    ];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: OrderCommentsSection(
            orderId: 'o1',
            repository: _FakeOrderCommentsRepository(
              {
                'o1': [comment],
                'gen0': [_comment('c0', 'Комментарий прошлой жизни')],
              },
              const [],
            ),
            historyService: historyService(chain),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // Вкладки: текущий заказ + прошлое поколение с датой создания.
    expect(find.text('Текущий заказ'), findsOneWidget);
    expect(find.text('12.03.2026'), findsOneWidget);
    expect(find.text('Тестовый комментарий'), findsOneWidget);

    // Переключение на прошлое поколение: его история + пометка о чтении.
    await tester.tap(find.text('12.03.2026'));
    await tester.pumpAndSettle();
    expect(find.text('Комментарий прошлой жизни'), findsOneWidget);
    expect(find.text('Тестовый комментарий'), findsNothing);
    expect(
      find.text('Только просмотр: история предыдущего заказа'),
      findsOneWidget,
    );

    // И обратно на текущий.
    await tester.tap(find.text('Текущий заказ'));
    await tester.pumpAndSettle();
    expect(find.text('Тестовый комментарий'), findsOneWidget);
    expect(find.text('Комментарий прошлой жизни'), findsNothing);
  });
}
