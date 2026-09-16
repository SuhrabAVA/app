import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sheet_clone/modules/orders/order_editing_frame.dart';

void main() {
  testWidgets('busy order pulses, names its editor and stops after release',
      (tester) async {
    Widget scene(String? editor) => MaterialApp(
            home: Scaffold(
                body: OrderEditingFrame(
          editorName: editor,
          child: const SizedBox(width: 260, height: 180, child: Text('Заказ')),
        )));
    await tester.pumpWidget(scene('Анна'));
    expect(find.byTooltip('Редактирует: Анна. Дождитесь сохранения.'),
        findsOneWidget);
    expect(tester.binding.hasScheduledFrame, isTrue);
    await tester.pump(const Duration(milliseconds: 600));
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(scene(null));
    await tester.pumpAndSettle();
    expect(find.byType(Tooltip), findsNothing);
    expect(find.text('Заказ'), findsOneWidget);
  });

  testWidgets('reduced motion keeps a static busy outline', (tester) async {
    await tester.pumpWidget(const MaterialApp(
        home: MediaQuery(
      data: MediaQueryData(disableAnimations: true),
      child: OrderEditingFrame(
          editorName: 'Анна', child: SizedBox(width: 200, height: 80)),
    )));
    await tester.pumpAndSettle();
    expect(tester.binding.hasScheduledFrame, isFalse);
    expect(find.byTooltip('Редактирует: Анна. Дождитесь сохранения.'),
        findsOneWidget);
  });
}
