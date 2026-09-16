import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sheet_clone/modules/orders/order_manager_comment_banner.dart';

Future<void> _pump(WidgetTester tester, String comment) {
  return tester.pumpWidget(
    MaterialApp(
      home: Scaffold(body: OrderManagerCommentBanner(comment: comment)),
    ),
  );
}

void main() {
  testWidgets('комментарий менеджера — на красном фоне #A80006',
      (tester) async {
    await _pump(tester, '  Печатать только после звонка заказчику  ');

    expect(find.text('КОММЕНТАРИЙ'), findsOneWidget);
    expect(find.text('Печатать только после звонка заказчику'), findsOneWidget);

    final box = tester.widget<Container>(find
        .ancestor(
          of: find.text('КОММЕНТАРИЙ'),
          matching: find.byType(Container),
        )
        .last);
    final decoration = box.decoration! as BoxDecoration;
    expect(decoration.color, const Color(0xFFA80006));
  });

  testWidgets('пустой комментарий блока не создаёт', (tester) async {
    await _pump(tester, '   ');

    expect(find.text('КОММЕНТАРИЙ'), findsNothing);
    expect(OrderManagerCommentBanner.hasComment('   '), isFalse);
    expect(OrderManagerCommentBanner.hasComment('нет'), isTrue);
  });
}
