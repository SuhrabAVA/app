import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sheet_clone/modules/tasks/tasks_screen.dart';

void main() {
  Future<void> pump(WidgetTester tester, Widget child) async {
    await tester.pumpWidget(
      MaterialApp(home: Scaffold(body: Center(child: child))),
    );
  }

  testWidgets('выключенная кнопка остаётся disabled, но тап объясняет причину',
      (tester) async {
    var explained = 0;

    await pump(
      tester,
      ExplainOnTap(
        enabled: false,
        explain: () => explained++,
        child: const ElevatedButton(
          onPressed: null,
          child: Text('✓ Завершить'),
        ),
      ),
    );

    final button = tester.widget<ElevatedButton>(find.byType(ElevatedButton));
    expect(button.onPressed, isNull, reason: 'кнопка должна быть выключена');
    expect(button.enabled, isFalse);

    // Тап проходит мимо самой кнопки (её перехватывает AbsorbPointer) и
    // попадает в обёртку — именно это нам и нужно проверить.
    await tester.tap(find.text('✓ Завершить'), warnIfMissed: false);
    await tester.pump();

    expect(explained, 1);
  });

  testWidgets('включённая кнопка не оборачивается и работает как обычно',
      (tester) async {
    var explained = 0;
    var pressed = 0;

    await pump(
      tester,
      ExplainOnTap(
        enabled: true,
        explain: () => explained++,
        child: ElevatedButton(
          onPressed: () => pressed++,
          child: const Text('✓ Завершить'),
        ),
      ),
    );

    final button = tester.widget<ElevatedButton>(find.byType(ElevatedButton));
    expect(button.enabled, isTrue);

    await tester.tap(find.text('✓ Завершить'));
    await tester.pump();

    expect(pressed, 1);
    expect(explained, 0);
  });

  testWidgets('без explain-колбэка тап по выключенной кнопке ничего не делает',
      (tester) async {
    var pressed = 0;

    await pump(
      tester,
      const ExplainOnTap(
        enabled: false,
        explain: null,
        child: ElevatedButton(
          onPressed: null,
          child: Text('✓ Завершить'),
        ),
      ),
    );

    await tester.tap(find.text('✓ Завершить'), warnIfMissed: false);
    await tester.pump();

    expect(pressed, 0);
    expect(
      tester.widget<ElevatedButton>(find.byType(ElevatedButton)).enabled,
      isFalse,
    );
  });
}
