import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sheet_clone/modules/manager/manager_workspace_screen.dart';

/// Шапка рабочего места менеджера съедала четверть окна: `AppBar` 56 px плюс
/// `TabBar` с иконкой над подписью ещё 72 px, а под ними шла собственная шапка
/// открытого модуля. Таблица заданий начиналась ниже середины экрана.
///
/// Тест держит два свойства: одна строка вместо двух и отсутствие
/// переполнения на узком окне, где имя и четыре вкладки уже не помещаются.
void main() {
  Widget host(Size size) => MediaQuery(
        data: MediaQueryData(size: size),
        child: MaterialApp(
          home: DefaultTabController(
            length: 4,
            child: Scaffold(
              appBar: ManagerWorkspaceAppBar(
                title: 'Авакова Аружан Мұратқызы • Менеджер',
                onLogout: () {},
              ),
              body: const SizedBox.expand(),
            ),
          ),
        ),
      );

  testWidgets('шапка и вкладки укладываются в одну строку', (tester) async {
    tester.view.physicalSize = const Size(1536, 960);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(host(const Size(1536, 960)));
    await tester.pumpAndSettle();

    final appBarHeight = tester.getSize(find.byType(AppBar)).height;
    expect(
      appBarHeight,
      kManagerWorkspaceHeaderHeight,
      reason: 'заголовок и вкладки должны занимать одну полосу, а не две',
    );

    // Все четыре вкладки на месте, и имя рядом с ними помещается.
    for (final label in ['Заказы', 'Архив', 'Производство', 'Чат']) {
      expect(find.text(label), findsOneWidget);
    }
    expect(find.textContaining('Менеджер'), findsWidgets);
    expect(tester.takeException(), isNull);
  });

  testWidgets('на узком окне имя уступает место вкладкам', (tester) async {
    const narrow = Size(600, 800);
    tester.view.physicalSize = narrow;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(host(narrow));
    await tester.pumpAndSettle();

    // Ниже breakpoint имя скрыто целиком — иначе строка уходила бы в
    // переполнение, а без вкладок рабочее место непереключаемо.
    expect(find.textContaining('Авакова'), findsNothing);
    for (final label in ['Заказы', 'Архив', 'Производство', 'Чат']) {
      expect(find.text(label), findsOneWidget);
    }
    expect(tester.takeException(), isNull);
  });
}
