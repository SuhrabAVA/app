import 'package:flutter/material.dart';
import 'package:uuid/uuid.dart';
import 'package:firebase_database/firebase_database.dart';

import 'position_model.dart';
import 'employee_model.dart';
import 'workplace_model.dart';
import 'terminal_model.dart';

/// Провайдер для управления данными персонала: должностями, сотрудниками,
/// рабочими местами и терминалами. Хранит данные в памяти и уведомляет
/// слушателей при изменениях.
class PersonnelProvider with ChangeNotifier {
  final _uuid = const Uuid();
  final DatabaseReference _employeesRef =
      FirebaseDatabase.instance.ref('employees');

  PersonnelProvider() {
    _listenToEmployees();
  }

  // Список должностей
  /// Начальный список должностей. Здесь собраны все типы должностей,
  /// которые используются в системе. Дополнять список при необходимости
  /// можно динамически через экран «Должности».
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

  /// Начальный список рабочих мест. Каждое место привязано к одной
  /// или нескольким должностям. Список можно дополнять из
  /// пользовательского интерфейса. Предопределённые рабочие места
  /// упрощают начальную конфигурацию системы.
  final List<WorkplaceModel> _workplaces = [
    // 1. Бобинорезка — работает бобинорезчик
    WorkplaceModel(id: 'w_bobiner', name: 'Бобинорезка', positionIds: ['bob_cutter']),
    // 2. Флексопечать — печатник
    WorkplaceModel(id: 'w_flexoprint', name: 'Флексопечать', positionIds: ['print']),
    // 3–4. Листорезка (старая и новая) — листорезчик
    WorkplaceModel(id: 'w_sheet_old', name: 'Листорезка 1 (старая)', positionIds: ['cut_sheet']),
    WorkplaceModel(id: 'w_sheet_new', name: 'Листорезка 2 (новая)', positionIds: ['cut_sheet']),
    // 5–8. Различные сборочные автоматы — пакетосборщик
    WorkplaceModel(id: 'w_auto_p_assembly', name: 'Автоматическая П‑сборка', positionIds: ['bag_collector']),
    WorkplaceModel(id: 'w_auto_p_pipe', name: 'Автоматическая П‑сборка (труба)', positionIds: ['bag_collector']),
    WorkplaceModel(id: 'w_auto_v1', name: 'Автоматическая В‑сборка 1 (фри, уголки)', positionIds: ['bag_collector']),
    WorkplaceModel(id: 'w_auto_v2', name: 'Автоматическая В‑сборка 2 (окошко)', positionIds: ['bag_collector']),
    // 9. Резка — резчик
    WorkplaceModel(id: 'w_cutting', name: 'Резка', positionIds: ['cutter']),
    // 10–11. Дно‑склейка (холодная/горячая) — дносклейщик
    WorkplaceModel(id: 'w_bottom_glue_cold', name: 'Холодная дно‑склейка', positionIds: ['bottom_gluer']),
    WorkplaceModel(id: 'w_bottom_glue_hot', name: 'Горячая дно‑склейка', positionIds: ['bottom_gluer']),
    // 12–13. Ручка‑склейка (автомат/полуавтомат) — склейщик ручек
    WorkplaceModel(id: 'w_handle_glue_auto', name: 'Автоматическая ручка‑склейка', positionIds: ['handle_gluer']),
    WorkplaceModel(id: 'w_handle_glue_semi', name: 'Полуавтоматическая ручка‑склейка', positionIds: ['handle_gluer']),
    // 14–15. Высечка — оператор высечки
    WorkplaceModel(id: 'w_die_cut_a1', name: 'Высечка A1', positionIds: ['die_cutter']),
    WorkplaceModel(id: 'w_die_cut_a2', name: 'Высечка A2', positionIds: ['die_cutter']),
    // 16–21. Различные операции сборки — сборщик
    WorkplaceModel(id: 'w_tape_glue', name: 'Приклейка скотча', positionIds: ['assembler']),
    WorkplaceModel(id: 'w_two_sheet', name: 'Сборка с 2‑х листов', positionIds: ['assembler']),
    WorkplaceModel(id: 'w_pipe_assembly', name: 'Сборка трубы', positionIds: ['assembler']),
    WorkplaceModel(id: 'w_bottom_card', name: 'Сборка дна + картон', positionIds: ['assembler']),
    WorkplaceModel(id: 'w_bottom_glue_manual', name: 'Склейка дна (ручная)', positionIds: ['assembler']),
    WorkplaceModel(id: 'w_card_laying', name: 'Укладка картона на дно', positionIds: ['assembler']),
    // 22–23. Оборудование для верёвок — оператор верёвок
    WorkplaceModel(id: 'w_rope_maker', name: 'Изготовление верёвок (2 шт.)', positionIds: ['rope_operator']),
    WorkplaceModel(id: 'w_rope_reel', name: 'Перемотка верёвок в бухты', positionIds: ['rope_operator']),
    // 24. Оборудование для ручек — оператор ручек
    WorkplaceModel(id: 'w_handle_maker', name: 'Станок для изготовления ручек', positionIds: ['handle_operator']),
    // 25. Пресс — используется резчиком
    WorkplaceModel(id: 'w_press', name: 'Пресс', positionIds: ['cutter']),
    // 26–29. Оборудование для маффинов/тюльпанов — оператор маффинов
    WorkplaceModel(id: 'w_tart_maker', name: 'Станок для изготовления тарталеток', positionIds: ['muffin_operator']),
    WorkplaceModel(id: 'w_muffin_bord', name: 'Станок для маффинов с бортиками', positionIds: ['muffin_operator']),
    WorkplaceModel(id: 'w_muffin_no_bord', name: 'Станок для маффинов без бортиков', positionIds: ['muffin_operator']),
    WorkplaceModel(id: 'w_tulip_maker', name: 'Станок для изготовления тюльпанов', positionIds: ['muffin_operator']),
    // 30. Склейка одной точки — отдельная должность
    WorkplaceModel(id: 'w_single_point', name: 'Склейка одной точки', positionIds: ['single_point_gluer']),
  ];

  /// Список терминалов. По умолчанию пустой — пользователь может
  /// создавать терминалы из интерфейса. Каждый терминал может
  /// обслуживать несколько рабочих мест.
  final List<TerminalModel> _terminals = [];

  List<PositionModel> get positions => List.unmodifiable(_positions);
  List<EmployeeModel> get employees => List.unmodifiable(_employees);
  List<WorkplaceModel> get workplaces => List.unmodifiable(_workplaces);
  List<TerminalModel> get terminals => List.unmodifiable(_terminals);

  // Добавление должности
  void addPosition(String name) {
    final id = _uuid.v4();
    _positions.add(PositionModel(id: id, name: name));
    notifyListeners();
  }

  void _listenToEmployees() {
    _employeesRef.onValue.listen((event) {
      final data = event.snapshot.value;
      _employees.clear();
      if (data is Map) {
        data.forEach((key, value) {
          final map = Map<String, dynamic>.from(value as Map);
          _employees.add(EmployeeModel.fromJson(map, key));
        });
      }
      notifyListeners();
    });
  }

  // Добавление сотрудника с сохранением в Firebase
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
    _employees.add(employee);
    notifyListeners();
    _employeesRef.child(id).set(employee.toJson());
  }

  // Обновление существующего сотрудника
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
    );
    _employees[index] = updated;
    notifyListeners();
    _employeesRef.child(id).set(updated.toJson());
  }

  // Добавление рабочего места
  void addWorkplace({required String name, required List<String> positionIds}) {
    final id = _uuid.v4();
    _workplaces.add(WorkplaceModel(id: id, name: name, positionIds: positionIds));
    notifyListeners();
  }

  // Добавление терминала
  void addTerminal({required String name, required List<String> workplaceIds}) {
    final id = _uuid.v4();
    _terminals.add(TerminalModel(id: id, name: name, workplaceIds: workplaceIds));
    notifyListeners();
  }
}