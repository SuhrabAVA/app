import 'dart:async';
import 'package:flutter/material.dart';
import 'package:uuid/uuid.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'personnel_constants.dart'; // <-- константы kManagerId, kWarehouseHeadId
import 'position_model.dart';  
import 'position_model.dart';
import 'employee_model.dart';
import 'workplace_model.dart';
import 'terminal_model.dart';

/// Провайдер для управления данными персонала.
/// Источник данных сотрудников — Supabase (Postgres + Realtime).
class PersonnelProvider with ChangeNotifier {
  PersonnelProvider() {
    // гарантируем, что «Менеджер» и «Заведующий складом» есть среди должностей
    ensureManagerPosition();
    ensureWarehouseHeadPosition();
    // подтягиваем сотрудников и слушаем изменения
    _listenToEmployees();
  }

  final _uuid = const Uuid();
  final SupabaseClient _supabase = Supabase.instance.client;

  StreamSubscription<List<Map<String, dynamic>>>? _empSub;

  // -------------------- Локальные справочники (как было) --------------------

  /// Должности (локально, можно расширять)
  final List<PositionModel> _positions = [
    PositionModel(id: 'bob_cutter', name: 'Бобинорезчик'),
    PositionModel(id: 'print', name: 'Печатник'),
    PositionModel(id: 'cut_sheet', name: 'Листорезчик'),
    PositionModel(id: 'bag_collector', name: 'Пакетосборщик'),
    PositionModel(id: 'cutter', name: 'Резчик'),
    PositionModel(id: 'bottom_gluer', name: 'Дносклейщик'),
    PositionModel(id: 'handle_gluer', name: 'Склейщик ручек'),
    PositionModel(id: 'die_cutter', name: 'Оператор высечки'),
    PositionModel(id: 'assembler', name: 'Сборщик'),
    PositionModel(id: 'rope_operator', name: 'Оператор веревок'),
    PositionModel(id: 'handle_operator', name: 'Оператор ручек'),
    PositionModel(id: 'muffin_operator', name: 'Оператор маффинов'),
    PositionModel(id: 'single_point_gluer', name: 'Склейка одной точки'),
  ];

  /// Сотрудники (поднимаются из Supabase)
  final List<EmployeeModel> _employees = [];

  /// Рабочие места (локально, как было)
  final List<WorkplaceModel> _workplaces = [
    WorkplaceModel(id: 'w_bobiner', name: 'Бобинорезка', positionIds: ['bob_cutter']),
    WorkplaceModel(id: 'w_flexoprint', name: 'Флексопечать', positionIds: ['print']),
    WorkplaceModel(id: 'w_sheet_old', name: 'Листорезка 1 (старая)', positionIds: ['cut_sheet']),
    WorkplaceModel(id: 'w_sheet_new', name: 'Листорезка 2 (новая)', positionIds: ['cut_sheet']),
    WorkplaceModel(id: 'w_auto_p_assembly', name: 'Автоматическая П-сборка', positionIds: ['bag_collector']),
    WorkplaceModel(id: 'w_auto_p_pipe', name: 'Автоматическая П-сборка (труба)', positionIds: ['bag_collector']),
    WorkplaceModel(id: 'w_auto_v1', name: 'Автоматическая В-сборка 1 (фри, уголки)', positionIds: ['bag_collector']),
    WorkplaceModel(id: 'w_auto_v2', name: 'Автоматическая В-сборка 2 (окошко)', positionIds: ['bag_collector']),
    WorkplaceModel(id: 'w_cutting', name: 'Резка', positionIds: ['cutter']),
    WorkplaceModel(id: 'w_bottom_glue_cold', name: 'Холодная дно-склейка', positionIds: ['bottom_gluer']),
    WorkplaceModel(id: 'w_bottom_glue_hot', name: 'Горячая дно-склейка', positionIds: ['bottom_gluer']),
    WorkplaceModel(id: 'w_handle_glue_auto', name: 'Автоматическая ручка-склейка', positionIds: ['handle_gluer']),
    WorkplaceModel(id: 'w_handle_glue_semi', name: 'Полуавтоматическая ручка-склейка', positionIds: ['handle_gluer']),
    WorkplaceModel(id: 'w_die_cut_a1', name: 'Высечка A1', positionIds: ['die_cutter']),
    WorkplaceModel(id: 'w_die_cut_a2', name: 'Высечка A2', positionIds: ['die_cutter']),
    WorkplaceModel(id: 'w_tape_glue', name: 'Приклейка скотча', positionIds: ['assembler']),
    WorkplaceModel(id: 'w_two_sheet', name: 'Сборка с 2-х листов', positionIds: ['assembler']),
    WorkplaceModel(id: 'w_pipe_assembly', name: 'Сборка трубы', positionIds: ['assembler']),
    WorkplaceModel(id: 'w_bottom_card', name: 'Сборка дна + картон', positionIds: ['assembler']),
    WorkplaceModel(id: 'w_bottom_glue_manual', name: 'Склейка дна (ручная)', positionIds: ['assembler']),
    WorkplaceModel(id: 'w_card_laying', name: 'Укладка картона на дно', positionIds: ['assembler']),
    WorkplaceModel(id: 'w_rope_maker', name: 'Изготовление верёвок (2 шт.)', positionIds: ['rope_operator']),
    WorkplaceModel(id: 'w_rope_reel', name: 'Перемотка верёвок в бухты', positionIds: ['rope_operator']),
    WorkplaceModel(id: 'w_handle_maker', name: 'Станок для изготовления ручек', positionIds: ['handle_operator']),
    WorkplaceModel(id: 'w_press', name: 'Пресс', positionIds: ['cutter']),
    WorkplaceModel(id: 'w_tart_maker', name: 'Станок для изготовления тарталеток', positionIds: ['muffin_operator']),
    WorkplaceModel(id: 'w_muffin_bord', name: 'Станок для маффинов с бортиками', positionIds: ['muffin_operator']),
    WorkplaceModel(id: 'w_muffin_no_bord', name: 'Станок для маффинов без бортиков', positionIds: ['muffin_operator']),
    WorkplaceModel(id: 'w_tulip_maker', name: 'Станок для изготовления тюльпанов', positionIds: ['muffin_operator']),
    WorkplaceModel(id: 'w_single_point', name: 'Склейка одной точки', positionIds: ['single_point_gluer']),
  ];

  /// Терминалы (оставлено как было)
  final List<TerminalModel> _terminals = [];

  // ---- Getters
  List<PositionModel> get positions => List.unmodifiable(_positions);
  List<EmployeeModel> get employees => List.unmodifiable(_employees);
  List<WorkplaceModel> get workplaces => List.unmodifiable(_workplaces);
  List<TerminalModel> get terminals => List.unmodifiable(_terminals);

  // -------------------- Сотрудники: загрузка и realtime --------------------

  /// Разовая загрузка (если нужно вручную дёрнуть)
  Future<void> fetchEmployees() async {
    try {
      final rows = await _supabase
          .from('employees')
          .select('*')
          .order('lastName', ascending: true);

      _employees
        ..clear()
        ..addAll((rows as List).map((r) {
          final map = Map<String, dynamic>.from(r as Map);
          final id = (map['id'] ?? '').toString();
          return EmployeeModel.fromJson(map, id);
        }));
      notifyListeners();
    } catch (e) {
      debugPrint('❌ fetchEmployees failed: $e');
    }
  }

  void _listenToEmployees() {
    _empSub?.cancel();
    _empSub = _supabase
        .from('employees')
        .stream(primaryKey: ['id'])
        .order('lastName', ascending: true)
        .listen((rows) {
      _employees
        ..clear()
        ..addAll(rows.map((row) {
          final map = Map<String, dynamic>.from(row as Map);
          final id = (row['id'] ?? '').toString();
          return EmployeeModel.fromJson(map, id);
        }));
      notifyListeners();
    }, onError: (e) {
      debugPrint('❌ employees stream error: $e');
    });
  }

  // -------------------- Хелперы --------------------

  /// Название должности по id (для подпиcей в UI)
  String positionNameById(String? id) {
    if (id == null || id.isEmpty) return '';
    final p = _positions.firstWhere(
      (p) => p.id == id,
      orElse: () => PositionModel(id: '', name: ''),
    );
    return p.name;
  }

  // -------------------- CRUD локальных справочников --------------------

  void addPosition(String name) {
    final id = _uuid.v4();
    _positions.add(PositionModel(id: id, name: name.trim()));
    notifyListeners();
  }

  void addWorkplace({required String name, required List<String> positionIds}) {
    final id = _uuid.v4();
    _workplaces.add(WorkplaceModel(id: id, name: name.trim(), positionIds: positionIds));
    notifyListeners();
  }

  void addTerminal({required String name, required List<String> workplaceIds}) {
    final id = _uuid.v4();
    _terminals.add(TerminalModel(id: id, name: name.trim(), workplaceIds: workplaceIds));
    notifyListeners();
  }

  // -------------------- CRUD сотрудника (Supabase) --------------------

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
    final id = _uuid.v4();

    final employee = EmployeeModel(
      id: id,
      lastName: lastName,
      firstName: firstName,
      patronymic: patronymic,
      iin: iin,
      photoUrl: photoUrl,
      positionIds: positionIds,
      isFired: isFired,
      comments: comments,
      login: login,
      password: password,
    );

    // оптимистично обновляем UI
    _employees.add(employee);
    notifyListeners();

    final data = Map<String, dynamic>.from(employee.toJson())..['id'] = id;

    try {
      final inserted = await _supabase
          .from('employees')
          .insert(data)
          .select()
          .single();
      debugPrint('✅ employees.insert OK: $inserted');
    } on PostgrestException catch (e, st) {
      debugPrint('❌ PostgrestException on insert: ${e.message} code=${e.code} details=${e.details}\n$st');
      _employees.removeWhere((x) => x.id == id);
      notifyListeners();
      rethrow;
    } catch (e, st) {
      debugPrint('❌ Unknown error on insert: $e\n$st');
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

    final updated = EmployeeModel(
      id: id,
      lastName: lastName,
      firstName: firstName,
      patronymic: patronymic,
      iin: iin,
      photoUrl: photoUrl,
      positionIds: positionIds,
      isFired: isFired,
      comments: comments,
      login: login,
      password: password,
    );

    final prev = _employees[index];
    _employees[index] = updated;
    notifyListeners();

    final data = Map<String, dynamic>.from(updated.toJson())..remove('id');

    try {
      await _supabase.from('employees').update(data).eq('id', id).select().single();
    } catch (e) {
      // откатываем локально, если запрос не удался
      _employees[index] = prev;
      notifyListeners();
      debugPrint('❌ updateEmployee failed: $e');
      rethrow;
    }
  }

  // -------------------- Positions: редактирование/удаление (в БД) --------------------

  Future<void> updatePosition({
    required String id,
    required String name,
    String? description,
  }) async {
    try {
      await _supabase.from('positions').update({
        'name': name.trim(),
        'description': (description ?? '').trim().isEmpty ? null : description!.trim(),
        'updated_at': DateTime.now().toIso8601String(),
      }).eq('id', id);
      // локально тоже обновим, чтобы UI сразу увидел
      final i = _positions.indexWhere((p) => p.id == id);
      if (i != -1) _positions[i] = PositionModel(id: id, name: name.trim());
      notifyListeners();
    } catch (e) {
      debugPrint('❌ updatePosition failed: $e');
      rethrow;
    }
  }

  Future<void> deletePosition(String id) async {
    try {
      await _supabase.from('positions').delete().eq('id', id);
      _positions.removeWhere((p) => p.id == id);
      notifyListeners();
    } catch (e) {
      debugPrint('❌ deletePosition failed: $e');
      rethrow;
    }
  }

  /// Гарантирует наличие должности «Менеджер» локально + пытается синкнуть в БД.
  

  // -------------------- Workplaces: редактирование/удаление (в БД) --------------------

  Future<void> updateWorkplace({
    required String id,
    required String name,
    String? description,
  }) async {
    try {
      await _supabase.from('workplaces').update({
        'name': name.trim(),
        'description': (description ?? '').trim().isEmpty ? null : description!.trim(),
        'updated_at': DateTime.now().toIso8601String(),
      }).eq('id', id);

      final i = _workplaces.indexWhere((w) => w.id == id);
      if (i != -1) {
        final old = _workplaces[i];
        _workplaces[i] = WorkplaceModel(
          id: id,
          name: name.trim(),
          positionIds: old.positionIds,
        );
      }
      notifyListeners();
    } catch (e) {
      debugPrint('❌ updateWorkplace failed: $e');
      rethrow;
    }
  }

  Future<void> deleteWorkplace(String id) async {
    try {
      await _supabase.from('workplaces').delete().eq('id', id);
      _workplaces.removeWhere((w) => w.id == id);
      notifyListeners();
    } catch (e) {
      debugPrint('❌ deleteWorkplace failed: $e');
      rethrow;
    }
  }

  // -------------------- Жизненный цикл --------------------

  @override
  void dispose() {
    _empSub?.cancel();
    super.dispose();
  }
}



extension PersonnelProviderHelpers on PersonnelProvider {
  bool isManagerPositionId(String id) => id == kManagerId;
  bool isWarehouseHeadPositionId(String id) => id == kWarehouseHeadId;

  /// Возвращает позицию «Менеджер» (по id или названию)
  PositionModel? findManagerPosition() {
    try {
      return _positions.firstWhere(
        (p) => p.id == kManagerId || p.name.toLowerCase().trim() == 'менеджер',
      );
    } catch (_) {
      return null;
    }
  }

  /// Возвращает позицию «Заведующий складом» (по id или названию)
  PositionModel? findWarehouseHeadPosition() {
    try {
      return _positions.firstWhere(
        (p) =>
            p.id == kWarehouseHeadId || p.name.toLowerCase().trim() == 'заведующий складом',
      );
    } catch (_) {
      return null;
    }
  }

  /// Все обычные должности (без «Менеджера» и «Заведующего складом»)
  List<PositionModel> get regularPositions => _positions
      .where((p) =>
          !(p.id == kManagerId ||
            p.name.toLowerCase().trim() == 'менеджер' ||
            p.id == kWarehouseHeadId ||
            p.name.toLowerCase().trim() == 'заведующий складом'))
      .toList();

  /// Имя должности по id (без падений)
  String positionNameById(String? id) {
    if (id == null) return '';
    try {
      return _positions.firstWhere((p) => p.id == id).name;
    } catch (_) {
      return '';
    }
  }

  /// Гарантируем, что «Менеджер» есть и внизу списка
  Future<void> ensureManagerPosition() async {
    // локально
    final already = _positions.any(
      (p) => p.id == kManagerId || p.name.toLowerCase().trim() == 'менеджер',
    );
    if (!already) {
      _positions.add(PositionModel(id: kManagerId, name: 'Менеджер'));
      notifyListeners();
    } else {
      // переместим вниз
      final copy = List<PositionModel>.from(_positions);
      copy.removeWhere(
        (p) => p.id == kManagerId || p.name.toLowerCase().trim() == 'менеджер',
      );
      final mgr = _positions.firstWhere(
        (p) => p.id == kManagerId || p.name.toLowerCase().trim() == 'менеджер',
      );
      copy.add(mgr);
      _positions
        ..clear()
        ..addAll(copy);
      notifyListeners();
    }

    // при наличии таблицы positions — мягкая синхронизация
    try {
      final rows = await _supabase
          .from('positions')
          .select('id')
          .ilike('name', 'менеджер')
          .limit(1);

      if (rows is List && rows.isNotEmpty) return;

      await _supabase.from('positions').insert({
        'id': kManagerId,
        'name': 'Менеджер',
        'description': 'Управление заказами и чат менеджеров',
        'created_at': DateTime.now().toIso8601String(),
        'updated_at': DateTime.now().toIso8601String(),
      });
    } catch (_) {
      // ок: локально уже есть
    }
  }

  /// Гарантируем, что «Заведующий складом» есть и внизу списка
  Future<void> ensureWarehouseHeadPosition() async {
    // локально
    final already = _positions.any(
      (p) => p.id == kWarehouseHeadId ||
          p.name.toLowerCase().trim() == 'заведующий складом',
    );
    if (!already) {
      _positions.add(
          PositionModel(id: kWarehouseHeadId, name: 'Заведующий складом'));
      notifyListeners();
    } else {
      // переместим вниз
      final copy = List<PositionModel>.from(_positions);
      copy.removeWhere(
        (p) => p.id == kWarehouseHeadId ||
            p.name.toLowerCase().trim() == 'заведующий складом',
      );
      final wh = _positions.firstWhere(
        (p) => p.id == kWarehouseHeadId ||
            p.name.toLowerCase().trim() == 'заведующий складом',
      );
      copy.add(wh);
      _positions
        ..clear()
        ..addAll(copy);
      notifyListeners();
    }

    // при наличии таблицы positions — мягкая синхронизация
    try {
      final rows = await _supabase
          .from('positions')
          .select('id')
          .ilike('name', 'заведующий складом')
          .limit(1);

      if (rows is List && rows.isNotEmpty) return;

      await _supabase.from('positions').insert({
        'id': kWarehouseHeadId,
        'name': 'Заведующий складом',
        'description': 'Управление складом и чат',
        'created_at': DateTime.now().toIso8601String(),
        'updated_at': DateTime.now().toIso8601String(),
      });
    } catch (_) {
      // ок: локально уже есть
    }
  }
}