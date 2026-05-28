/// Тип оплаты сотрудника.
enum PayType { salary, piece, mixed }

PayType? parsePayType(String? raw) {
  switch ((raw ?? '').trim().toLowerCase()) {
    case 'salary':
    case 'оклад':
      return PayType.salary;
    case 'piece':
    case 'piecework':
    case 'сдельная':
      return PayType.piece;
    case 'mixed':
    case 'смешанная':
      return PayType.mixed;
    default:
      return null;
  }
}

String payTypeToString(PayType type) {
  switch (type) {
    case PayType.salary:
      return 'salary';
    case PayType.piece:
      return 'piece';
    case PayType.mixed:
      return 'mixed';
  }
}

String payTypeLabel(PayType type) {
  switch (type) {
    case PayType.salary:
      return 'Оклад';
    case PayType.piece:
      return 'Сдельная';
    case PayType.mixed:
      return 'Смешанная';
  }
}
