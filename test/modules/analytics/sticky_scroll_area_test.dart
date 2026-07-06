import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sheet_clone/modules/analytics/widgets/analytics_table_parts.dart';

/// Регрессия на механику строк таблиц аналитики (см. StickyScrollArea):
/// 1) Stack внутри StickyScrollArea обязан отдавать intrinsic-высоту контента,
///    иначе IntrinsicHeight мерит строку только по sticky-ячейке и контент
///    сплющивается (RenderFlex overflow 13/29px);
/// 2) OverflowBox обязан разрывать tight-ширину ячейки, иначе
///    SizedBox(width: restWidth) схлопывается до видимой области и колонки
///    рассинхронизируются с заголовком.
void main() {
  testWidgets(
      'строка таблицы: высота — от контента, ширина контента — restWidth',
      (tester) async {
    const restWidth = 1000.0;
    const contentKey = Key('row-content');

    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: Center(
          child: SizedBox(
            width: 400,
            child: IntrinsicHeight(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  // Sticky-ячейка заведомо НИЖЕ контента (20 < 60): если Stack
                  // не отдаёт intrinsic контента, строка сожмётся до 20.
                  const SizedBox(width: 100, height: 20),
                  Expanded(
                    child: StickyScrollArea(
                      child: ClipRect(
                        child: OverflowBox(
                          alignment: Alignment.topLeft,
                          minWidth: 0,
                          maxWidth: double.infinity,
                          child: Transform.translate(
                            offset: const Offset(0, 0),
                            child: const SizedBox(
                              key: contentKey,
                              width: restWidth,
                              child: Column(
                                mainAxisSize: MainAxisSize.min,
                                children: [SizedBox(height: 60)],
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );

    expect(tester.takeException(), isNull);

    final contentSize = tester.getSize(find.byKey(contentKey));
    expect(contentSize.width, restWidth,
        reason: 'ширина контента не должна схлопываться до видимой области');
    expect(contentSize.height, 60,
        reason: 'высота строки должна определяться контентом, не sticky-ячейкой');
  });
}
