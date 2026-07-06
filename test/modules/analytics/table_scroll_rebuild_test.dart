import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sheet_clone/modules/analytics/utils/h_scroll_sync.dart';

/// Замер Фазы 4: тик горизонтального скролла не должен пересобирать контент
/// строк. Схема повторяет таблицы аналитики: контент строки передаётся через
/// параметр `child` per-row ValueListenableBuilder'а, builder создаёт только
/// Transform.translate.
class _CountingContent extends StatelessWidget {
  const _CountingContent({required this.onBuild});

  final VoidCallback onBuild;

  @override
  Widget build(BuildContext context) {
    onBuild();
    return const SizedBox(width: 1000, height: 30);
  }
}

void main() {
  testWidgets('тик скролла: 0 пересборок контента строк (child у VLB)',
      (tester) async {
    final sync = HScrollSync();
    final header = sync.acquire();
    var contentBuilds = 0;
    const rowCount = 5;

    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: Column(
          children: [
            // Настоящий scrollable — как заголовок таблицы.
            SizedBox(
              height: 30,
              width: 300,
              child: SingleChildScrollView(
                controller: header,
                scrollDirection: Axis.horizontal,
                child: const SizedBox(width: 1000, height: 30),
              ),
            ),
            // Строки-подписчики — как строки данных таблиц.
            for (var i = 0; i < rowCount; i++)
              SizedBox(
                height: 30,
                width: 300,
                child: ClipRect(
                  child: OverflowBox(
                    alignment: Alignment.topLeft,
                    minWidth: 0,
                    maxWidth: double.infinity,
                    child: ValueListenableBuilder<double>(
                      valueListenable: sync.offsetNotifier,
                      child:
                          _CountingContent(onBuild: () => contentBuilds++),
                      builder: (context, hOffset, child) =>
                          Transform.translate(
                        offset: Offset(-hOffset, 0),
                        child: child,
                      ),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );

    expect(tester.takeException(), isNull);
    expect(contentBuilds, rowCount, reason: 'первичная сборка — по одной');

    // 10 тиков скролла заголовка.
    for (var offset = 10.0; offset <= 100.0; offset += 10.0) {
      header.jumpTo(offset);
      await tester.pump();
    }

    expect(sync.offsetNotifier.value, 100.0);
    expect(tester.takeException(), isNull);
    expect(contentBuilds, rowCount,
        reason: 'тики скролла не должны пересобирать контент строк '
            '(до фикса: N строк × каждый тик)');
  });
}
