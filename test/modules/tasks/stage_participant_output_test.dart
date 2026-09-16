import 'package:flutter_test/flutter_test.dart';
import 'package:sheet_clone/modules/tasks/stage_participant_output.dart';
import 'package:sheet_clone/modules/tasks/stage_quantity_records.dart';
import 'package:sheet_clone/modules/tasks/task_model.dart';

int _seq = 0;

/// Текст рассчитанной сервером доли — как его пишет
/// `recompute_task_quantity_shares`.
String share(num qty) => '{"actual":$qty,"generated":true}';

TaskComment comment(String type, String userId, [String text = '', int? at]) =>
    TaskComment(
      id: 'c${_seq++}',
      type: type,
      text: text,
      userId: userId,
      timestamp: at ?? (1000 + _seq),
    );

/// База отсчёта — реальный epoch в миллисекундах. Мелкие числа
/// `normalizeEpochToMillis` принимает за секунды и умножает на 1000, из-за чего
/// метки комментариев и интервалов разъезжаются на три порядка.
const int _base = 1750000000000;

/// Закрытый производственный интервал — вес участника при делении отрезка.
///
/// Время пишется строкой ISO: `TaskTimeEvent.fromPayload` разбирает только
/// строку, а число молча превращает интервал в незакрытый.
String _iso(int millis) =>
    DateTime.fromMillisecondsSinceEpoch(millis, isUtc: true).toIso8601String();

TaskComment production(String userId, {required int from, required int to}) =>
    TaskComment(
      id: 'e${_seq++}',
      type: 'time_event',
      text: '{"type":"production","startTime":"${_iso(from)}",'
          '"endTime":"${_iso(to)}","subjectUserId":"$userId"}',
      userId: userId,
      timestamp: from,
    );

TaskModel task({
  List<String> assignees = const [],
  List<TaskComment> comments = const [],
}) =>
    TaskModel(
      id: 't${_seq++}',
      orderId: 'order-1',
      stageId: 'stage-1',
      assignees: assignees,
      comments: comments,
    );

void main() {
  group('одиночный режим', () {
    test('каждый исполнитель со своим количеством, итог — их сумма', () {
      final output = stageOutputForTasks([
        task(assignees: const ['a', 'b'], comments: [
          comment('quantity_done', 'a', '600'),
          comment('quantity_done', 'b', '400'),
        ]),
      ]);

      expect(output.participants.map((p) => p.userId), ['a', 'b']);
      expect(output.participants[0].qty, 600);
      expect(output.participants[1].qty, 400);
      expect(output.totalQty, 1000);
      expect(output.hasTotal, isTrue);
    });
  });

  group('совместный режим', () {
    test('доли идут людям, а тираж бригады — в итог, но не в личное', () {
      // Доли, рассчитанные сервером, помечены generated и в тираж не идут:
      // их сумма округляется вверх, и сложение с самим тиражом посчитало бы
      // этап дважды. quantity_team_total записан владельцем, но это итог
      // бригады, а не то, что владелец сделал сам.
      final output = stageOutputForTasks([
        task(assignees: const ['owner', 'helper'], comments: [
          comment('joined', 'helper'),
          comment('quantity_share', 'owner', share(700)),
          comment('quantity_share', 'helper', share(300)),
          comment('quantity_team_total', 'owner', '1000'),
        ]),
      ]);

      expect(output.participants.map((p) => p.userId), ['owner', 'helper']);
      expect(output.participants[0].qty, 700);
      expect(output.participants[1].qty, 300);
      expect(output.totalQty, 1000);
    });

    test('доля помощника не задваивает тираж', () {
      final output = stageOutputForTasks([
        task(assignees: const ['owner', 'helper'], comments: [
          comment('joined', 'helper'),
          comment('quantity_share', 'helper', share(300)),
          comment('quantity_stage_total', 'owner', '1000'),
        ]),
      ]);
      expect(output.totalQty, 1000);
      expect(output.participants[1].qty, 300);
    });
  });

  group('участники', () {
    test('удалённый из assignees помощник остаётся в списке', () {
      // Его joined никуда не девается, работа была.
      final output = stageOutputForTasks([
        task(assignees: const ['owner'], comments: [
          comment('joined', 'helper'),
          comment('quantity_share', 'helper', share(200)),
        ]),
      ]);
      expect(output.participants.map((p) => p.userId), ['owner', 'helper']);
      expect(output.participants[1].qty, 200);
    });

    test('участник без персональной записи не выпадает из списка', () {
      final output = stageOutputForTasks([
        task(assignees: const ['owner', 'helper'], comments: [
          comment('joined', 'helper'),
          comment('quantity_team_total', 'owner', '1000'),
        ]),
      ]);
      expect(output.participants.length, 2);
      expect(output.participants[1].hasQty, isFalse);
      expect(formatStageQty(output.participants[1].qty), '—');
      expect(output.totalQty, 1000);
    });

    test('владелец этапа стоит первым', () {
      final output = stageOutputForTasks([
        task(assignees: const ['owner', 'second'], comments: [
          comment('start', 'second'),
        ]),
      ]);
      expect(output.participants.first.userId, 'owner');
    });

    test('наладчик и сменщик — участники, а не посторонние', () {
      // Прежнее правило считало участником только автора start/joined/user_done.
      // Человек, сделавший наладку и ушедший на пересмену, исчезал с карточки
      // целиком — при том, что смену на этапе он отработал. Эти отметки нельзя
      // оставить, не находясь у станка, поэтому их автор — участник.
      final output = stageOutputForTasks([
        task(assignees: const ['owner'], comments: [
          comment('setup_start', 'setuper'),
          comment('problem', 'reporter'),
          comment('shift_resume', 'shifter'),
        ]),
      ]);
      expect(
        output.participants.map((p) => p.userId),
        ['owner', 'setuper', 'reporter', 'shifter'],
      );
    });
  });

  group('несколько задач этапа', () {
    test('альтернативные рабочие места складываются в один этап', () {
      final output = stageOutputForTasks([
        task(assignees: const ['a'], comments: [
          comment('quantity_done', 'a', '400'),
        ]),
        task(assignees: const ['b'], comments: [
          comment('quantity_done', 'b', '600'),
        ]),
      ]);
      expect(output.participants.map((p) => p.userId), ['a', 'b']);
      expect(output.totalQty, 1000);
    });

    test('один человек на двух задачах суммируется', () {
      final output = stageOutputForTasks([
        task(assignees: const ['a'], comments: [
          comment('quantity_done', 'a', '400'),
        ]),
        task(assignees: const ['a'], comments: [
          comment('quantity_done', 'a', '150'),
        ]),
      ]);
      expect(output.participants.single.qty, 550);
    });
  });

  group('пустые случаи', () {
    test('этап без задач', () {
      final output = stageOutputForTasks(const <TaskModel>[]);
      expect(output.participants, isEmpty);
      expect(output.hasTotal, isFalse);
    });

    test('назначены, но количество ещё не вводили', () {
      // hasTotal отличает «сделали 0» от «ещё не вводили»: ноль в первом
      // случае осмыслен, во втором его показывать нельзя.
      final output = stageOutputForTasks([
        task(assignees: const ['a'], comments: [comment('start', 'a')]),
      ]);
      expect(output.participants.single.userId, 'a');
      expect(output.participants.single.hasQty, isFalse);
      expect(output.hasTotal, isFalse);
    });
  });

  group('круг этапа', () {
    test('после возобновления прошлый круг в счёт не идёт', () {
      // Иначе перезапущенный этап показывал сумму всех кругов: 500 + 300
      // вместо 300, и «Итого» расходилось с тем, что сделали на самом деле.
      final output = stageOutputForTasks([
        task(assignees: const ['a'], comments: [
          comment('quantity_done', 'a', '500', _base + 1000),
          comment('stage_reopened', 'lead', 'Этап возобновлён', _base + 2000),
          comment('quantity_done', 'a', '300', _base + 3000),
        ]),
      ]);
      expect(output.participants.single.qty, 300);
      expect(output.totalQty, 300);
    });

    test('без возобновления считается вся история', () {
      final output = stageOutputForTasks([
        task(assignees: const ['a'], comments: [
          comment('quantity_done', 'a', '500', _base + 1000),
          comment('quantity_done', 'a', '300', _base + 3000),
        ]),
      ]);
      expect(output.participants.single.qty, 800);
    });
  });

  group('тираж отрезка делится по отработанному времени', () {
    test('пропорционально производственным интервалам', () {
      // a отработал 100 с, b — 300 с, тираж отрезка 400: 100 и 300.
      final output = stageOutputForTasks([
        task(assignees: const ['a', 'b'], comments: [
          production('a', from: _base + 10000, to: _base + 110000),
          production('b', from: _base + 10000, to: _base + 310000),
          comment('quantity_stage_total', 'a', '400', _base + 400000),
        ]),
      ]);
      expect(output.participants[0].qty, 100);
      expect(output.participants[1].qty, 300);
      expect(output.participants[0].provisional, isTrue);
      expect(output.totalQty, 400);
    });

    test('автор записи тиража больше не остаётся с прочерком', () {
      // Скриншот бригады «Автомат большой»: человек ввёл «сделано 1 шт», а в
      // строке у него стоял прочерк — тираж отрезка не доставался никому.
      final output = stageOutputForTasks([
        task(assignees: const ['a'], comments: [
          production('a', from: _base + 10000, to: _base + 110000),
          comment('quantity_stage_total', 'a', '1', _base + 200000),
        ]),
      ]);
      expect(output.participants.single.qty, 1);
      expect(formatStageQty(output.participants.single.qty), '1');
    });

    test('на станке без деления по времени каждому идёт полный тираж', () {
      // workplaces.split_quantity_by_time = false: тираж делает машина,
      // бригада её обслуживает — то же правило, что на сервере.
      final output = stageOutputForTasks(
        [
          task(assignees: const ['a', 'b'], comments: [
            production('a', from: _base + 10000, to: _base + 110000),
            production('b', from: _base + 10000, to: _base + 310000),
            comment('quantity_stage_total', 'a', '400', _base + 400000),
          ]),
        ],
        splitByTime: false,
      );
      expect(output.participants[0].qty, 400);
      expect(output.participants[1].qty, 400);
      expect(output.totalQty, 400);
    });

    test('сдавший смену не получает тираж следующего отрезка за хвост меток', () {
      // Лостовец, Флексопечать: интервал Медета закрыт на полмиллисекунды
      // позже границы отрезка, и на станке без деления ему досталось 550 м
      // смены Равиля. Хвост короче секунды участием не считается.
      final output = stageOutputForTasks(
        [
          task(assignees: const ['b'], comments: [
            production('a', from: _base + 10000, to: _base + 120500),
            comment('quantity_stage_total', 'a', '14500', _base + 120000),
            production('b', from: _base + 130000, to: _base + 230000),
            comment('quantity_stage_total', 'b', '550', _base + 240000),
          ]),
        ],
        splitByTime: false,
      );
      final byUser = {for (final p in output.participants) p.userId: p.qty};
      expect(byUser['a'], 14500);
      expect(byUser['b'], 550);
      expect(output.totalQty, 15050);
    });

    test('кусается: секунда и больше в отрезке — это участие', () {
      final output = stageOutputForTasks(
        [
          task(assignees: const ['b'], comments: [
            production('a', from: _base + 10000, to: _base + 121000),
            comment('quantity_stage_total', 'a', '14500', _base + 120000),
            production('b', from: _base + 120000, to: _base + 230000),
            comment('quantity_stage_total', 'b', '550', _base + 240000),
          ]),
        ],
        splitByTime: false,
      );
      final byUser = {for (final p in output.participants) p.userId: p.qty};
      expect(byUser['a'], 15050);
      expect(byUser['b'], 550);
    });

    test('серверные доли отменяют деление на клиенте', () {
      // Иначе выработка удвоилась бы: и доля от сервера, и своя прикидка.
      final output = stageOutputForTasks([
        task(assignees: const ['a', 'b'], comments: [
          production('a', from: _base + 10000, to: _base + 110000),
          production('b', from: _base + 10000, to: _base + 310000),
          comment('quantity_share', 'a', share(100), _base + 390000),
          comment('quantity_share', 'b', share(300), _base + 390001),
          comment('quantity_stage_total', 'a', '400', _base + 400000),
        ]),
      ]);
      expect(output.participants[0].qty, 100);
      expect(output.participants[1].qty, 300);
      expect(output.participants[0].provisional, isFalse);
      expect(output.totalQty, 400);
    });

    test('несколько отрезков считаются по отдельности', () {
      // Первый отрезок целиком a, второй целиком b — пересмена между ними.
      final output = stageOutputForTasks([
        task(assignees: const ['a', 'b'], comments: [
          production('a', from: _base + 10000, to: _base + 110000),
          comment('quantity_stage_total', 'a', '100', _base + 120000),
          production('b', from: _base + 130000, to: _base + 230000),
          comment('quantity_stage_total', 'b', '900', _base + 240000),
        ]),
      ]);
      expect(output.participants[0].qty, 100);
      expect(output.participants[1].qty, 900);
      expect(output.totalQty, 1000);
    });
  });

  group('отрезок, в котором никто не числился в работе', () {
    test('тираж достаётся автору записи, а не пропадает', () {
      // Заказ Burger king, этап «Фри»: сотрудник ушёл на срочный заказ, станок
      // встал, а выработку смены он ввёл часом позже. Производственных
      // интервалов в отрезке ноль — раньше он выбрасывался целиком, и 17 000
      // шт из 30 503 не доставались никому ни в выработке, ни в сдельной.
      final output = stageOutputForTasks([
        task(assignees: const ['a'], comments: [
          production('a', from: _base, to: _base + 3600000),
          comment(
              'quantity_stage_total', 'a', '{"actual":1000}', _base + 3600000),
          comment(
              'quantity_stage_total', 'b', '{"actual":17000}', _base + 7200000),
        ]),
      ]);

      expect(output.totalQty, 18000);
      expect(
        {for (final p in output.participants) p.userId: p.qty},
        {'a': 1000.0, 'b': 17000.0},
      );
    });

    test('кусается: покрытый отрезок по-прежнему делится по времени', () {
      // Иначе «отдать автору» подменило бы собой всё деление и забирало тираж
      // там, где бригада работала вдвоём.
      final output = stageOutputForTasks([
        task(assignees: const ['a', 'b'], comments: [
          production('a', from: _base, to: _base + 3600000),
          production('b', from: _base, to: _base + 3600000),
          comment(
              'quantity_stage_total', 'a', '{"actual":1000}', _base + 3600000),
        ]),
      ]);

      expect(
        {for (final p in output.participants) p.userId: p.qty},
        {'a': 500.0, 'b': 500.0},
      );
    });

    test('запись без автора не ломает этап', () {
      final output = stageOutputForTasks([
        task(assignees: const ['a'], comments: [
          production('a', from: _base, to: _base + 3600000),
          comment(
              'quantity_stage_total', 'a', '{"actual":1000}', _base + 3600000),
          comment(
              'quantity_stage_total', '', '{"actual":5000}', _base + 7200000),
        ]),
      ]);

      // В тираже этапа запись остаётся — теряется только адресат.
      expect(output.totalQty, 6000);
      expect(output.participants.single.userId, 'a');
      expect(output.participants.single.qty, 1000);
    });
  });

  group('упаковка: штуки против упаковок', () {
    // Реальная запись упаковщика: сотруднику засчитываются упаковки, а из
    // тиража заказа сделаны ШТУКИ. Пока парсер был один, этап на 4878 штук из
    // 5000 показывался как «49 из 5000» и горел красным «недодали −99 %».
    String packRecord(num pieces, int packs) =>
        '{"actual":$pieces.0,"unit":"шт","expected":5000.0,'
        '"display":"$pieces шт · $packs уп","packs":$packs,"pack_size":100.0}';

    test('тираж этапа считается в штуках, а не в упаковках', () {
      final output = stageOutputForTasks([
        task(assignees: const ['a', 'b'], comments: [
          comment('quantity_done', 'a', packRecord(1700, 17)),
          comment('quantity_done', 'b', packRecord(3178, 32)),
        ]),
      ]);
      expect(output.totalQty, 4878);
      expect(output.participants[0].qty, 1700);
      expect(output.participants[1].qty, 3178);
    });

    test('запись без actual — старый формат, читаем упаковки', () {
      final output = stageOutputForTasks([
        task(assignees: const ['a'], comments: [
          comment('quantity_done', 'a', '{"packs":17,"display":"17 уп"}'),
        ]),
      ]);
      expect(output.participants.single.qty, 17);
    });

    test('сдельный парсер по-прежнему отдаёт упаковки', () {
      // Коэффициент рабочего места задан за упаковку: подмена штуками
      // умножила бы выплату на фасовку.
      expect(parseStageQuantityText(packRecord(1700, 17)), 17);
      expect(parseStageQuantityActual(packRecord(1700, 17)), 1700);
    });
  });

  group('formatStageQty', () {
    test('целое без хвоста', () => expect(formatStageQty(1000), '1000'));
    test('дробное сохраняется', () => expect(formatStageQty(12.5), '12.5'));
    test('нет значения — прочерк', () => expect(formatStageQty(null), '—'));
  });
}
