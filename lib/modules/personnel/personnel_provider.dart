import 'package:flutter/material.dart';
import 'package:uuid/uuid.dart';
// ⬇️ вместо Firebase:
import 'package:supabase_flutter/supabase_flutter.dart';

import 'position_model.dart';
import 'employee_model.dart';
import 'workplace_model.dart';
import 'terminal_model.dart';

/// Провайдер для управления данными персонала.
/// Firebase Realtime DB → Supabase (Postgres + Realtime).
class PersonnelProvider with ChangeNotifier {
  final _uuid = const Uuid();
  final SupabaseClient _supabase = Supabase.instance.client;

  PersonnelProvider() {
    _listenToEmployees(); // аналогично старому _listenToEmployees()
  }

  // Список должностей (как было)
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

  final List<EmployeeModel> _employees = [];

  /// Начальный список рабочих мест (как было)
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

  /// Список терминалов (как было)
  final List<TerminalModel> _terminals = [];

  List<PositionModel> get positions => List.unmodifiable(_positions);
  List<EmployeeModel> get employees => List.unmodifiable(_employees);
  List<WorkplaceModel> get workplaces => List.unmodifiable(_workplaces);
  List<TerminalModel> get terminals => List.unmodifiable(_terminals);

  // -------------------- Загрузка/стрим сотрудников (Supabase) --------------------

  void _listenToEmployees() {
    // Realtime поток из таблицы employees по первичному ключу id
    _supabase.from('employees').stream(primaryKey: ['id']).listen((rows) {
      _employees.clear();
      for (final row in rows) {
        final map = Map<String, dynamic>.from(row as Map);
        // Если у тебя EmployeeModel.fromJson ожидает (map, id) — передаём id из строки:
        final id = (row['id'] ?? '').toString();
        _employees.add(EmployeeModel.fromJson(map, id));
      }
      notifyListeners();
    });
  }

  // -------------------- Должности/терминалы (локально, как было) --------------------

  void addPosition(String name) {
    final id = _uuid.v4();
    _positions.add(PositionModel(id: id, name: name));
    notifyListeners();
  }

  void addWorkplace({required String name, required List<String> positionIds}) {
    final id = _uuid.v4();
    _workplaces.add(WorkplaceModel(id: id, name: name, positionIds: positionIds));
    notifyListeners();
  }

  void addTerminal({required String name, required List<String> workplaceIds}) {
    final id = _uuid.v4();
    _terminals.add(TerminalModel(id: id, name: name, workplaceIds: workplaceIds));
    notifyListeners();
  }

  // -------------------- CRUD сотрудника в Supabase --------------------

  void addEmployee({
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
  }) {
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

    // локально
    _employees.add(employee);
    notifyListeners();

    // запись в БД (важно убедиться, что таблица employees имеет колонку id)
    final data = Map<String, dynamic>.from(employee.toJson());
    data['id'] = id; // в Supabase id хранится в строке, не в ключе
    _supabase.from('employees').insert(data);
  }

  void updateEmployee({
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
  }) {
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

    // локально
    _employees[index] = updated;
    notifyListeners();

    // БД: не передаём id в update (он в where)
    final data = Map<String, dynamic>.from(updated.toJson());
    data.remove('id');
    _supabase.from('employees').update(data).eq('id', id);
  }
}
