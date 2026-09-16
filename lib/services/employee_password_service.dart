/// Проверка пароля сотрудника — на сервере.
///
/// Зачем файл: пароль сверялся в трёх местах приложения (вход, добавление
/// сотрудника во вкладку, добавление помощника) простым сравнением с
/// `employees.password`, который уезжал на каждое устройство открытым текстом.
/// Теперь сверяет `employee_verify_password` по bcrypt-хешу, которого
/// приложение не видит.
library;

import 'package:supabase_flutter/supabase_flutter.dart';

import '../utils/network_failures.dart';

/// Итог проверки пароля.
enum PasswordCheck {
  /// Пароль верный.
  accepted,

  /// Пароль неверный или сотрудник уволен.
  rejected,

  /// Сервер недоступен, проверить нечем.
  unavailable,
}

/// Вызов серверной проверки. Выделен, чтобы решение можно было проверить
/// тестом без сети.
typedef PasswordRpc = Future<Object?> Function(
    String employeeId, String password);

/// Решает, принят ли пароль.
///
/// [cachedPassword] — пароль из списка сотрудников, пока он ещё приходит на
/// устройство (стадия А). Используется ТОЛЬКО когда сервер недоступен: иначе
/// на цеховой сети без связи никто не смог бы войти. После стадии Б поле
/// придёт пустым, и без связи вход честно скажет «нет связи».
Future<PasswordCheck> checkEmployeePassword({
  required String employeeId,
  required String input,
  required PasswordRpc rpc,
  String? cachedPassword,
}) async {
  final entered = input.trim();
  if (employeeId.trim().isEmpty || entered.isEmpty) {
    return PasswordCheck.rejected;
  }
  try {
    final result = await rpc(employeeId, entered);
    return result == true ? PasswordCheck.accepted : PasswordCheck.rejected;
  } catch (error) {
    if (!isTransientNetworkFailure(error)) rethrow;
    final cached = (cachedPassword ?? '').trim();
    if (cached.isEmpty) return PasswordCheck.unavailable;
    return cached == entered ? PasswordCheck.accepted : PasswordCheck.rejected;
  }
}

/// Проверка пароля через Supabase.
Future<PasswordCheck> verifyEmployeePassword({
  required String employeeId,
  required String input,
  String? cachedPassword,
  SupabaseClient? client,
}) {
  final sb = client ?? Supabase.instance.client;
  return checkEmployeePassword(
    employeeId: employeeId,
    input: input,
    cachedPassword: cachedPassword,
    rpc: (id, password) => sb.rpc('employee_verify_password', params: {
      'p_employee_id': id,
      'p_password': password,
    }),
  );
}

/// Текст ошибки для диалога ввода пароля.
String? passwordCheckError(PasswordCheck check) => switch (check) {
      PasswordCheck.accepted => null,
      PasswordCheck.rejected => 'Неверный пароль',
      PasswordCheck.unavailable =>
        'Нет связи с сервером — пароль проверить нельзя. Повторите.',
    };
