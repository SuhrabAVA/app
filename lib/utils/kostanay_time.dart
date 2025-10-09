/// Fixed UTC offset for Kostanay (UTC+5 without daylight saving time).
const Duration kKostanayUtcOffset = Duration(hours: 5);

/// Returns current date & time converted to Kostanay timezone.
DateTime nowInKostanay() {
  final utcNow = DateTime.now().toUtc();
  return utcNow.add(kKostanayUtcOffset);
}

/// Returns an ISO-8601 string for the current Kostanay time.
String nowInKostanayIsoString() {
  final utcNow = DateTime.now().toUtc();
  final kostanayUtc = utcNow.add(kKostanayUtcOffset);
  final iso = kostanayUtc.toIso8601String();
  final offsetMinutes = kKostanayUtcOffset.inMinutes;
  final sign = offsetMinutes < 0 ? '-' : '+';
  final absMinutes = offsetMinutes.abs();
  final hours = absMinutes ~/ 60;
  final minutes = absMinutes % 60;
  final suffix = '$sign${_twoDigits(hours)}:${_twoDigits(minutes)}';
  return iso.endsWith('Z')
      ? iso.substring(0, iso.length - 1) + suffix
      : '$iso$suffix';
}

/// Converts any [dateTime] to Kostanay time keeping the same instant.
DateTime toKostanayTime(DateTime dateTime) {
  final utc = dateTime.isUtc ? dateTime : dateTime.toUtc();
  return utc.add(kKostanayUtcOffset);
}

String _twoDigits(int value) => value.toString().padLeft(2, '0');

/// Formats an ISO timestamp into `yyyy-MM-dd HH:mm` using Kostanay time.
///
/// Returns [fallback] when [isoString] is `null` or empty. If [isoString]
/// cannot be parsed, returns the original trimmed string.
String formatKostanayTimestamp(String? isoString, {String fallback = '—'}) {
  final raw = isoString?.trim();
  if (raw == null || raw.isEmpty) return fallback;

  final parsed = DateTime.tryParse(raw);
  if (parsed == null) return raw;

  final utc = parsed.isUtc ? parsed : parsed.toUtc();
  final kostanay = utc.add(kKostanayUtcOffset);

  return '${kostanay.year}-${_twoDigits(kostanay.month)}-${_twoDigits(kostanay.day)} '
      '${_twoDigits(kostanay.hour)}:${_twoDigits(kostanay.minute)}';
}
