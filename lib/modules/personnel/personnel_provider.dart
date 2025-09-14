import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';

import '../../services/doc_db.dart';
import 'personnel_constants.dart'; // kManagerId, kWarehouseHeadId
import 'position_model.dart';
import 'employee_model.dart';
import 'workplace_model.dart';
import 'terminal_model.dart';

/// Провайдер персонала, работающий через коллекции в `documents`:
/// employees / positions / workplaces / terminals
class PersonnelProvider extends ChangeNotifier {
  PersonnelProvider() {
    // Инициализация: загружаем данные и подписываемся на realtime.
    _bootstrap();
  }

  final _uuid = const Uuid();
  final DocDB _db = DocDB();

  // локальные кэши под UI — заполняются из documents
  final List<EmployeeModel> _employees = [];
  final List<PositionModel> _positions = [];
  final List<WorkplaceModel> _workplaces = [];
  final List<TerminalModel> _terminals = [];

  // realtime канал (dynamic — для совместимости с разными SDK)
  dynamic _empChan;

  // getters для UI
  List<EmployeeModel> get employees => List.unmodifiable(_employees);
  List<PositionModel> get positions => List.unmodifiable(_positions);
  List<WorkplaceModel> get workplaces => List.unmodifiable(_workplaces);
  List<TerminalModel> get terminals => List.unmodifiable(_terminals);

  /// Должности, исключая специальных (менеджер, зав. складом),
  /// используются в выборах, где эти роли недоступны.
  List<PositionModel> get regularPositions {
    return _positions
        .where((p) {
          final name = p.name.toLowerCase().trim();
          return name != 'менеджер' && name != 'заведующий складом';
        })
        .toList(growable: false);
  }

  Future<void> _bootstrap() async {
    // Последовательность загрузки:
    // 1) Загружаем должности
    await _loadPositionsFromDocuments();
    // 2) Гарантируем наличие обязательных ролей в базе
    await ensureManagerPosition();
    await ensureWarehouseHeadPosition();
    // 3) Если были добавлены новые должности — перечитываем список
    await _loadPositionsFromDocuments();
    // 4) Загружаем сотрудников, рабочие места и терминалы
    await _loadEmployeesFromDocuments();
    await _loadWorkplacesFromDocuments();
    await _loadTerminalsFromDocuments();
    // 5) Подписываемся на realtime сотрудников
    _listenToEmployees();
  }

  String _genId() => _uuid.v4();

  // -------------------- Загрузка --------------------

  Future<void> _loadAllFromDocuments() async {
    // Метод оставлен для обратной совместимости.
    // Используем последовательную загрузку, аналогичную _bootstrap().
    await _loadPositionsFromDocuments();
    await ensureManagerPosition();
    await ensureWarehouseHeadPosition();
    await _loadPositionsFromDocuments();
    await _loadEmployeesFromDocuments();
    await _loadWorkplacesFromDocuments();
    await _loadTerminalsFromDocuments();
  }

  Future<void> _loadEmployeesFromDocuments() async {
    try {
      final rows = await _db.list('employees');
      _employees
        ..clear()
        ..addAll(rows.map((r) {
          final data = (r['data'] as Map).cast<String, dynamic>();
          final id = (r['id'] as String?) ?? (data['id'] as String?) ?? _genId();
          return EmployeeModel.fromJson(data, id);
        }));
      notifyListeners();
    } catch (e) {
      debugPrint('❌ load employees failed: $e');
    }
  }

  // Если login_screen вызывает fetchEmployees() — оставим обёртку
  Future<void> fetchEmployees() => _loadEmployeesFromDocuments();

  Future<void> _loadPositionsFromDocuments() async {
    try {
      final rows = await _db.list('positions');
      _positions
        ..removeWhere((p) => true)
        ..addAll(rows.map((r) {
          final m = (r['data'] as Map).cast<String, dynamic>();
          final id = (r['id'] as String?) ?? (m['id'] as String?) ?? _genId();
          return PositionModel(id: id, name: (m['name'] ?? '').toString());
        }));
      notifyListeners();
    } catch (e) {
      debugPrint('❌ load positions failed: $e');
    }
  }

  Future<void> _loadWorkplacesFromDocuments() async {
    try {
      final rows = await _db.list('workplaces');
      _workplaces
        ..removeWhere((w) => true)
        ..addAll(rows.map((r) {
          final m = (r['data'] as Map).cast<String, dynamic>();
          final id = (r['id'] as String?) ?? (m['id'] as String?) ?? _genId();
          return WorkplaceModel(
            id: id,
            name: (m['name'] ?? '').toString(),
            positionIds: (m['positionIds'] as List?)?.cast<String>() ?? [],
            hasMachine: (m['has_machine'] as bool?) ?? false,
            maxConcurrentWorkers: (m['max_concurrent_workers'] as int?) ?? 1,
          );
        }));
      notifyListeners();
    } catch (e) {
      debugPrint('❌ load workplaces failed: $e');
    }
  }

  Future<void> _loadTerminalsFromDocuments() async {
    try {
      final rows = await _db.list('terminals');
      _terminals
        ..removeWhere((t) => true)
        ..addAll(rows.map((r) {
          final m = (r['data'] as Map).cast<String, dynamic>();
          final id = (r['id'] as String?) ?? (m['id'] as String?) ?? _genId();
          return TerminalModel(
            id: id,
            name: (m['name'] ?? '').toString(),
            workplaceIds: (m['workplaceIds'] as List?)?.cast<String>() ?? [],
          );
        }));
      notifyListeners();
    } catch (e) {
      debugPrint('❌ load terminals failed: $e');
    }
  }

  // -------------------- Realtime --------------------

  void _listenToEmployees() {
    try { _empChan?.unsubscribe(); } catch (_) {}
    _empChan = _db.listenCollection('employees', (row, event) async {
      await _loadEmployeesFromDocuments();
    });
  }

  // -------------------- Helpers --------------------

  String positionNameById(String? id) {
    if (id == null || id.isEmpty) return '';
    try {
      return _positions.firstWhere((p) => p.id == id).name;
    } catch (_) {
      return '';
    }
  }

  // -------------------- Employees --------------------

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
    final employee = EmployeeModel(
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

    _employees.add(employee);
    notifyListeners();

    try {
      // сохраняем данные сотрудника в коллекции employees
      await _db.insert('employees', {
        ...employee.toJson(),
        'id': id,
      }, explicitId: id);
    } catch (e) {
      _employees.removeWhere((x) => x.id == id);
      notifyListeners();
      rethrow;
    }
  }

  Future<void> updateEmployee({
    required String id,
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
    final index = _employees.indexWhere((e) => e.id == id);
    if (index == -1) return;

    final prev = _employees[index];
    final updated = EmployeeModel(
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
    _employees[index] = updated;
    notifyListeners();

    try {
      await _db.updateById(id, {
        ...updated.toJson()..remove('id'),
      });
    } catch (e) {
      _employees[index] = prev;
      notifyListeners();
      rethrow;
    }
  }

  // -------------------- Positions --------------------

  Future<void> addPosition(String name) async {
    final id = _genId();
    final model = PositionModel(id: id, name: name.trim());
    _positions.add(model);
    notifyListeners();
    try {
      await _db.insert('positions', {
        'id': id,
        'name': model.name,
      }, explicitId: id);
    } catch (e) {
      _positions.removeWhere((p) => p.id == id);
      notifyListeners();
      rethrow;
    }
  }

  Future<void> updatePosition({
    required String id,
    required String name,
    String? description,
  }) async {
    try {
      await _db.patchById(id, {
        'name': name.trim(),
        'description': (description ?? '').trim().isEmpty ? null : description!.trim(),
      });
      final i = _positions.indexWhere((p) => p.id == id);
      if (i != -1) _positions[i] = PositionModel(id: id, name: name.trim());
      notifyListeners();
    } catch (e) {
      rethrow;
    }
  }

  Future<void> deletePosition(String id) async {
    try {
      await _db.deleteById(id);
      _positions.removeWhere((p) => p.id == id);
      notifyListeners();
    } catch (e) {
      rethrow;
    }
  }

  // -------------------- Workplaces --------------------

  void addWorkplace({
    required String name,
    required List<String> positionIds,
    bool hasMachine = false,
    int maxConcurrentWorkers = 1,
  }) {
    final id = _genId();
    _workplaces.add(WorkplaceModel(
      id: id,
      name: name.trim(),
      positionIds: positionIds,
      hasMachine: hasMachine,
      maxConcurrentWorkers: maxConcurrentWorkers,
    ));
    notifyListeners();

    unawaited(_db.insert('workplaces', {
      'id': id,
      'name': name.trim(),
      'positionIds': positionIds,
      'has_machine': hasMachine,
      'max_concurrent_workers': maxConcurrentWorkers,
    }, explicitId: id));
  }

  Future<void> updateWorkplace({
    required String id,
    required String name,
    String? description,
    bool? hasMachine,
    int? maxConcurrentWorkers,
    List<String>? positionIds,
  }) async {
    final updateData = <String, dynamic>{
      'name': name.trim(),
      'description': (description ?? '').trim().isEmpty ? null : description!.trim(),
    };
    if (hasMachine != null) updateData['has_machine'] = hasMachine;
    if (maxConcurrentWorkers != null) {
      updateData['max_concurrent_workers'] = maxConcurrentWorkers;
    }
    if (positionIds != null) updateData['positionIds'] = positionIds;

    try {
      await _db.patchById(id, updateData);

      final i = _workplaces.indexWhere((w) => w.id == id);
      if (i != -1) {
        final old = _workplaces[i];
        _workplaces[i] = WorkplaceModel(
          id: id,
          name: name.trim(),
          positionIds: positionIds ?? old.positionIds,
          hasMachine: hasMachine ?? old.hasMachine,
          maxConcurrentWorkers: maxConcurrentWorkers ?? old.maxConcurrentWorkers,
        );
      }
      notifyListeners();
    } catch (e) {
      rethrow;
    }
  }

  Future<void> deleteWorkplace(String id) async {
    try {
      await _db.deleteById(id);
      _workplaces.removeWhere((w) => w.id == id);
      notifyListeners();
    } catch (e) {
      rethrow;
    }
  }

  // -------------------- Terminals --------------------

  void addTerminal({required String name, required List<String> workplaceIds}) {
    final id = _genId();
    _terminals.add(TerminalModel(id: id, name: name.trim(), workplaceIds: workplaceIds));
    notifyListeners();

    unawaited(_db.insert('terminals', {
      'id': id,
      'name': name.trim(),
      'workplaceIds': workplaceIds,
      // created_at/updated_at автоматически поставит БД
    }, explicitId: id));
  }

  @override
  void dispose() {
    try {
      try { _empChan?.unsubscribe(); } catch (_) {}
    } catch (_) {}
    super.dispose();
  }

  // -------- ensure* позиции (локально + мягкая синхронизация в documents) --------

  Future<void> ensureManagerPosition() async {
    // Проверяем наличие должности «Менеджер» в БД; если отсутствует — добавляем.
    try {
      final exists = (await _db.whereEq('positions', 'name', 'Менеджер')).isNotEmpty;
      if (!exists) {
        await _db.insert('positions', {
          'name': 'Менеджер',
          'description': 'Управление заказами и чат менеджеров',
          'code': kManagerId,
        });
      }
    } catch (_) {
      // Игнорируем ошибки — загрузка продолжится
    }
  }

  Future<void> ensureWarehouseHeadPosition() async {
    try {
      final exists =
          (await _db.whereEq('positions', 'name', 'Заведующий складом')).isNotEmpty;
      if (!exists) {
        await _db.insert('positions', {
          'name': 'Заведующий складом',
          'description': 'Управление складом и чат',
          'code': kWarehouseHeadId,
        });
      }
    } catch (_) {
      // игнорируем ошибки
    }
  }

  /// Поиск должности «Менеджер» среди загруженных позиций.
  PositionModel? findManagerPosition() {
    try {
      return _positions.firstWhere(
        (p) => p.name.toLowerCase().trim() == 'менеджер',
      );
    } catch (_) {
      return null;
    }
  }

  /// Поиск должности «Заведующий складом» среди загруженных позиций.
  PositionModel? findWarehouseHeadPosition() {
    try {
      return _positions.firstWhere(
        (p) => p.name.toLowerCase().trim() == 'заведующий складом',
      );
    } catch (_) {
      return null;
    }
  }
}
