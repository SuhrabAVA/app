// lib/modules/personnel/personnel_provider.dart
import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../services/personnel_db.dart';
import 'personnel_constants.dart';
import 'position_model.dart';
import 'employee_model.dart';
import 'workplace_model.dart';
import 'terminal_model.dart';

class PersonnelProvider extends ChangeNotifier {
  PersonnelProvider({PersonnelDB? db, bool bootstrap = true})
      : _db = db ?? PersonnelDB() {
    if (bootstrap) _bootstrap();
  }

  final _uuid = const Uuid();
  final PersonnelDB _db;

  final List<EmployeeModel> _employees = <EmployeeModel>[];
  final List<PositionModel> _positions = <PositionModel>[];
  final List<WorkplaceModel> _workplaces = <WorkplaceModel>[];
  final List<TerminalModel> _terminals = <TerminalModel>[];

  // --- realtime channels ---
  RealtimeChannel? _empChan;
  RealtimeChannel? _posChan;
  RealtimeChannel? _wpPosChan;
  RealtimeChannel? _workplacesChan; // единственное объявление

  bool _disposed = false;
  void _safeNotify() {
    if (!_disposed) notifyListeners();
  }

  // ---------- getters ----------
  List<EmployeeModel> get employees => List.unmodifiable(_employees);
  List<PositionModel> get positions => List.unmodifiable(_positions);
  List<WorkplaceModel> get workplaces => List.unmodifiable(_workplaces);
  List<TerminalModel> get terminals => List.unmodifiable(_terminals);

  // Позиции для выбора на экранах (при желании исключаем фиксированные)
  List<PositionModel> get regularPositions => _positions
      .where((p) =>
          p.id != kManagerId &&
          p.id != kWarehouseHeadId &&
          p.id != kTechLeaderId)
      .toList(growable: false);

  String _genId() => _uuid.v4();

  // ---------- lifecycle ----------
  Future<void> _bootstrap() async {
    await _loadPositionsFromSql();
    await _loadEmployeesFromSql();
    await _loadWorkplacesFromSql();
    await _loadTerminalsFromSql();

    _listenToEmployees();
    _listenToPositions();
    _listenToWorkplacePositions();
    _listenToWorkplaces(); // подписка на изменения в таблице рабочих мест
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
    super.dispose();
  }

  // ---------- public refreshers -----------
  Future<void> fetchEmployees() => _loadEmployeesFromSql();
  Future<void> fetchPositions() => _loadPositionsFromSql();
  Future<void> fetchWorkplaces() => _loadWorkplacesFromSql();
  Future<void> fetchTerminals() => _loadTerminalsFromSql();

  // ---------- loaders -----------
  Future<void> _loadPositionsFromSql() async {
    final rows = await _db.listPositions();
    _positions
      ..clear()
      ..addAll(rows.map((r) => PositionModel.fromMap(r, r['id'].toString())));
    _safeNotify();
  }

  Future<void> _loadEmployeesFromSql() async {
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
          )));
    _safeNotify();
  }

  Future<void> _loadWorkplacesFromSql() async {
    final rows = await _db.listWorkplacesView();
    _workplaces
      ..clear()
      ..addAll(rows.map((r) => WorkplaceModel.fromMap({
            'name': r['name'],
            'positionIds': r['position_ids'] ?? const [],
            'has_machine': r['has_machine'],
            'max_concurrent_workers': r['max_concurrent_workers'],
            'unit': r['unit'],
          }, r['id'])));
    _safeNotify();
  }

  Future<void> _loadTerminalsFromSql() async {
    final rows = await _db.listTerminalsView();
    _terminals
      ..clear()
      ..addAll(rows.map((r) => TerminalModel.fromMap({
            'name': r['name'],
            'workplaceIds': r['workplace_ids'] ?? const [],
          }, r['id'])));
    _safeNotify();
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
  Future<void> addEmployee({
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

  // ---------- workplaces CRUD -----------
  Future<void> addWorkplace({
    required String name,
    String? description,
    bool hasMachine = false,
    int maxConcurrentWorkers = 1,
    List<String> positionIds = const [],
    String? unit,
  }) async {
    final id = _genId();
    await _db.insertWorkplace(
      id: id,
      name: name.trim(),
      description: description,
      hasMachine: hasMachine,
      maxConcurrentWorkers: maxConcurrentWorkers,
      positionIds: positionIds,
      unit: unit,
    );
    await _loadWorkplacesFromSql();
  }

  Future<void> updateWorkplace({
    required String id,
    required String name,
    String? description,
    bool? hasMachine,
    int? maxConcurrentWorkers,
    List<String>? positionIds,
    String? unit,
  }) async {
    await _db.updateWorkplace(
      id: id,
      name: name.trim(),
      description: description,
      hasMachine: hasMachine,
      maxConcurrentWorkers: maxConcurrentWorkers,
      positionIds: positionIds,
      unit: unit,
    );
    await _loadWorkplacesFromSql();
  }

  Future<void> deleteWorkplace(String id) async {
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

  Future<void> ensureManagerPosition() async {
    final exists = _positions.any((p) => p.id == kManagerId);
    if (!exists) {
      await _db.insertPosition(id: kManagerId, name: 'Manager');
      await _loadPositionsFromSql();
    }
  }

  Future<void> ensureWarehouseHeadPosition() async {
    final exists = _positions.any((p) => p.id == kWarehouseHeadId);
    if (!exists) {
      await _db.insertPosition(id: kWarehouseHeadId, name: 'Warehouse Head');
      await _loadPositionsFromSql();
    }
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
}
