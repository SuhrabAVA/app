import 'package:flutter_test/flutter_test.dart';
import 'package:sheet_clone/modules/orders/product_type_route.dart';
import 'package:sheet_clone/modules/orders/product_type_stage_guards.dart';

/// Правила блокировки правки маршрута.
///
/// ЗАЧЕМ ЭТОТ ТЕСТ СУЩЕСТВУЕТ
/// В порядке этих условий уже был дефект: правило про вариант по умолчанию
/// стояло раньше правила «нужно не меньше двух вариантов», и при ровно двух
/// вариантах техлид получал совет переназначить вариант по умолчанию, выполнял
/// его и упирался в ту же неактивную кнопку. Тупик. Пока правила жили
/// приватными методами виджета, проверить их можно было только глазами.
void main() {
  group('удаление рабочего места, режим «все РМ»', () {
    test('единственное РМ убрать нельзя — этап не попадёт в план', () {
      final stage = _stage(mode: 'all', workplaces: [_wp('wp-1')]);
      expect(
        workplaceDeleteBlockedReason(stage, stage.workplaces.first),
        contains('удалите этап целиком'),
      );
    });

    test('из двух РМ убрать можно любое', () {
      final stage = _stage(mode: 'all', workplaces: [_wp('wp-1'), _wp('wp-2')]);
      for (final workplace in stage.workplaces) {
        expect(workplaceDeleteBlockedReason(stage, workplace), isNull);
      }
    });
  });

  group('удаление варианта, режим «один из»', () {
    test('при ровно двух вариантах заблокированы ОБА, включая не-default', () {
      final stage = _stage(mode: 'one_of', workplaces: [
        _wp('wp-1', isDefault: true),
        _wp('wp-2'),
      ]);

      // Это и есть исправленный дефект: у второго варианта нет признака
      // «по умолчанию», но удалить его всё равно нельзя — и причина должна
      // быть про количество, а не про переназначение.
      for (final workplace in stage.workplaces) {
        final reason = workplaceDeleteBlockedReason(stage, workplace);
        expect(reason, isNotNull);
        expect(reason, contains('не меньше двух вариантов'));
        expect(reason, isNot(contains('по умолчанию другой')),
            reason: 'совет переназначить default здесь ведёт в тупик');
      }
    });

    test('при трёх вариантах заблокирован только вариант по умолчанию', () {
      final stage = _stage(mode: 'one_of', workplaces: [
        _wp('wp-1', isDefault: true),
        _wp('wp-2'),
        _wp('wp-3'),
      ]);

      expect(
        workplaceDeleteBlockedReason(stage, stage.workplaces[0]),
        contains('по умолчанию другой'),
      );
      expect(workplaceDeleteBlockedReason(stage, stage.workplaces[1]), isNull);
      expect(workplaceDeleteBlockedReason(stage, stage.workplaces[2]), isNull);
    });
  });

  group('смена режима', () {
    test('этап с одним РМ переключаемым не сделать', () {
      final stage = _stage(mode: 'all', workplaces: [_wp('wp-1')]);
      expect(
        selectionModeChangeBlockedReason(stage),
        contains('второе рабочее место'),
      );
    });

    test('этап с двумя РМ переключаемым сделать можно', () {
      final stage = _stage(mode: 'all', workplaces: [_wp('wp-1'), _wp('wp-2')]);
      expect(selectionModeChangeBlockedReason(stage), isNull);
    });

    test('обратный переход не запрещён никогда — о нём предупреждает диалог',
        () {
      final stage = _stage(mode: 'one_of', workplaces: [
        _wp('wp-1', isDefault: true),
        _wp('wp-2'),
      ]);
      expect(selectionModeChangeBlockedReason(stage), isNull);
    });
  });
}

RouteStage _stage({
  required String mode,
  required List<RouteStageWorkplace> workplaces,
}) =>
    RouteStage(
      rowId: 'stage-1',
      key: 'stage-key',
      title: 'Этап',
      position: 1,
      level: 0,
      selectionMode: mode,
      workplaces: workplaces,
    );

RouteStageWorkplace _wp(String id, {bool isDefault = false}) =>
    RouteStageWorkplace(
      rowId: 'row-$id',
      workplaceId: id,
      isDefault: isDefault,
    );
