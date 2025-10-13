/// Simple descriptor for an employee that can be mentioned in chat messages.
class ChatMentionCandidate {
  final String id;
  final String displayName;
  final String _normalizedPrimary;
  final String _normalizedAlt;

  ChatMentionCandidate({
    required this.id,
    required this.displayName,
    required String primarySearch,
    required String altSearch,
  })  : _normalizedPrimary = _normalize(primarySearch),
        _normalizedAlt = _normalize(altSearch);

  /// Normalizes a string for search comparisons.
  static String _normalize(String value) {
    final cleaned = value
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-z0-9а-яё\s]'), ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    return cleaned;
  }

  /// Returns `true` if this candidate matches the provided [query].
  bool matches(String query) {
    final normalized = _normalize(query);
    if (normalized.isEmpty) return true;
    final parts = normalized.split(' ');
    return parts.every((p) =>
        p.isEmpty ||
        _normalizedPrimary.contains(p) ||
        _normalizedAlt.contains(p));
  }

  /// Creates a candidate from raw employee data stored in Supabase.
  factory ChatMentionCandidate.fromEmployeeRow(
    String id,
    Map<String, dynamic> data,
  ) {
    final last = (data['lastName'] ?? '').toString();
    final first = (data['firstName'] ?? '').toString();
    final patr = (data['patronymic'] ?? '').toString();
    final primary = [last, first, patr]
        .where((p) => p.trim().isNotEmpty)
        .map((p) => p.trim())
        .join(' ');
    final alt = [first, last, patr]
        .where((p) => p.trim().isNotEmpty)
        .map((p) => p.trim())
        .join(' ');
    final display = primary.isNotEmpty ? primary : alt;
    return ChatMentionCandidate(
      id: id,
      displayName: display,
      primarySearch: display,
      altSearch: alt,
    );
  }
}
