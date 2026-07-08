import 'package:flutter_test/flutter_test.dart';
import 'package:sheet_clone/modules/analytics/models/claim_model.dart';

/// Фаза E «Претензии из чата»: ClaimModel с новыми полями
/// (source/message_id/file_url/file_mime/author_name) и нормализацией
/// пустых строк в null.
void main() {
  test('fromMap: чат-претензия со всеми новыми полями', () {
    final c = ClaimModel.fromMap({
      'id': 'cl1',
      'order_id': null,
      'employee_id': 'e1',
      'description': 'Криво упаковано',
      'created_by': 'mgr-1',
      'created_at': '2026-07-03T14:40:00Z',
      'source': 'chat',
      'message_id': 'msg-1',
      'file_url': 'https://x/chat/msg-1.jpg',
      'file_mime': 'image/jpeg',
      'author_name': 'Менеджер Мария',
    });
    expect(c.source, 'chat');
    expect(c.orderId, isNull);
    expect(c.messageId, 'msg-1');
    expect(c.fileUrl, 'https://x/chat/msg-1.jpg');
    expect(c.fileMime, 'image/jpeg');
    expect(c.authorName, 'Менеджер Мария');
    expect(c.createdAt.toUtc().day, 3);
  });

  test('fromMap: строка без source считается заказной (легаси-строки)', () {
    final c = ClaimModel.fromMap({
      'id': 'cl2',
      'order_id': 'o1',
      'employee_id': 'e1',
      'created_at': '2026-07-01T10:00:00Z',
    });
    expect(c.source, 'order');
    expect(c.orderId, 'o1');
    expect(c.messageId, isNull);
  });

  test('fromMap: пустые строки нормализуются в null', () {
    final c = ClaimModel.fromMap({
      'id': 'cl3',
      'order_id': '',
      'comment_id': '',
      'employee_id': 'e1',
      'workplace_id': '',
      'description': '',
      'created_by': '',
      'created_at': '2026-07-01T10:00:00Z',
      'source': '',
      'message_id': '',
      'file_url': '',
      'file_mime': '',
      'author_name': '',
    });
    expect(c.orderId, isNull);
    expect(c.commentId, isNull);
    expect(c.workplaceId, isNull);
    expect(c.description, isNull);
    expect(c.createdBy, isNull);
    expect(c.messageId, isNull);
    expect(c.fileUrl, isNull);
    expect(c.fileMime, isNull);
    expect(c.authorName, isNull);
    // пустой source трактуется как дефолт 'order'
    expect(c.source, 'order');
  });
}
