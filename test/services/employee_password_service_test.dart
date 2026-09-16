import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sheet_clone/services/employee_password_service.dart';

void main() {
  group('checkEmployeePassword', () {
    test('решает сервер, а не пароль из списка сотрудников', () async {
      // Регрессия: пароль сравнивался с employees.password на устройстве.
      // Сервер отвечает «неверно» — локальное совпадение не спасает.
      final check = await checkEmployeePassword(
        employeeId: 'e1',
        input: '1234',
        cachedPassword: '1234',
        rpc: (_, __) async => false,
      );
      expect(check, PasswordCheck.rejected);
    });

    test('сервер принимает — вход разрешён', () async {
      String? sent;
      final check = await checkEmployeePassword(
        employeeId: 'e1',
        input: '  1234 ',
        rpc: (_, password) async {
          sent = password;
          return true;
        },
      );
      expect(check, PasswordCheck.accepted);
      expect(sent, '1234', reason: 'ввод обрезается, как в прежнем диалоге');
    });

    test('без связи — сверка с паролем из списка (стадия А)', () async {
      final ok = await checkEmployeePassword(
        employeeId: 'e1',
        input: '1234',
        cachedPassword: '1234',
        rpc: (_, __) async => throw const SocketException('Failed host lookup'),
      );
      final wrong = await checkEmployeePassword(
        employeeId: 'e1',
        input: '9999',
        cachedPassword: '1234',
        rpc: (_, __) async => throw const SocketException('Failed host lookup'),
      );
      expect(ok, PasswordCheck.accepted);
      expect(wrong, PasswordCheck.rejected);
    });

    test('без связи и без локального пароля — «нет связи», не «неверно»', () async {
      final check = await checkEmployeePassword(
        employeeId: 'e1',
        input: '1234',
        cachedPassword: '',
        rpc: (_, __) async => throw const SocketException('timed out'),
      );
      expect(check, PasswordCheck.unavailable);
      expect(passwordCheckError(check), contains('Нет связи'));
    });

    test('ошибка сервера (не связь) не превращается в локальную сверку', () async {
      expect(
        () => checkEmployeePassword(
          employeeId: 'e1',
          input: '1234',
          cachedPassword: '1234',
          rpc: (_, __) async => throw StateError('permission denied'),
        ),
        throwsStateError,
      );
    });

    test('пустой ввод отклоняется без запроса', () async {
      var called = false;
      final check = await checkEmployeePassword(
        employeeId: 'e1',
        input: '   ',
        rpc: (_, __) async {
          called = true;
          return true;
        },
      );
      expect(check, PasswordCheck.rejected);
      expect(called, isFalse);
    });
  });
}
