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
  PersonnelProvider({DocDB? docDb, bool bootstrap = true})
      : _db = docDb ?? DocDB() {
    if (bootstrap) {
      // Инициализация: загружаем данные и подписываемся на realtime.
      _bootstrap();
    }
  }

  final _uuid = const Uuid();
  final DocDB _db;

  // локальные кэши под UI — заполняются из documents
  final List<EmployeeModel> _employees = [];
  final List<PositionModel> _positions = [];
  final List<WorkplaceModel> _workplaces = [];
  final List<TerminalModel> _terminals = [];

  // NOTE: Added default seeds for positions and workplaces. These seeds were
  // extracted from the legacy application (lib.zip) and are used to initialize
  // the Supabase "documents" collections upon first launch. They ensure that
  // all standard job positions and workplaces are available without manual
  // creation. The seeds are injected via ensureDefaultPositions() and
  // ensureDefaultWorkplaces() during bootstrapping.

  /// List of default positions taken from the old project. Each map contains
  /// an "id" and a human-readable "name". These will be inserted into the
  /// `positions` collection only if a position with the same name does not
  /// already exist.
  static const List<Map<String, String>> _defaultPositionSeeds = [
    {'id': 'bob_cutter', 'name': 'Бобинорезчик'},
    {'id': 'print', 'name': 'Печатник'},
    {'id': 'cut_sheet', 'name': 'Листорезчик'},
    {'id': 'bag_collector', 'name': 'Пакетосборщик'},
    {'id': 'cutter', 'name': 'Резчик'},
    {'id': 'bottom_gluer', 'name': 'Дносклейщик'},
    {'id': 'handle_gluer', 'name': 'Склейщик ручек'},
    {'id': 'die_cutter', 'name': 'Оператор высечки'},
    {'id': 'assembler', 'name': 'Сборщик'},
    {'id': 'rope_operator', 'name': 'Оператор веревок'},
    {'id': 'handle_operator', 'name': 'Оператор ручек'},
    {'id': 'muffin_operator', 'name': 'Оператор маффинов'},
    {'id': 'single_point_gluer', 'name': 'Склейка одной точки'},
  ];

  /// List of default workplaces taken from the old project. Each record
  /// defines an "id", a "name", and the list of position IDs allowed to
  /// work there. Additional fields `hasMachine` and `maxConcurrentWorkers`
  /// were absent in the legacy code, so defaults (false and 1) are used.
  static const List<Map<String, dynamic>> _defaultWorkplaceSeeds = [
    {'id': 'w_bobiner', 'name': 'Бобинорезка', 'positionIds': ['bob_cutter']},
    {'id': 'w_flexoprint', 'name': 'Флексопечать', 'positionIds': ['print']},
    {'id': 'w_sheet_old', 'name': 'Листорезка 1 (старая)', 'positionIds': ['cut_sheet']},
    {'id': 'w_sheet_new', 'name': 'Листорезка 2 (новая)', 'positionIds': ['cut_sheet']},
    {'id': 'w_auto_p_assembly', 'name': 'Автоматическая П-сборка', 'positionIds': ['bag_collector']},
    {'id': 'w_auto_p_pipe', 'name': 'Автоматическая П-сборка (труба)', 'positionIds': ['bag_collector']},
    {'id': 'w_auto_v1', 'name': 'Автоматическая В-сборка 1 (фри, уголки)', 'positionIds': ['bag_collector']},
    {'id': 'w_auto_v2', 'name': 'Автоматическая В-сборка 2 (окошко)', 'positionIds': ['bag_collector']},
    {'id': 'w_cutting', 'name': 'Резка', 'positionIds': ['cutter']},
    {'id': 'w_bottom_glue_cold', 'name': 'Холодная дно-склейка', 'positionIds': ['bottom_gluer']},
    {'id': 'w_bottom_glue_hot', 'name': 'Горячая дно-склейка', 'positionIds': ['bottom_gluer']},
    {'id': 'w_handle_glue_auto', 'name': 'Автоматическая ручка-склейка', 'positionIds': ['handle_gluer']},
    {'id': 'w_handle_glue_semi', 'name': 'Полуавтоматическая ручка-склейка', 'positionIds': ['handle_gluer']},
    {'id': 'w_die_cut_a1', 'name': 'Высечка A1', 'positionIds': ['die_cutter']},
    {'id': 'w_die_cut_a2', 'name': 'Высечка A2', 'positionIds': ['die_cutter']},
    {'id': 'w_tape_glue', 'name': 'Приклейка скотча', 'positionIds': ['assembler']},
    {'id': 'w_two_sheet', 'name': 'Сборка с 2-х листов', 'positionIds': ['assembler']},
    {'id': 'w_pipe_assembly', 'name': 'Сборка трубы', 'positionIds': ['assembler']},
    {'id': 'w_bottom_card', 'name': 'Сборка дна + картон', 'positionIds': ['assembler']},
    {'id': 'w_bottom_glue_manual', 'name': 'Склейка дна (ручная)', 'positionIds': ['assembler']},
    {'id': 'w_card_laying', 'name': 'Укладка картона на дно', 'positionIds': ['assembler']},
    {'id': 'w_rope_maker', 'name': 'Изготовление верёвок (2 шт.)', 'positionIds': ['rope_operator']},
    {'id': 'w_rope_reel', 'name': 'Перемотка верёвок в бухты', 'positionIds': ['rope_operator']},
    {'id': 'w_handle_maker', 'name': 'Станок для изготовления ручек', 'positionIds': ['handle_operator']},
    {'id': 'w_press', 'name': 'Пресс', 'positionIds': ['cutter']},
    {'id': 'w_tart_maker', 'name': 'Станок для изготовления тарталеток', 'positionIds': ['muffin_operator']},
    {'id': 'w_muffin_bord', 'name': 'Станок для маффинов с бортиками', 'positionIds': ['muffin_operator']},
    {'id': 'w_muffin_no_bord', 'name': 'Станок для маффинов без бортиков', 'positionIds': ['muffin_operator']},
    {'id': 'w_tulip_maker', 'name': 'Станок для изготовления тюльпанов', 'positionIds': ['muffin_operator']},
    {'id': 'w_single_point', 'name': 'Склейка одной точки', 'positionIds': ['single_point_gluer']},
  ];

  // realtime канал (dynamic — для совместимости с разными SDK)
  dynamic _empChan;
  bool _disposed = false;

  void _safeNotify() {
    if (!_disposed) notifyListeners();
  }

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
    // Создаём стандартные должности и рабочие места
    await ensureDefaultPositions();
    await ensureDefaultWorkplaces();
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
    await ensureDefaultPositions();
    await ensureDefaultWorkplaces();
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
      _safeNotify();
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
      _safeNotify();
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
      _safeNotify();
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
      _safeNotify();
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
    _safeNotify();

    try {
      // сохраняем данные сотрудника в коллекции employees
      await _db.insert('employees', {
        ...employee.toJson(),
        'id': id,
      }, explicitId: id);
    } catch (e) {
      _employees.removeWhere((x) => x.id == id);
      _safeNotify();
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
    _safeNotify();

    try {
      await _db.updateById(id, {
        ...updated.toJson()..remove('id'),
      });
    } catch (e) {
      _employees[index] = prev;
      _safeNotify();
      rethrow;
    }
  }

  // -------------------- Positions --------------------

  Future<void> addPosition(String name) async {
    final id = _genId();
    final model = PositionModel(id: id, name: name.trim());
    _positions.add(model);
    _safeNotify();
    try {
      await _db.insert('positions', {
        'id': id,
        'name': model.name,
      }, explicitId: id);
    } catch (e) {
      _positions.removeWhere((p) => p.id == id);
      _safeNotify();
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
      _safeNotify();
    } catch (e) {
      rethrow;
    }
  }

  Future<void> deletePosition(String id) async {
    try {
      await _db.deleteById(id);
      _positions.removeWhere((p) => p.id == id);
      _safeNotify();
    } catch (e) {
      rethrow;
    }
  }

  // -------------------- Workplaces --------------------

  Future<void> addWorkplace({
    required String name,
    required List<String> positionIds,
    bool hasMachine = false,
    int maxConcurrentWorkers = 1,
  }) async {
    final id = _genId();
    final model = WorkplaceModel(
      id: id,
      name: name.trim(),
      positionIds: positionIds,
      hasMachine: hasMachine,
      maxConcurrentWorkers: maxConcurrentWorkers,
    );
    _workplaces.add(model);
    _safeNotify();

    try {
      await _db.insert('workplaces', {
        'id': id,
        'name': name.trim(),
        'positionIds': positionIds,
        'has_machine': hasMachine,
        'max_concurrent_workers': maxConcurrentWorkers,
      }, explicitId: id);
    } catch (e) {
      _workplaces.removeWhere((w) => w.id == id);
      _safeNotify();
      rethrow;
    }
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
      _safeNotify();
    } catch (e) {
      rethrow;
    }
  }

  Future<void> deleteWorkplace(String id) async {
    try {
      await _db.deleteById(id);
      _workplaces.removeWhere((w) => w.id == id);
      _safeNotify();
    } catch (e) {
      rethrow;
    }
  }

  // -------------------- Terminals --------------------

  void addTerminal({required String name, required List<String> workplaceIds}) {
    final id = _genId();
    _terminals.add(TerminalModel(id: id, name: name.trim(), workplaceIds: workplaceIds));
    _safeNotify();

    unawaited(_db.insert('terminals', {
      'id': id,
      'name': name.trim(),
      'workplaceIds': workplaceIds,
      // created_at/updated_at автоматически поставит БД
    }, explicitId: id));
  }

  @override
  void dispose() {
    _disposed = true;
    try { _empChan?.unsubscribe(); } catch (_) {}
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

  /// Creates default positions in Supabase documents if they are missing.
  ///
  /// Iterates through [_defaultPositionSeeds] and, for each seed, checks if a
  /// position with the same name exists. If not, it inserts a new record into
  /// the `positions` collection with the provided id and name. Any errors
  /// during insertion are ignored to avoid blocking bootstrapping.
  Future<void> ensureDefaultPositions() async {
    for (final seed in _defaultPositionSeeds) {
      final name = seed['name'] ?? '';
      final id = seed['id'] ?? _genId();
      try {
        final exists = (await _db.whereEq('positions', 'name', name)).isNotEmpty;
        if (!exists) {
          await _db.insert('positions', {
            'id': id,
            'name': name,
          }, explicitId: id);
        }
      } catch (_) {
        // ignore errors during seeding
      }
    }
  }

  /// Creates default workplaces in Supabase documents if they are missing.
  ///
  /// Iterates through [_defaultWorkplaceSeeds] and, for each seed, checks if a
  /// workplace with the same name exists. If not, it inserts a new record
  /// into the `workplaces` collection with the provided id, name, and
  /// positionIds. Additional fields `has_machine` and
  /// `max_concurrent_workers` default to false and 1 respectively. Errors are
  /// ignored to ensure bootstrapping continues.
  Future<void> ensureDefaultWorkplaces() async {
    for (final seed in _defaultWorkplaceSeeds) {
      final name = seed['name'] ?? '';
      final id = seed['id'] ?? _genId();
      final positionIds = (seed['positionIds'] as List?)?.cast<String>() ?? const <String>[];
      try {
        final exists = (await _db.whereEq('workplaces', 'name', name)).isNotEmpty;
        if (!exists) {
          await _db.insert('workplaces', {
            'id': id,
            'name': name,
            'positionIds': positionIds,
            'has_machine': false,
            'max_concurrent_workers': 1,
          }, explicitId: id);
        }
      } catch (_) {
        // ignore errors during seeding
      }
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
