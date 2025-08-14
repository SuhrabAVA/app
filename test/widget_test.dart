// This is a basic Flutter widget test.
//
// To perform an interaction with a widget in your test, use the WidgetTester
// utility in the flutter_test package. For example, you can send tap and scroll
// gestures. You can also use WidgetTester to find child widgets in the widget
// tree, read text, and verify that the values of widget properties are correct.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sheet_clone/my_app.dart'; 
import 'package:sheet_clone/main.dart';
import 'package:sheet_clone/my_app.dart';
void main() {
    testWidgets('Login screen displays form fields', (WidgetTester tester) async {
    // Build our app and trigger a frame.
    await tester.pumpWidget(const MyApp());

     expect(find.text('Логин'), findsOneWidget);
    expect(find.text('Пароль'), findsOneWidget);
    expect(find.text('Войти'), findsOneWidget);
  });

  testWidgets('shows error message for invalid credentials', (WidgetTester tester) async {
    await tester.pumpWidget(const MyApp());

    // Tap the '+' icon and trigger a frame.
    await tester.enterText(find.byType(TextField).at(0), 'wrong');
    await tester.enterText(find.byType(TextField).at(1), 'creds');
    await tester.tap(find.text('Войти'));
    await tester.pump();

    // Verify that our counter has incremented.
    expect(find.text('Неверный логин или пароль'), findsOneWidget);
  });
}
