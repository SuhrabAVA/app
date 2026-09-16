import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sheet_clone/services/connectivity_service.dart';
import 'package:sheet_clone/widgets/offline_overlay.dart';

Widget host(Size screen) => MediaQuery(
      data: MediaQueryData(size: screen),
      child: const Directionality(
        textDirection: TextDirection.ltr,
        child: OfflineOverlayHost(child: SizedBox.expand()),
      ),
    );

void main() {
  tearDown(() => ConnectivityService.instance.debugSetOnline(true));

  group('badgeSizeFor', () {
    test('на компьютере ровно 230', () {
      expect(
        OfflineOverlayHost.badgeSizeFor(const Size(1536, 864), isDesktop: true),
        230,
      );
    });

    test('в узком окне не больше половины короткой стороны', () {
      expect(
        OfflineOverlayHost.badgeSizeFor(const Size(320, 200), isDesktop: true),
        100,
      );
    });

    test('на телефоне и планшете — пропорционально меньше 230', () {
      final phone =
          OfflineOverlayHost.badgeSizeFor(const Size(390, 844), isDesktop: false);
      final tablet =
          OfflineOverlayHost.badgeSizeFor(const Size(853, 485), isDesktop: false);
      expect(phone, lessThan(OfflineOverlayHost.desktopSize));
      expect(tablet, lessThan(OfflineOverlayHost.desktopSize));
      expect(phone, lessThan(tablet));
      expect(phone, greaterThanOrEqualTo(OfflineOverlayHost.minSize));
    });
  });

  group('OfflineOverlayHost', () {
    testWidgets('при связи оверлея нет вовсе', (tester) async {
      ConnectivityService.instance.debugSetOnline(true);
      await tester.pumpWidget(host(const Size(1536, 864)));
      expect(find.byType(FadeTransition), findsNothing);
    });

    testWidgets('без связи значок появляется и мигает', (tester) async {
      ConnectivityService.instance.debugSetOnline(false);
      await tester.pumpWidget(host(const Size(1536, 864)));

      expect(find.byType(FadeTransition), findsOneWidget);
      final double full =
          tester.widget<FadeTransition>(find.byType(FadeTransition))
              .opacity
              .value;
      expect(full, 1.0);

      await tester.pump(const Duration(milliseconds: 350));
      final double faded =
          tester.widget<FadeTransition>(find.byType(FadeTransition))
              .opacity
              .value;
      expect(faded, lessThan(full));

      // Мигание не заканчивается само: значок держится, пока нет связи.
      await tester.pump(const Duration(milliseconds: 5000));
      expect(find.byType(FadeTransition), findsOneWidget);
    });

    testWidgets('значок гаснет, как только связь вернулась', (tester) async {
      ConnectivityService.instance.debugSetOnline(false);
      await tester.pumpWidget(host(const Size(1536, 864)));
      expect(find.byType(FadeTransition), findsOneWidget);

      ConnectivityService.instance.debugSetOnline(true);
      await tester.pump();
      expect(find.byType(FadeTransition), findsNothing);
    });

    testWidgets('значок не перехватывает нажатия', (tester) async {
      ConnectivityService.instance.debugSetOnline(false);
      var taps = 0;
      await tester.pumpWidget(
        MediaQuery(
          data: const MediaQueryData(size: Size(1536, 864)),
          child: Directionality(
            textDirection: TextDirection.ltr,
            child: OfflineOverlayHost(
              child: GestureDetector(
                onTap: () => taps++,
                behavior: HitTestBehavior.opaque,
                child: const SizedBox.expand(),
              ),
            ),
          ),
        ),
      );

      // Тап ровно в центр значка вверху экрана.
      await tester.tapAt(const Offset(768, 130));
      expect(taps, 1);
    });
  });
}
