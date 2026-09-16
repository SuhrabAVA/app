import 'package:flutter_test/flutter_test.dart';
import 'package:sheet_clone/modules/personnel/employee_model.dart';
import 'package:sheet_clone/modules/personnel/personnel_constants.dart';
import 'package:sheet_clone/modules/personnel/workspace_access_rules.dart';

void main() {
  EmployeeModel employee({
    required String id,
    List<String> positionIds = const ['print'],
    bool isFired = false,
  }) {
    return EmployeeModel(
      id: id,
      lastName: 'Фамилия',
      firstName: 'Имя',
      patronymic: '',
      iin: '',
      positionIds: positionIds,
      isFired: isFired,
    );
  }

  test('роли с отдельным рабочим местом распознаются все четыре', () {
    for (final positionId in const [
      kManagerId,
      kWarehouseHeadId,
      kTechLeaderId,
      kCmmSpecialistId,
    ]) {
      expect(
        hasDedicatedWorkplaceRole(
          employee(id: positionId, positionIds: [positionId]),
        ),
        isTrue,
        reason: positionId,
      );
    }
  });

  test('обычная производственная должность ограничений не получает', () {
    expect(
      hasDedicatedWorkplaceRole(employee(id: 'e1', positionIds: const ['print'])),
      isFalse,
    );
  });

  test('в общее рабочее пространство попадают только производственные', () {
    final list = employeesForSharedWorkspace([
      employee(id: 'printer', positionIds: const ['print']),
      employee(id: 'packer', positionIds: const ['assembler']),
      employee(id: 'manager', positionIds: const [kManagerId]),
      employee(id: 'techlead', positionIds: const [kTechLeaderId]),
      employee(id: 'warehouse', positionIds: const [kWarehouseHeadId]),
      employee(id: 'cmm', positionIds: const [kCmmSpecialistId]),
    ]);

    expect(list.map((e) => e.id), ['printer', 'packer']);
  });

  test('уволенные и уже открытые исключаются', () {
    final list = employeesForSharedWorkspace(
      [
        employee(id: 'printer'),
        employee(id: 'fired', isFired: true),
        employee(id: 'already-open'),
      ],
      excludedIds: const {'already-open'},
    );

    expect(list.map((e) => e.id), ['printer']);
  });

  test('смешанные должности: спецроль перевешивает', () {
    // Карточка сотрудника не даёт выбрать спецроль вместе с обычной, но старые
    // записи такое сочетание содержать могут — в цех такой человек не идёт.
    expect(
      hasDedicatedWorkplaceRole(
        employee(id: 'e1', positionIds: const ['print', kManagerId]),
      ),
      isTrue,
    );
  });
}
