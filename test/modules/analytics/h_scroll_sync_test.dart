import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sheet_clone/modules/analytics/utils/h_scroll_sync.dart';

void main() {
  testWidgets(
      'скролл одного контроллера двигает второй и обновляет offsetNotifier',
      (tester) async {
    final sync = HScrollSync();
    final header = sync.acquire();
    final footer = sync.acquire();

    Widget hScroll(ScrollController ctrl) => SizedBox(
          height: 50,
          width: 200,
          child: SingleChildScrollView(
            controller: ctrl,
            scrollDirection: Axis.horizontal,
            child: const SizedBox(width: 1000, height: 50),
          ),
        );

    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: Column(children: [hScroll(header), hScroll(footer)]),
      ),
    );

    expect(sync.offsetNotifier.value, 0.0);

    var notified = 0;
    sync.offsetNotifier.addListener(() => notified++);

    header.jumpTo(120);
    await tester.pump();

    expect(sync.offsetNotifier.value, 120.0);
    expect(footer.offset, 120.0);
    expect(notified, greaterThan(0));

    // Обратное направление: скролл футера двигает шапку.
    footer.jumpTo(40);
    await tester.pump();
    expect(sync.offsetNotifier.value, 40.0);
    expect(header.offset, 40.0);
  });

  testWidgets('контроллер, полученный после скролла, стартует с текущего оффсета',
      (tester) async {
    final sync = HScrollSync();
    final first = sync.acquire();

    Widget hScroll(ScrollController ctrl) => SizedBox(
          height: 50,
          width: 200,
          child: SingleChildScrollView(
            controller: ctrl,
            scrollDirection: Axis.horizontal,
            child: const SizedBox(width: 1000, height: 50),
          ),
        );

    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: hScroll(first),
      ),
    );
    first.jumpTo(75);
    await tester.pump();

    final late = sync.acquire();
    expect(late.initialScrollOffset, 75.0);
  });
}
