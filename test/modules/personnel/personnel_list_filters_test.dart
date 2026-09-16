import 'package:flutter_test/flutter_test.dart';
import 'package:sheet_clone/modules/orders/order_extra_options.dart';
import 'package:sheet_clone/modules/orders/product_type_settings.dart'
    show ProductTypeRef;
import 'package:sheet_clone/modules/personnel/employee_model.dart';
import 'package:sheet_clone/modules/personnel/employee_status_model.dart';
import 'package:sheet_clone/modules/personnel/personnel_list_filters.dart';
import 'package:sheet_clone/modules/personnel/position_model.dart';
import 'package:sheet_clone/modules/personnel/terminal_model.dart';
import 'package:sheet_clone/modules/personnel/workplace_model.dart';

EmployeeModel employee({
  String last = 'Вуколов',
  String first = 'Равиль',
  List<String> positions = const ['op'],
  String login = 'ravil',
}) =>
    EmployeeModel(
      id: 'e1',
      lastName: last,
      firstName: first,
      patronymic: '',
      iin: '900101300123',
      positionIds: positions,
      login: login,
    );

const positionNames = {'op': 'Оператор', 'pack': 'Упаковщик'};
String positionName(String id) => positionNames[id] ?? id;
String statusName(String id) => id == 'st' ? 'Стажёр' : id;

void main() {
  group('matchesSearch', () {
    test('пустой запрос пропускает всё', () {
      expect(matchesSearch('  ', ['что угодно']), isTrue);
    });

    test('каждое слово должно найтись, поля можно смешивать', () {
      expect(matchesSearch('вуколов оператор', ['Вуколов Равиль', 'Оператор']),
          isTrue);
      expect(matchesSearch('вуколов упаковщик', ['Вуколов Равиль', 'Оператор']),
          isFalse);
    });

    test('регистр, «ё» и лишние пробелы не мешают', () {
      expect(matchesSearch('  СТАЖЕР ', ['Стажёр']), isTrue);
    });

    test('пустые поля не ломают поиск', () {
      expect(matchesSearch('равиль', [null, '', 'Равиль']), isTrue);
    });
  });

  group('matchesAnyId', () {
    test('пустой выбор — любые', () {
      expect(matchesAnyId({}, const []), isTrue);
    });

    test('«не задано» отбирает только записи без значений', () {
      expect(matchesAnyId({kFilterNoneId}, const []), isTrue);
      expect(matchesAnyId({kFilterNoneId}, const ['op']), isFalse);
      expect(matchesAnyId({kFilterNoneId, 'op'}, const ['op']), isTrue);
    });

    test('достаточно одного совпадения', () {
      expect(matchesAnyId({'pack'}, const ['op', 'pack']), isTrue);
      expect(matchesAnyId({'pack'}, const ['op']), isFalse);
    });
  });

  group('Сотрудники', () {
    bool run(EmployeeListFilter f, EmployeeModel e, {String? status}) =>
        f.matches(e,
            positionName: positionName,
            statusId: status,
            statusName: statusName);

    test('поиск по ФИО, логину, ИИН, должности и статусу', () {
      final e = employee();
      expect(run(EmployeeListFilter()..query = 'равил', e), isTrue);
      expect(run(EmployeeListFilter()..query = 'ravil', e), isTrue);
      expect(run(EmployeeListFilter()..query = '900101', e), isTrue);
      expect(run(EmployeeListFilter()..query = 'оператор', e), isTrue);
      expect(run(EmployeeListFilter()..query = 'стажер', e, status: 'st'),
          isTrue);
      expect(run(EmployeeListFilter()..query = 'упаковщик', e), isFalse);
    });

    test('фильтр по должности и «без должности»', () {
      final filter = EmployeeListFilter()..positionIds.add('pack');
      expect(run(filter, employee(positions: ['op'])), isFalse);
      expect(run(filter, employee(positions: ['op', 'pack'])), isTrue);

      final none = EmployeeListFilter()..positionIds.add(kFilterNoneId);
      expect(run(none, employee(positions: [])), isTrue);
      expect(run(none, employee()), isFalse);
    });

    test('фильтр по статусу и «без статуса»', () {
      final filter = EmployeeListFilter()..statusIds.add('st');
      expect(run(filter, employee(), status: 'st'), isTrue);
      expect(run(filter, employee(), status: null), isFalse);

      final none = EmployeeListFilter()..statusIds.add(kFilterNoneId);
      expect(run(none, employee(), status: null), isTrue);
      expect(run(none, employee(), status: 'st'), isFalse);
    });

    test('сброс возвращает всё', () {
      final filter = EmployeeListFilter()
        ..query = 'x'
        ..positionIds.add('pack')
        ..statusIds.add('st');
      expect(filter.isActive, isTrue);
      filter.clear();
      expect(filter.isActive, isFalse);
      expect(run(filter, employee()), isTrue);
    });
  });

  group('Должности', () {
    final position = PositionModel(id: 'op', name: 'Оператор');

    test('без сотрудников / без рабочих мест', () {
      final unused = PositionListFilter()..hasEmployees = TriFilter.no;
      expect(unused.matches(position, employeeCount: 0, workplaceCount: 3),
          isTrue);
      expect(unused.matches(position, employeeCount: 2, workplaceCount: 3),
          isFalse);

      final linked = PositionListFilter()..hasWorkplaces = TriFilter.yes;
      expect(linked.matches(position, employeeCount: 0, workplaceCount: 0),
          isFalse);
    });

    test('поиск по названию', () {
      expect(
          (PositionListFilter()..query = 'опер')
              .matches(position, employeeCount: 0, workplaceCount: 0),
          isTrue);
    });
  });

  group('Статусы', () {
    const status =
        EmployeeStatus(id: 'st', name: 'Стажёр', description: 'Фикс. ставка');

    test('поиск по описанию и фильтр «присвоен»', () {
      expect(
          (StatusListFilter()..query = 'ставка')
              .matches(status, assignedCount: 0),
          isTrue);
      final assigned = StatusListFilter()..assigned = TriFilter.yes;
      expect(assigned.matches(status, assignedCount: 0), isFalse);
      expect(assigned.matches(status, assignedCount: 1), isTrue);
    });
  });

  group('Рабочие места', () {
    WorkplaceModel wp({
      String name = 'Флексопечать',
      bool machine = true,
      String? unit = 'м',
      WorkplaceExecutionMode mode = WorkplaceExecutionMode.joint,
      List<String> positions = const ['op'],
    }) =>
        WorkplaceModel(
          id: 'w',
          name: name,
          positionIds: positions,
          hasMachine: machine,
          unit: unit,
          executionMode: mode,
        );

    bool run(WorkplaceListFilter f, WorkplaceModel w) =>
        f.matches(w, positionName: positionName);

    test('станок, режим, единица, должность', () {
      expect(run(WorkplaceListFilter()..hasMachine = TriFilter.no, wp()),
          isFalse);
      expect(
          run(WorkplaceListFilter()..mode = WorkplaceExecutionMode.separate,
              wp()),
          isFalse);
      expect(run(WorkplaceListFilter()..units.add('шт'), wp()), isFalse);
      expect(run(WorkplaceListFilter()..units.add(kFilterNoneId), wp(unit: '')),
          isTrue);
      expect(run(WorkplaceListFilter()..positionIds.add('op'), wp()), isTrue);
    });

    test('поиск по названию и должности', () {
      expect(run(WorkplaceListFilter()..query = 'флексо оператор', wp()),
          isTrue);
    });
  });

  group('Терминалы', () {
    final terminal =
        TerminalModel(id: 't', name: 'Цех 1', workplaceIds: const ['w']);
    String workplaceName(String id) => id == 'w' ? 'Бабинорезка' : id;

    test('поиск по рабочему месту и фильтр «без рабочих мест»', () {
      expect(
          (TerminalListFilter()..query = 'бабино')
              .matches(terminal, workplaceName: workplaceName),
          isTrue);
      final none = TerminalListFilter()..workplaceIds.add(kFilterNoneId);
      expect(none.matches(terminal, workplaceName: workplaceName), isFalse);
    });
  });

  group('Типы продукта', () {
    const type = ProductTypeRef(id: 'p', title: 'В-образный пакет');

    test('поиск и черновик', () {
      expect((ProductTypeListFilter()..query = 'пакет').matches(type, draft: false),
          isTrue);
      expect(
          (ProductTypeListFilter()..hasDraft = TriFilter.yes)
              .matches(type, draft: false),
          isFalse);
    });
  });

  group('Опции заказа', () {
    const option = OrderOptionDef(
      id: 'o',
      productTypeId: 'p',
      title: 'Материал ручки',
      kind: kOrderOptionKindSelect,
      values: [
        OrderOptionValue(id: 'v1', title: 'Крафт'),
        OrderOptionValue(id: 'v2', title: 'Старый', isActive: false),
      ],
    );

    test('поиск по действующему варианту, но не по удалённому', () {
      expect((OrderOptionListFilter()..query = 'крафт').matches(option), isTrue);
      expect(
          (OrderOptionListFilter()..query = 'старый').matches(option), isFalse);
    });

    test('фильтр по виду опции', () {
      expect(
          (OrderOptionListFilter()..kinds.add(kOrderOptionKindBoolean))
              .matches(option),
          isFalse);
    });
  });
}
