import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sheet_clone/modules/chat/chat_message.dart';
import 'package:sheet_clone/modules/chat/widgets/message_bubble.dart';

/// Фаза E «Претензии из чата»: бейдж «Претензия: имена» в MessageBubble
/// строится из claim_targets сообщения (sender_id не участвует).
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    // _MessageBubbleState создаёт AudioPlayer (audioplayers 2.x); в тестах
    // платформенного канала нет — мокаем, чтобы dispose не падал.
    for (final name in [
      'xyz.luan/audioplayers',
      'xyz.luan/audioplayers.global',
    ]) {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
              MethodChannel(name), (call) async => null);
    }
  });

  ChatMessage message({List<ChatClaimTarget> targets = const []}) =>
      ChatMessage(
        id: 'm1',
        roomId: 'general',
        senderId: null, // бейдж не должен зависеть от sender_id
        senderName: 'Менеджер Мария',
        kind: 'video',
        body: 'Смотрите видео',
        createdAt: DateTime(2026, 7, 3, 14, 40),
        claimTargets: targets,
      );

  Future<void> pumpBubble(WidgetTester tester, ChatMessage m) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: MessageBubble(m: m, isMine: false, meId: 'someone'),
        ),
      ),
    );
    await tester.pump();
  }

  testWidgets('сообщение с claim_targets показывает бейдж с именами',
      (tester) async {
    await pumpBubble(
      tester,
      message(targets: const [
        ChatClaimTarget(id: 'e1', name: 'Иванов Иван'),
        ChatClaimTarget(id: 'e2', name: 'Петров Пётр'),
      ]),
    );

    expect(
      find.text('Претензия: Иванов Иван, Петров Пётр'),
      findsOneWidget,
    );
    expect(find.byIcon(Icons.flag), findsOneWidget);
  });

  testWidgets('обычное сообщение — без бейджа', (tester) async {
    await pumpBubble(tester, message());

    expect(find.textContaining('Претензия'), findsNothing);
    expect(find.byIcon(Icons.flag), findsNothing);
  });
}
