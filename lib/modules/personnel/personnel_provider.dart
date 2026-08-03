// lib/modules/personnel/personnel_provider.dart
import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' show ClientException;
import 'package:uuid/uuid.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../services/doc_db.dart';
import '../../services/personnel_db.dart';
import '../../utils/auth_helper.dart';
import 'personnel_constants.dart';
import 'position_model.dart';
import 'employee_model.dart';
import 'employee_status_model.dart';
import 'employee_status_repository.dart';
import 'workplace_model.dart';
import 'terminal_model.dart';

const Set<String> _protectedWorkplaceIds = {
  'w_bobiner',
  'w_flexoprint',
  '0571c01c-f086-47e4-81b2-5d8b2ab91218',
  'b92a89d1-8e95-4c6d-b990-e308486e4bf1',
};

class PersonnelProvider extends ChangeNotifier {
  PersonnelProvider({PersonnelDB? db, DocDB? docDb, bool bootstrap = true})
      : _db = db ?? PersonnelDB(),
        _docDb = docDb {
    if (bootstrap) _bootstrap();
  }

  final _uuid = const Uuid();
  final PersonnelDB _db;
  final DocDB? _docDb;
  // late: конструктор репозитория трогает Supabase.instance — при
  // bootstrap: false (тесты) инициализация не должна происходить.
  late final EmployeeStatusRepository _statusRepo = EmployeeStatusRepository();

  final List<EmployeeModel> _employees = <EmployeeModel>[];
  final List<PositionModel> _positions = <PositionModel>[];
  final List<WorkplaceModel> _workplaces = <WorkplaceModel>[];
  final List<TerminalModel> _terminals = <TerminalModel>[];
  final List<EmployeeStatus> _statuses = <EmployeeStatus>[];
  Map<String, String> _employeeStatusIds = <String, String>{};

  // --- realtime channels ---
  RealtimeChannel? _empChan;
  RealtimeChannel? _posChan;
  RealtimeChannel? _wpPosChan;
  RealtimeChannel? _workplacesChan; // единственное объявление
  RealtimeChannel? _statusChan;
  RealtimeChannel? _statusHistoryChan;

  bool _disposed = false;
  void _safeNotify() {
    if (!_disposed) notifyListeners();
  }

  // ---------- getters ----------
  List<EmployeeModel> get employees => List.unmodifiable(_employees);
  List<PositionModel> get positions => List.unmodifiable(_positions);
  List<WorkplaceModel> get workplaces => List.unmodifiable(_workplaces);
  List<TerminalModel> get terminals => List.unmodifiable(_terminals);
  List<EmployeeStatus> get statuses => List.unmodifiable(_statuses);
  /// employeeId -> statusId для ТЕКУЩИХ (открытых) периодов.
  Map<String, String> get employeeStatusIds =>
      Map.unmodifiable(_employeeStatusIds);

  // Позиции для выбора на экранах (при желании исключаем фиксированные)
  List<PositionModel> get regularPositions => _positions
      .where((p) =>
          p.id != kManagerId &&
          p.id != kWarehouseHeadId &&
          p.id != kTechLeaderId &&
          p.id != kCmmSpecialistId)
      .toList(growable: false);

  String _genId() => _uuid.v4();

  // ---------- lifecycle ----------
  Future<void> _bootstrap() async {
    await _loadPositionsFromSql();
    await _loadEmployeesFromSql();
    await _loadWorkplacesFromSql();
    await _loadTerminalsFromSql();
    await _loadStatusesFromSql();

    _listenToEmployees();
    _listenToPositions();
    _listenToWorkplacePositions();
    _listenToWorkplaces(); // подписка на изменения в таблице рабочих мест
    _listenToStatuses();
    _listenToStatusHistory();
  }

  @override
  void dispose() {
    _disposed = true;
    try {
      _empChan?.unsubscribe();
    } catch (_) {}
    try {
      _posChan?.unsubscribe();
    } catch (_) {}
    try {
      _wpPosChan?.unsubscribe();
    } catch (_) {}
    try {
      _workplacesChan?.unsubscribe();
    } catch (_) {}
    try {
      _statusChan?.unsubscribe();
    } catch (_) {}
    try {
      _statusHistoryChan?.unsubscribe();
    } catch (_) {}
    super.dispose();
  }

  // ---------- public refreshers -----------
  Future<void> fetchEmployees() => _loadEmployeesFromSql();
  Future<void> fetchPositions() => _loadPositionsFromSql();
  Future<void> fetchWorkplaces() => _loadWorkplacesFromSql();
  Future<void> fetchTerminals() => _loadTerminalsFromSql();
  Future<void> fetchStatuses() => _loadStatusesFromSql();

  // ---------- loaders -----------
  Future<void> _loadPositionsFromSql() async {
    try {
      final rows = await _db.listPositions();
      _positions
        ..clear()
        ..addAll(rows.map((r) => PositionModel.fromMap(r, r['id'].toString())));
      _safeNotify();
    } on ClientException catch (e, st) {
      debugPrint('Positions load failed: $e');
      debugPrintStack(stackTrace: st);
    } catch (e, st) {
      debugPrint('Unexpected positions load error: $e');
      debugPrintStack(stackTrace: st);
    }
  }

  Future<void> _loadEmployeesFromSql() async {
    try {
      final rows = await _db.listEmployeesView();
      _employees
        ..clear()
        ..addAll(rows.map((r) => EmployeeModel(
              id: r['id'],
              lastName: r['last_name'] ?? '',
              firstName: r['first_name'] ?? '',
              patronymic: r['patronymic'] ?? '',
              iin: r['iin'] ?? '',
              photoUrl: r['photo_url'],
              positionIds: List<String>.from(r['position_ids'] ?? const []),
              isFired: (r['is_fired'] as bool?) ?? false,
              comments: r['comments'] ?? '',
              login: r['login'] ?? '',
              password: r['password'] ?? '',
              baseDaySalary:
                  (r['base_day_salary'] as num?)?.toDouble() ?? 0,
            )));
      _safeNotify();
    } on ClientException catch (e, st) {
      debugPrint('Employees load failed: $e');
      debugPrintStack(stackTrace: st);
    } catch (e, st) {
      debugPrint('Unexpected employees load error: $e');
      debugPrintStack(stackTrace: st);
    }
  }

  Future<void> _loadWorkplacesFromSql() async {
    try {
      final rows = await _db.listWorkplacesView();
      _workplaces
        ..clear()
        ..addAll(rows.map((r) => WorkplaceModel.fromMap({
              'name': r['name'],
              'title': r['title'],
              'short_name': r['short_name'],
              'code': r['code'],
              'positionIds': r['position_ids'] ?? const [],
              'has_machine': r['has_machine'],
              'max_concurrent_workers': r['max_concurrent_workers'],
              'unit': r['unit'],
              'execution_mode': r['execution_mode'],
              'priladka_calc_mode': r['priladka_calc_mode'],
              'priladka_price': r['priladka_price'],
            }, r['id'])));
      _safeNotify();
    } on ClientException catch (e, st) {
      debugPrint('Workplaces load failed: $e');
      debugPrintStack(stackTrace: st);
    } catch (e, st) {
      debugPrint('Unexpected workplaces load error: $e');
      debugPrintStack(stackTrace: st);
    }
  }

  Future<void> _loadTerminalsFromSql() async {
    try {
      final rows = await _db.listTerminalsView();
      _terminals
        ..clear()
        ..addAll(rows.map((r) => TerminalModel.fromMap({
              'name': r['name'],
              'workplaceIds': r['workplace_ids'] ?? const [],
            }, r['id'])));
      _safeNotify();
    } on ClientException catch (e, st) {
      debugPrint('Terminals load failed: $e');
      debugPrintStack(stackTrace: st);
    } catch (e, st) {
      debugPrint('Unexpected terminals load error: $e');
      debugPrintStack(stackTrace: st);
    }
  }

  Future<void> _loadStatusesFromSql() async {
    try {
      final statuses = await _statusRepo.listAll();
      final currentIds = await _statusRepo.loadCurrentStatusIds();
      _statuses
        ..clear()
        ..addAll(statuses);
      _employeeStatusIds = currentIds;
      _safeNotify();
    } on ClientException catch (e, st) {
      debugPrint('Statuses load failed: $e');
      debugPrintStack(stackTrace: st);
    } catch (e, st) {
      debugPrint('Unexpected statuses load error: $e');
      debugPrintStack(stackTrace: st);
    }
  }

  // ---------- positions CRUD -----------
  Future<void> addPosition(String name,
      {String? id, String? description}) async {
    final pid = id ?? _genId();
    await _db.insertPosition(
        id: pid, name: name.trim(), description: description);
    await _loadPositionsFromSql();
  }

  Future<void> updatePosition(
      {required String id, required String name, String? description}) async {
    await _db.updatePosition(
        id: id, name: name.trim(), description: description);
    await _loadPositionsFromSql();
  }

  Future<void> deletePosition(String id) async {
    await _db.deletePosition(id);
    await _loadPositionsFromSql();
  }

  // ---------- employees CRUD -----------
  /// Возвращает id созданного сотрудника (нужен вызывающему коду, чтобы
  /// сразу присвоить статус — assignEmployeeStatus требует employeeId).
  Future<String> addEmployee({
    required String lastName,
    required String firstName,
    required String patronymic,
    required String iin,
    String? photoUrl,
    required List<String> positionIds,
    bool isFired = false,
    String comments = '',
    String login = '',
    String password = '',
  }) async {
    final id = _genId();
    await _db.insertEmployee(
      id: id,
      lastName: lastName.trim(),
      firstName: firstName.trim(),
      patronymic: patronymic.trim(),
      iin: iin.trim(),
      photoUrl: photoUrl,
      positionIds: positionIds,
      isFired: isFired,
      comments: comments,
      login: login.trim(),
      password: password.trim(),
    );
    await _loadEmployeesFromSql();
    return id;
  }

  Future<void> updateEmployee({
    required String id,
    String? lastName,
    String? firstName,
    String? patronymic,
    String? iin,
    String? photoUrl,
    List<String>? positionIds,
    bool? isFired,
    String? comments,
    String? login,
    String? password,
  }) async {
    await _db.updateEmployee(
      id: id,
      lastName: lastName,
      firstName: firstName,
      patronymic: patronymic,
      iin: iin,
      photoUrl: photoUrl,
      isFired: isFired,
      comments: comments,
      login: login,
      password: password,
      positionIds: positionIds,
    );
    await _loadEmployeesFromSql();
  }

  // ---------- statuses CRUD -----------
  void _assertTechLeader() {
    if (!AuthHelper.isTechLeader) {
      throw StateError('Управлять статусами может только технический лидер.');
    }
  }

  Future<void> addStatus(String name, {String? description}) async {
    _assertTechLeader();
    await _statusRepo.create(name: name.trim(), description: description);
    await _loadStatusesFromSql();
  }

  Future<void> updateStatus(
      {required String id, required String name, String? description}) async {
    _assertTechLeader();
    await _statusRepo.update(id: id, name: name.trim(), description: description);
    await _loadStatusesFromSql();
  }

  Future<void> deleteStatus(String id) async {
    _assertTechLeader();
    await _statusRepo.delete(id);
    await _loadStatusesFromSql();
  }

  /// Присваивает [statusId] сотруднику или снимает статус (statusId == null),
  /// с сохранением истории (см. EmployeeStatusRepository.assignStatus).
  Future<void> assignEmployeeStatus({
    required String employeeId,
    required String? statusId,
  }) async {
    _assertTechLeader();
    await _statusRepo.assignStatus(employeeId: employeeId, statusId: statusId);
    await _loadStatusesFromSql();
  }

  String? currentStatusIdFor(String employeeId) => _employeeStatusIds[employeeId];

  // ---------- workplaces CRUD -----------
  Future<void> addWorkplace({
    required String name,
    String? description,
    bool hasMachine = false,
    int maxConcurrentWorkers = 0,
    List<String> positionIds = const [],
    String? unit,
    WorkplaceExecutionMode executionMode = WorkplaceExecutionMode.joint,
    PriladkaCalcMode? priladkaCalcMode,
    double priladkaPrice = 0,
  }) async {
    final id = _genId();
    // В тестах можем использовать DocDB как заглушку, чтобы не дергать Supabase.
    if (_docDb != null) {
      final workplace = WorkplaceModel(
        id: id,
        name: name.trim(),
        description: description,
        hasMachine: hasMachine,
        maxConcurrentWorkers: maxConcurrentWorkers,
        positionIds: positionIds,
        unit: unit,
        executionMode: executionMode,
        priladkaCalcMode: priladkaCalcMode,
        priladkaPrice: priladkaPrice,
      );

      await _docDb!.insert('workplaces', workplace.toMap(), explicitId: id);
      _workplaces.add(workplace);
      _safeNotify();
    } else {
      await _db.insertWorkplace(
        id: id,
        name: name.trim(),
        description: description,
        hasMachine: hasMachine,
        maxConcurrentWorkers: maxConcurrentWorkers,
        positionIds: positionIds,
        unit: unit,
        executionMode: executionMode,
        priladkaCalcMode: priladkaCalcMode,
        priladkaPrice: priladkaPrice,
      );
      await _loadWorkplacesFromSql();
    }
  }

  Future<void> updateWorkplace({
    required String id,
    required String name,
    String? description,
    bool? hasMachine,
    int? maxConcurrentWorkers,
    List<String>? positionIds,
    String? unit,
    WorkplaceExecutionMode? executionMode,
    bool setPriladkaCalcMode = false,
    PriladkaCalcMode? priladkaCalcMode,
    double? priladkaPrice,
  }) async {
    await _db.updateWorkplace(
      id: id,
      name: name.trim(),
      description: description,
      hasMachine: hasMachine,
      maxConcurrentWorkers: maxConcurrentWorkers,
      positionIds: positionIds,
      unit: unit,
      executionMode: executionMode,
      setPriladkaCalcMode: setPriladkaCalcMode,
      priladkaCalcMode: priladkaCalcMode,
      priladkaPrice: priladkaPrice,
    );
    await _loadWorkplacesFromSql();
  }

  /// Обновляет только цену за приладку рабочего места (правится из
  /// настроек аналитики). Прав доступа здесь не проверяем — вызывающий
  /// AnalyticsService уже гейтит по canEdit. Локальную модель патчим на
  /// месте: метод дёргается на каждый ввод символа, полная перезагрузка
  /// списка рабочих мест здесь избыточна.
  Future<void> setWorkplacePriladkaPrice({
    required String id,
    required double price,
  }) async {
    await _db.updateWorkplace(id: id, priladkaPrice: price);
    final idx = _workplaces.indexWhere((w) => w.id == id);
    if (idx != -1) {
      final w = _workplaces[idx];
      _workplaces[idx] = WorkplaceModel(
        id: w.id,
        name: w.name,
        description: w.description,
        positionIds: w.positionIds,
        hasMachine: w.hasMachine,
        maxConcurrentWorkers: w.maxConcurrentWorkers,
        unit: w.unit,
        executionMode: w.executionMode,
        priladkaCalcMode: w.priladkaCalcMode,
        priladkaPrice: price,
      );
      _safeNotify();
    }
  }

  Future<void> deleteWorkplace(String id) async {
    if (_protectedWorkplaceIds.contains(id)) {
      throw StateError('Это рабочее место защищено от удаления');
    }
    await _db.deleteWorkplace(id);
    await _loadWorkplacesFromSql();
  }

  // ---------- terminals CRUD -----------
  Future<void> addTerminal({
    required String name,
    String? description,
    List<String> workplaceIds = const [],
  }) async {
    final id = _genId();
    await _db.insertTerminal(
      id: id,
      name: name.trim(),
      description: description,
      workplaceIds: workplaceIds,
    );
    await _loadTerminalsFromSql();
  }

  Future<void> updateTerminal({
    required String id,
    String? name,
    String? description,
    List<String>? workplaceIds,
  }) async {
    await _db.updateTerminal(
      id: id,
      name: name?.trim(),
      description: description,
      workplaceIds: workplaceIds,
    );
    await _loadTerminalsFromSql();
  }

  Future<void> deleteTerminal(String id) async {
    await _db.deleteTerminal(id);
    await _loadTerminalsFromSql();
  }

  // ---------- helpers for UI -----------
  String positionNameById(String id) {
    try {
      return _positions.firstWhere((p) => p.id == id).name;
    } catch (_) {
      return id;
    }
  }

  WorkplaceModel? workplaceById(String id) {
    try {
      return _workplaces.firstWhere((w) => w.id == id);
    } catch (_) {
      return null;
    }
  }

  PositionModel? findManagerPosition() {
    try {
      return _positions.firstWhere((p) =>
          p.id == kManagerId ||
          p.name.trim().toLowerCase() == 'menedzher' ||
          p.name.trim().toLowerCase() == 'manager' ||
          p.name.trim().toLowerCase() == 'menedjer');
    } catch (_) {
      return null;
    }
  }

  PositionModel? findWarehouseHeadPosition() {
    try {
      return _positions.firstWhere((p) => p.id == kWarehouseHeadId);
    } catch (_) {
      return null;
    }
  }

  PositionModel? findTechLeaderPosition() {
    try {
      return _positions.firstWhere((p) => p.id == kTechLeaderId);
    } catch (_) {
      return null;
    }
  }

  PositionModel? findCmmSpecialistPosition() {
    try {
      return _positions.firstWhere((p) => p.id == kCmmSpecialistId);
    } catch (_) {
      return null;
    }
  }

  Future<void> ensureManagerPosition() async {
    await _ensurePosition(id: kManagerId, name: 'Manager');
  }

  Future<void> ensureWarehouseHeadPosition() async {
    await _ensurePosition(id: kWarehouseHeadId, name: 'Warehouse Head');
  }

  Future<void> ensureCmmSpecialistPosition() async {
    await _ensurePosition(id: kCmmSpecialistId, name: 'CMM специалист');
  }

  Future<void> _ensurePosition({required String id, required String name}) async {
    if (_positions.any((p) => p.id == id)) return;
    try {
      await _db.insertPosition(id: id, name: name);
    } on PostgrestException catch (e) {
      if (e.code != '23505') rethrow;
      // Another client/session has already inserted this fixed position.
    }
    await _loadPositionsFromSql();
  }

  // ---------- realtime ----------
  void _listenToEmployees() {
    try {
      _empChan = Supabase.instance.client
          .channel('realtime:employees')
          .onPostgresChanges(
            event: PostgresChangeEvent.all,
            schema: 'public',
            table: 'employees',
            callback: (payload) => fetchEmployees(),
          )
          .subscribe();
    } catch (_) {}
  }

  void _listenToPositions() {
    try {
      _posChan = Supabase.instance.client
          .channel('realtime:positions')
          .onPostgresChanges(
            event: PostgresChangeEvent.all,
            schema: 'public',
            table: 'positions',
            callback: (payload) => fetchPositions(),
          )
          .subscribe();
    } catch (_) {}
  }

  void _listenToWorkplacePositions() {
    try {
      _wpPosChan = Supabase.instance.client
          .channel('realtime:workplace_positions')
          .onPostgresChanges(
            event: PostgresChangeEvent.all,
            schema: 'public',
            table: 'workplace_positions',
            callback: (payload) => fetchWorkplaces(),
          )
          .subscribe();
    } catch (_) {}
  }

  void _listenToWorkplaces() {
    try {
      _workplacesChan = Supabase.instance.client
          .channel('realtime:workplaces')
          .onPostgresChanges(
            event: PostgresChangeEvent.all,
            schema: 'public',
            table: 'workplaces',
            callback: (payload) => fetchWorkplaces(),
          )
          .subscribe();
    } catch (_) {}
  }

  void _listenToStatuses() {
    try {
      _statusChan = Supabase.instance.client
          .channel('realtime:employee_statuses')
          .onPostgresChanges(
            event: PostgresChangeEvent.all,
            schema: 'public',
            table: 'employee_statuses',
            callback: (payload) => fetchStatuses(),
          )
          .subscribe();
    } catch (_) {}
  }

  void _listenToStatusHistory() {
    try {
      _statusHistoryChan = Supabase.instance.client
          .channel('realtime:employee_status_history')
          .onPostgresChanges(
            event: PostgresChangeEvent.all,
            schema: 'public',
            table: 'employee_status_history',
            callback: (payload) => fetchStatuses(),
          )
          .subscribe();
    } catch (_) {}
  }
}