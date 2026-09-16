import 'employee_model.dart';
import 'personnel_constants.dart';

/// Должности, у которых своё отдельное рабочее место.
///
/// Тот же набор, что исключает `PersonnelProvider.regularPositions`, и тот же,
/// что вынесен в отдельный блок «Роль с отдельным рабочим местом» в
/// [ManagerAwarePositionsPicker]. Держим список одним определением: раньше
/// правило существовало только в карточке сотрудника, а рабочее пространство
/// про него не знало.
const Set<String> kDedicatedWorkplacePositionIds = <String>{
  kManagerId,
  kWarehouseHeadId,
  kTechLeaderId,
  kCmmSpecialistId,
};

/// У сотрудника есть роль с отдельным рабочим местом.
///
/// Такая роль эксклюзивна: выбрать её вместе с обычной должностью карточка
/// сотрудника не даёт, значит одна такая должность делает сотрудника
/// «не производственным» целиком.
bool hasDedicatedWorkplaceRole(EmployeeModel employee) {
  for (final id in employee.positionIds) {
    if (kDedicatedWorkplacePositionIds.contains(id.trim())) return true;
  }
  return false;
}

/// Сотрудники, которых можно добавить в общее рабочее пространство цеха —
/// вкладкой или помощником на этапе.
///
/// Отсеиваются уволенные и роли с отдельным рабочим местом: менеджер,
/// технический лидер, заведующий складом и CMM специалист работают в своих
/// модулях, производственных заданий у них нет, и появляться в списке наравне
/// с печатником или упаковщиком они не должны.
List<EmployeeModel> employeesForSharedWorkspace(
  Iterable<EmployeeModel> employees, {
  Set<String> excludedIds = const <String>{},
}) {
  return employees
      .where((employee) =>
          !employee.isFired &&
          !excludedIds.contains(employee.id) &&
          !hasDedicatedWorkplaceRole(employee))
      .toList(growable: false);
}
