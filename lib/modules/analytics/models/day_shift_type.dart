enum DayShiftType { day, night, off }

DayShiftType parseShiftType(String? raw) {
  switch ((raw ?? '').trim().toLowerCase()) {
    case 'day':
      return DayShiftType.day;
    case 'night':
      return DayShiftType.night;
    case 'off':
    default:
      return DayShiftType.off;
  }
}

String shiftTypeToString(DayShiftType type) {
  switch (type) {
    case DayShiftType.day:
      return 'day';
    case DayShiftType.night:
      return 'night';
    case DayShiftType.off:
      return 'off';
  }
}

String shiftTypeLabel(DayShiftType type) {
  switch (type) {
    case DayShiftType.day:
      return 'день';
    case DayShiftType.night:
      return 'ночь';
    case DayShiftType.off:
      return 'выходной';
  }
}
