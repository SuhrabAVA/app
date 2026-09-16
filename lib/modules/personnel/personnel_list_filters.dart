/// Поиск и фильтры списков модуля «Персонал».
///
/// Одно правило поиска на все экраны: без учёта регистра, «ё» = «е», запрос
/// режется на слова, и КАЖДОЕ слово должно встретиться хоть в одном поле
/// записи — «иванов оператор» находит Иванова-оператора, а не всех Ивановых
/// и всех операторов.
///
/// Фильтры — отдельные классы на экран. Экран держит экземпляр, меняет его
/// поля и зовёт `matches` для каждой строки; здесь нет ни виджетов, ни
/// провайдера, поэтому правила проверяются обычными тестами.
library;

import '../orders/order_extra_options.dart';
import '../orders/product_type_settings.dart' show ProductTypeRef;
import 'employee_model.dart';
import 'employee_status_model.dart';
import 'position_model.dart';
import 'terminal_model.dart';
import 'workplace_model.dart';

/// Пункт мультивыбора «значение не задано»: сотрудник без должности,
/// терминал без рабочих мест.
const String kFilterNoneId = '__none__';

/// Фильтр «да / нет / неважно».
enum TriFilter { any, yes, no }

extension TriFilterAccepts on TriFilter {
  bool accepts(bool value) => switch (this) {
        TriFilter.any => true,
        TriFilter.yes => value,
        TriFilter.no => !value,
      };
}

String normalizeSearchText(String? value) => (value ?? '')
    .toLowerCase()
    .replaceAll('ё', 'е')
    .replaceAll(RegExp(r'\s+'), ' ')
    .trim();

/// Каждое слово запроса есть хотя бы в одном из [fields].
bool matchesSearch(String query, Iterable<String?> fields) {
  final tokens =
      normalizeSearchText(query).split(' ').where((t) => t.isNotEmpty);
  if (tokens.isEmpty) return true;
  final haystack = normalizeSearchText(fields.whereType<String>().join(' '));
  return tokens.every(haystack.contains);
}

/// Мультивыбор по id: пустой выбор — «любые». [kFilterNoneId] отбирает записи,
/// у которых значений нет вовсе.
bool matchesAnyId(Set<String> selected, Iterable<String> ids) {
  if (selected.isEmpty) return true;
  final present = ids.where((id) => id.trim().isNotEmpty).toList();
  if (present.isEmpty) return selected.contains(kFilterNoneId);
  return present.any(selected.contains);
}

// ── Сотрудники ─────────────────────────────────────────────────────────────

class EmployeeListFilter {
  String query = '';
  final Set<String> positionIds = <String>{};
  final Set<String> statusIds = <String>{};

  bool get hasFilters => positionIds.isNotEmpty || statusIds.isNotEmpty;
  bool get isActive => query.trim().isNotEmpty || hasFilters;

  void clear() {
    query = '';
    positionIds.clear();
    statusIds.clear();
  }

  /// [statusId] — текущий статус сотрудника (null — без статуса).
  bool matches(
    EmployeeModel employee, {
    required String Function(String positionId) positionName,
    required String? statusId,
    required String Function(String statusId) statusName,
  }) {
    final status = (statusId ?? '').trim();
    if (!matchesAnyId(positionIds, employee.positionIds)) return false;
    if (!matchesAnyId(statusIds, [status])) return false;
    return matchesSearch(query, [
      employee.lastName,
      employee.firstName,
      employee.patronymic,
      employee.login,
      employee.iin,
      employee.comments,
      ...employee.positionIds.map(positionName),
      if (status.isNotEmpty) statusName(status),
    ]);
  }
}

// ── Должности ──────────────────────────────────────────────────────────────

class PositionListFilter {
  String query = '';
  TriFilter hasEmployees = TriFilter.any;
  TriFilter hasWorkplaces = TriFilter.any;

  bool get hasFilters =>
      hasEmployees != TriFilter.any || hasWorkplaces != TriFilter.any;
  bool get isActive => query.trim().isNotEmpty || hasFilters;

  void clear() {
    query = '';
    hasEmployees = TriFilter.any;
    hasWorkplaces = TriFilter.any;
  }

  bool matches(
    PositionModel position, {
    required int employeeCount,
    required int workplaceCount,
  }) {
    return hasEmployees.accepts(employeeCount > 0) &&
        hasWorkplaces.accepts(workplaceCount > 0) &&
        matchesSearch(query, [position.name]);
  }
}

// ── Статусы ────────────────────────────────────────────────────────────────

class StatusListFilter {
  String query = '';
  TriFilter assigned = TriFilter.any;

  bool get hasFilters => assigned != TriFilter.any;
  bool get isActive => query.trim().isNotEmpty || hasFilters;

  void clear() {
    query = '';
    assigned = TriFilter.any;
  }

  bool matches(EmployeeStatus status, {required int assignedCount}) {
    return assigned.accepts(assignedCount > 0) &&
        matchesSearch(query, [status.name, status.description]);
  }
}

// ── Рабочие места ──────────────────────────────────────────────────────────

class WorkplaceListFilter {
  String query = '';
  final Set<String> positionIds = <String>{};

  /// Единицы измерения; [kFilterNoneId] — единица не задана.
  final Set<String> units = <String>{};
  TriFilter hasMachine = TriFilter.any;

  /// null — любой режим.
  WorkplaceExecutionMode? mode;

  bool get hasFilters =>
      positionIds.isNotEmpty ||
      units.isNotEmpty ||
      hasMachine != TriFilter.any ||
      mode != null;
  bool get isActive => query.trim().isNotEmpty || hasFilters;

  void clear() {
    query = '';
    positionIds.clear();
    units.clear();
    hasMachine = TriFilter.any;
    mode = null;
  }

  bool matches(
    WorkplaceModel workplace, {
    required String Function(String positionId) positionName,
  }) {
    final unit = (workplace.unit ?? '').trim();
    if (!matchesAnyId(positionIds, workplace.positionIds)) return false;
    if (!matchesAnyId(units, [unit])) return false;
    if (!hasMachine.accepts(workplace.hasMachine)) return false;
    if (mode != null && workplace.executionMode != mode) return false;
    return matchesSearch(query, [
      workplace.name,
      workplace.description,
      unit,
      ...workplace.positionIds.map(positionName),
    ]);
  }
}

// ── Терминалы ──────────────────────────────────────────────────────────────

class TerminalListFilter {
  String query = '';
  final Set<String> workplaceIds = <String>{};

  bool get hasFilters => workplaceIds.isNotEmpty;
  bool get isActive => query.trim().isNotEmpty || hasFilters;

  void clear() {
    query = '';
    workplaceIds.clear();
  }

  bool matches(
    TerminalModel terminal, {
    required String Function(String workplaceId) workplaceName,
  }) {
    if (!matchesAnyId(workplaceIds, terminal.workplaceIds)) return false;
    return matchesSearch(query, [
      terminal.name,
      ...terminal.workplaceIds.map(workplaceName),
    ]);
  }
}

// ── Типы продукта ──────────────────────────────────────────────────────────

class ProductTypeListFilter {
  String query = '';
  TriFilter hasDraft = TriFilter.any;

  bool get hasFilters => hasDraft != TriFilter.any;
  bool get isActive => query.trim().isNotEmpty || hasFilters;

  void clear() {
    query = '';
    hasDraft = TriFilter.any;
  }

  bool matches(ProductTypeRef type, {required bool draft}) {
    return hasDraft.accepts(draft) && matchesSearch(query, [type.title]);
  }
}

// ── Опции заказа ───────────────────────────────────────────────────────────

class OrderOptionListFilter {
  String query = '';

  /// `kOrderOptionKindBoolean` / `kOrderOptionKindSelect`; пусто — любые.
  final Set<String> kinds = <String>{};

  bool get hasFilters => kinds.isNotEmpty;
  bool get isActive => query.trim().isNotEmpty || hasFilters;

  void clear() {
    query = '';
    kinds.clear();
  }

  /// Ищет и по названию опции, и по её действующим вариантам: техлид чаще
  /// помнит вариант («Крафт»), чем опцию, в которой он лежит.
  bool matches(OrderOptionDef option) {
    if (kinds.isNotEmpty && !kinds.contains(option.kind)) return false;
    return matchesSearch(query, [
      option.title,
      for (final value in option.values)
        if (value.isActive) value.title,
    ]);
  }
}
