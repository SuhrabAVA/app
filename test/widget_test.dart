import 'package:flutter_test/flutter_test.dart';
import 'package:sheet_clone/my_app.dart';

void main() {
  testWidgets('shows admin panel title', (tester) async {
    await tester.pumpWidget(const MyApp());
    expect(find.text('Панель администратора'), findsOneWidget);
  });
}

