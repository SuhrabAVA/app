import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:sheet_clone/modules/chat/chat_provider.dart';
import 'package:sheet_clone/modules/chat/chat_screen.dart';

/// Чат во вкладке рабочего пространства живёт без Scaffold: `MaterialApp`
/// сам по себе Material-предка не даёт. Раньше из-за этого поле ввода падало
/// с «No Material widget found», а подставленный ErrorWidget раздувал колонку
/// до overflow в десятки тысяч пикселей.
void main() {
  Widget host({required bool workspaceStyle}) => MaterialApp(
        home: ChangeNotifierProvider<ChatProvider>(
          create: (_) => ChatProvider(),
          child: ChatScreen(
            roomId: 'general',
            meId: 'user-1',
            meName: 'Тестовый',
            workspaceStyle: workspaceStyle,
          ),
        ),
      );

  testWidgets('рабочее пространство: поле ввода строится без Scaffold',
      (tester) async {
    await tester.pumpWidget(host(workspaceStyle: true));
    await tester.pump();

    expect(tester.takeException(), isNull);
    expect(find.byType(TextField), findsOneWidget);
    // Material-предок обязан быть выше поля ввода.
    expect(
      find.ancestor(
        of: find.byType(TextField),
        matching: find.byType(Material),
      ),
      findsWidgets,
    );
  });

  testWidgets('отдельный экран чата по-прежнему строится', (tester) async {
    await tester.pumpWidget(host(workspaceStyle: false));
    await tester.pump();

    expect(tester.takeException(), isNull);
    expect(find.byType(TextField), findsOneWidget);
  });
}
