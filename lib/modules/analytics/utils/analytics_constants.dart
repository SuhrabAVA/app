class AnalyticsConstants {
  AnalyticsConstants._();

  /// Стандартное начало дневной смены.
  static const int dayShiftStartMinutes = 8 * 60; // 08:00

  /// Стандартное окончание дневной смены (без переработки).
  static const int dayShiftEndMinutes = 20 * 60; // 20:00

  /// Стандартное начало ночной смены.
  static const int nightShiftStartMinutes = 20 * 60; // 20:00

  /// Часов в сутках, в минутах.
  static const int dayMinutes = 24 * 60;

  /// Длительность смены (12 часов).
  static const int shiftMinutes = 12 * 60;

  /// Половина смены (после неё смена считается отработанной).
  static const int halfShiftMinutes = 6 * 60;

  /// Тревога: если после старта смены нет активности
  /// дольше указанного числа минут — подсветить красным.
  static const int noActivityAlertMinutes = 60;

  /// Идентификатор фильтра "все рабочие места" в деталке сотрудника.
  static const String allWorkplaces = '__all__';

  /// Имя claim-комментария в комментариях задачи.
  static const String claimCommentType = 'claim';
}
