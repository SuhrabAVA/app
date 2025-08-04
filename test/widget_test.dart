import 'package:flutter_test/flutter_test.dart';
import 'package:sheet_clone/my_app.dart';

void main() {
  testWidgets('shows login screen', (tester) async {
    await tester.pumpWidget(const MyApp());
    expect(find.text('Логин'), findsOneWidget);
    expect(find.text('Войти'), findsOneWidget);
  });
}

