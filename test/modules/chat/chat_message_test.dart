import 'package:flutter_test/flutter_test.dart';
import 'package:sheet_clone/modules/chat/chat_message.dart';

/// Фаза E «Претензии из чата»: парсинг claim_targets из chat_messages.
/// PostgREST отдаёт jsonb списком, realtime-payload может отдать строкой,
/// мусор и null не должны ронять модель.
void main() {
  Map<String, dynamic> baseRow({Object? claimTargets}) => {
        'id': 'm1',
        'room_id': 'general',
        'sender_id': 'u1',
        'sender_name': 'Отправитель',
        'kind': 'image',
        'created_at': '2026-07-01T10:00:00Z',
        'claim_targets': claimTargets,
      };

  group('ChatMessage.fromMap / claim_targets', () {
    test('jsonb-список (List<Map>) парсится в цели', () {
      final m = ChatMessage.fromMap(baseRow(claimTargets: [
        {'id': 'e1', 'name': 'Иванов Иван'},
        {'id': 'e2', 'name': 'Петров Пётр'},
      ]));
      expect(m.hasClaim, isTrue);
      expect(m.claimTargets, hasLength(2));
      expect(m.claimTargets.first.id, 'e1');
      expect(m.claimTargets.first.name, 'Иванов Иван');
    });

    test('JSON-строка (realtime-payload) парсится так же', () {
      final m = ChatMessage.fromMap(baseRow(
        claimTargets: '[{"id":"e1","name":"Иванов Иван"}]',
      ));
      expect(m.claimTargets, hasLength(1));
      expect(m.claimTargets.single.name, 'Иванов Иван');
    });

    test('мусорная строка -> пустой список, без исключения', () {
      final m = ChatMessage.fromMap(baseRow(claimTargets: 'not-a-json'));
      expect(m.claimTargets, isEmpty);
      expect(m.hasClaim, isFalse);
    });

    test('null и отсутствие ключа -> пустой список', () {
      expect(ChatMessage.fromMap(baseRow()).claimTargets, isEmpty);
      final row = baseRow()..remove('claim_targets');
      expect(ChatMessage.fromMap(row).claimTargets, isEmpty);
    });

    test('записи без id отбрасываются, валидные остаются', () {
      final m = ChatMessage.fromMap(baseRow(claimTargets: [
        {'name': 'Безымянный'},
        {'id': '', 'name': 'Пустой id'},
        {'id': 'e1', 'name': 'Иванов'},
        'не-map',
      ]));
      expect(m.claimTargets, hasLength(1));
      expect(m.claimTargets.single.id, 'e1');
    });
  });

  group('ChatMessage.toMap / claim_targets', () {
    test('пустые цели -> null (обычное сообщение не тащит ключ)', () {
      final m = ChatMessage.fromMap(baseRow());
      expect(m.toMap()['claim_targets'], isNull);
    });

    test('непустые цели -> список map (round-trip)', () {
      final m = ChatMessage.fromMap(baseRow(claimTargets: [
        {'id': 'e1', 'name': 'Иванов'},
      ]));
      final raw = m.toMap()['claim_targets'];
      expect(raw, [
        {'id': 'e1', 'name': 'Иванов'},
      ]);
      // round-trip: fromMap(toMap) сохраняет цели
      final again = ChatMessage.fromMap(m.toMap());
      expect(again.claimTargets.single.id, 'e1');
    });
  });
}
