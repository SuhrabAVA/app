/// Лёгкий период действия статуса сотрудника, используемый расчётом ЗП.
/// Отделён от EmployeeStatusHistoryRow модуля персонала (нет id/createdAt),
/// чтобы SalaryCalculator не зависел от формы строки чужого репозитория.
/// [dateTo] исключительна: период покрывает дни [dateFrom, dateTo).
/// null означает, что период ещё открыт (статус активен по сей день).
class EmployeeStatusPeriod {
  final String statusId;
  final DateTime dateFrom;
  final DateTime? dateTo;

  const EmployeeStatusPeriod({
    required this.statusId,
    required this.dateFrom,
    this.dateTo,
  });

  bool covers(DateTime day) {
    final d = DateTime(day.year, day.month, day.day);
    final from = DateTime(dateFrom.year, dateFrom.month, dateFrom.day);
    if (d.isBefore(from)) return false;
    final to = dateTo;
    if (to == null) return true;
    final toDate = DateTime(to.year, to.month, to.day);
    return d.isBefore(toDate);
  }
}
