import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sheet_clone/my_app.dart';

void main() {
  testWidgets('Login screen displays form fields', (WidgetTester tester) async {
    await tester.pumpWidget(const MyApp());

    expect(find.text('Логин'), findsOneWidget);
    expect(find.text('Пароль'), findsOneWidget);
    expect(find.text('Войти'), findsOneWidget);
  });

  testWidgets('shows error message for invalid credentials', (WidgetTester tester) async {
    await tester.pumpWidget(const MyApp());

    await tester.enterText(find.byType(TextField).at(0), 'wrong');
    await tester.enterText(find.byType(TextField).at(1), 'creds');
    await tester.tap(find.text('Войти'));
    await tester.pump();

    expect(find.text('Неверный логин или пароль'), findsOneWidget);
  });
}
