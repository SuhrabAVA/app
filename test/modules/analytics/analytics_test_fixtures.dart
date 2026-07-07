import 'package:flutter/foundation.dart';
import 'package:sheet_clone/modules/analytics/models/analytics_event.dart';
import 'package:sheet_clone/modules/analytics/models/analytics_month.dart';
import 'package:sheet_clone/modules/analytics/models/employee_status.dart';
import 'package:sheet_clone/modules/analytics/services/analytics_service.dart';
import 'package:sheet_clone/modules/personnel/employee_model.dart';
import 'package:sheet_clone/modules/personnel/personnel_provider.dart';
import 'package:sheet_clone/modules/personnel/workplace_model.dart';

/// Фейковый сервис аналитики для рендер-тестов: отдаёт фиксированное
/// состояние и НЕ трогает Supabase (настоящий AnalyticsService создаёт
/// репозитории с Supabase.instance ещё в конструкторе). Прочие члены
/// интерфейса рендером не вызываются — noSuchMethod бросит, если это
/// перестанет быть правдой.
class FakeAnalyticsService extends ChangeNotifier
    implements AnalyticsService {
  FakeAnalyticsService(this._fixed);

  final AnalyticsState _fixed;

  @override
  AnalyticsState get state => _fixed;

  @override
  Future<void> loadMonth(AnalyticsMonth month) async {}

  @override
  Future<void> refresh() async {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// Фейковый провайдер персонала: только данные, без realtime и Supabase.
class FakePersonnelProvider extends ChangeNotifier
    implements PersonnelProvider {
  FakePersonnelProvider({
    required List<EmployeeModel> employees,
    required List<WorkplaceModel> workplaces,
  })  : _employees = employees,
        _workplaces = workplaces;

  final List<EmployeeModel> _employees;
  final List<WorkplaceModel> _workplaces;

  @override
  List<EmployeeModel> get employees => List.unmodifiable(_employees);

  @override
  List<WorkplaceModel> get workplaces => List.unmodifiable(_workplaces);

  @override
  WorkplaceModel? workplaceById(String id) {
    for (final w in _workplaces) {
      if (w.id == id) return w;
    }
    return null;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// Месяц mock-данных.
final mockMonth = AnalyticsMonth.fromYearMonth(2026, 6);

/// Рабочие места: wp2 — длинное название с переносом (исходный кейс
/// overflow 29px в workplaces_table).
final mockWorkplaces = <WorkplaceModel>[
  WorkplaceModel(id: 'wp1', name: 'Печать', positionIds: const [], unit: 'лист'),
  WorkplaceModel(
    id: 'wp2',
    name: 'Полуавтоматическая линия сборки гофрокоробов, второй цех (линия Б)',
    positionIds: const [],
    unit: 'коробка',
  ),
  WorkplaceModel(id: 'wp3', name: 'Ламинация', positionIds: const [], unit: 'м'),
];

/// Сотрудники: e1 работает на трёх РМ (многострочная ячейка «Рабочие места»
/// — исходный кейс overflow 11px в employees_table) и имеет статус
/// (двухстрочная sticky-ячейка); e3 — длинная фамилия.
///
/// Для Фазы D: e1 — сдельщик (payType piece, есть выработка), e2 — окладник
/// (payType salary, base_day_salary > 0).
final mockEmployees = <EmployeeModel>[
  EmployeeModel(
    id: 'e1',
    lastName: 'Иванов',
    firstName: 'Иван',
    patronymic: 'Иванович',
    iin: '000000000001',
    positionIds: const [],
  ),
  EmployeeModel(
    id: 'e2',
    lastName: 'Петров',
    firstName: 'Пётр',
    patronymic: 'Петрович',
    iin: '000000000002',
    positionIds: const [],
    baseDaySalary: 16000,
  ),
  EmployeeModel(
    id: 'e3',
    lastName: 'Длиннофамильный-Оченьдлиннофамильный',
    firstName: 'Константин',
    patronymic: 'Александрович',
    iin: '000000000003',
    positionIds: const [],
  ),
];

DateTime _d(int day, int hour, [int minute = 0]) =>
    DateTime(2026, 6, day, hour, minute);

AnalyticsEvent _event(
  String id,
  AnalyticsEventType type,
  String employeeId,
  String workplaceId,
  DateTime start,
  DateTime end, {
  double qty = 0,
  double setupQty = 0,
}) {
  return AnalyticsEvent(
    id: id,
    type: type,
    startTime: start,
    endTime: end,
    employeeId: employeeId,
    workplaceId: workplaceId,
    taskId: 'task-$id',
    orderId: 'order-$id',
    customer: 'Заказчик $id',
    qty: qty,
    setupQty: setupQty,
  );
}

/// События июня-2026: у e1 три рабочих места + паузы/проблемы/наладка,
/// у e2 ночная смена на «длинном» wp2.
final mockEvents = <AnalyticsEvent>[
  _event('ev1', AnalyticsEventType.work, 'e1', 'wp1', _d(1, 8), _d(1, 12),
      qty: 1200),
  _event('ev2', AnalyticsEventType.pause, 'e1', 'wp1', _d(1, 12), _d(1, 12, 30)),
  _event('ev3', AnalyticsEventType.work, 'e1', 'wp2', _d(1, 13), _d(1, 17),
      qty: 340),
  _event('ev4', AnalyticsEventType.problem, 'e1', 'wp2', _d(2, 9), _d(2, 9, 40)),
  _event('ev5', AnalyticsEventType.work, 'e1', 'wp3', _d(2, 10), _d(2, 14),
      qty: 800),
  _event('ev6', AnalyticsEventType.setup, 'e1', 'wp1', _d(3, 8), _d(3, 9),
      setupQty: 50),
  _event('ev7', AnalyticsEventType.work, 'e2', 'wp2', _d(1, 19), _d(1, 23),
      qty: 260),
  _event('ev8', AnalyticsEventType.pause, 'e2', 'wp2', _d(1, 23), _d(1, 23, 20)),
];

/// Готовое состояние аналитики (loading: false, без ошибок).
AnalyticsState mockState() => AnalyticsState(
      month: mockMonth,
      events: mockEvents,
      coefficients: const {'wp1': 1.5, 'wp2': 2.0, 'wp3': 1.0},
      statuses: const [EmployeeStatus(id: 's1', name: 'Стажёр')],
      employeeStatusIds: const {'e1': 's1'},
      // Фаза D: e1 — сдельщик, e2 — окладник со ставкой 16000/смена.
      employeePayTypes: const {'e1': 'piece', 'e2': 'salary'},
      employeeBaseSalaries: const {'e2': 16000},
      workplacePreviousSpeeds: const {
        'wp1': [4.2, 5.1],
        'wp2': [1.1],
      },
    );

FakeAnalyticsService mockService() => FakeAnalyticsService(mockState());

FakePersonnelProvider mockPersonnel() => FakePersonnelProvider(
      employees: mockEmployees,
      workplaces: mockWorkplaces,
    );
