/// Fixed UTC offset for Kostanay (UTC+6 without daylight saving time).
const Duration kKostanayUtcOffset = Duration(hours: 6);

/// Returns current date & time converted to Kostanay timezone.
DateTime nowInKostanay() {
  final utcNow = DateTime.now().toUtc();
  return utcNow.add(kKostanayUtcOffset);
}

/// Returns an ISO-8601 string for the current Kostanay time.
String nowInKostanayIsoString() => nowInKostanay().toIso8601String();

/// Converts any [dateTime] to Kostanay time keeping the same instant.
DateTime toKostanayTime(DateTime dateTime) {
  final utc = dateTime.isUtc ? dateTime : dateTime.toUtc();
  return utc.add(kKostanayUtcOffset);
}
