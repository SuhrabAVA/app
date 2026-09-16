/// Фильтр бумаги на складе по названию, формату и граммажу.
///
/// Раньше выбор в фильтре применялся только к вкладке «Список»: на
/// «Списаниях», «Приходах» и «Инвентаризации» кнопка «Применить» не меняла
/// ничего. К тому же значения сравнивались дословно, а словарь строился из
/// обрезанных строк — рулон с пробелом в конце названия не находился никогда.
///
/// Здесь одно правило для всех вкладок: сравнение без учёта регистра и лишних
/// пробелов, а формат и граммаж — как числа («24,5» = «24.5», «84.0» = «84»).
library;

/// Выбранные значения фильтра. Пустой набор — «любое значение».
class PaperMultiFilter {
  final Set<String> names = <String>{};
  final Set<String> formats = <String>{};
  final Set<String> grammages = <String>{};

  bool get isActive =>
      names.isNotEmpty || formats.isNotEmpty || grammages.isNotEmpty;

  int get selectedCount => names.length + formats.length + grammages.length;

  void clear() {
    names.clear();
    formats.clear();
    grammages.clear();
  }

  bool matches({required String name, String? format, String? grammage}) {
    return _matchesText(names, name) &&
        _matchesNumber(formats, format) &&
        _matchesNumber(grammages, grammage);
  }

  static bool _matchesText(Set<String> selected, String? value) {
    if (selected.isEmpty) return true;
    final key = normalizePaperText(value);
    if (key.isEmpty) return false;
    return selected.any((s) => normalizePaperText(s) == key);
  }

  static bool _matchesNumber(Set<String> selected, String? value) {
    if (selected.isEmpty) return true;
    final key = normalizePaperNumber(value);
    if (key.isEmpty) return false;
    return selected.any((s) => normalizePaperNumber(s) == key);
  }
}

/// Варианты для чипов фильтра: без повторов, по алфавиту. Из двух написаний
/// одного значения остаётся первое встреченное.
class PaperFilterOptions {
  const PaperFilterOptions({
    required this.names,
    required this.formats,
    required this.grammages,
  });

  final List<String> names;
  final List<String> formats;
  final List<String> grammages;

  factory PaperFilterOptions.from(
    Iterable<({String name, String? format, String? grammage})> rows,
  ) {
    final names = <String, String>{};
    final formats = <String, String>{};
    final grammages = <String, String>{};
    for (final row in rows) {
      _remember(names, row.name, normalizePaperText(row.name));
      _remember(formats, row.format, normalizePaperNumber(row.format));
      _remember(grammages, row.grammage, normalizePaperNumber(row.grammage));
    }
    return PaperFilterOptions(
      names: _sortedText(names.values),
      formats: _sortedNumbers(formats.values),
      grammages: _sortedNumbers(grammages.values),
    );
  }

  static void _remember(Map<String, String> into, String? raw, String key) {
    if (key.isEmpty) return;
    into.putIfAbsent(key, () => raw!.trim());
  }

  static List<String> _sortedText(Iterable<String> values) => values.toList()
    ..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));

  /// Форматы по величине: «10, 12, 84», а не «10, 12, 102, 84».
  static List<String> _sortedNumbers(Iterable<String> values) =>
      values.toList()
        ..sort((a, b) {
          final na = double.tryParse(normalizePaperNumber(a));
          final nb = double.tryParse(normalizePaperNumber(b));
          if (na != null && nb != null) return na.compareTo(nb);
          if (na != null) return -1;
          if (nb != null) return 1;
          return a.toLowerCase().compareTo(b.toLowerCase());
        });
}

/// Название: без регистра, пробелы по краям срезаны, внутренние схлопнуты.
String normalizePaperText(String? value) =>
    (value ?? '').trim().replaceAll(RegExp(r'\s+'), ' ').toLowerCase();

/// Формат/граммаж: число пишется одинаково независимо от запятой и хвоста
/// «.0». Не число — сравнивается как текст.
String normalizePaperNumber(String? value) {
  final text = normalizePaperText(value).replaceAll(',', '.');
  if (text.isEmpty) return '';
  final number = double.tryParse(text);
  if (number == null) return text;
  return number == number.truncateToDouble()
      ? number.toInt().toString()
      : number.toString();
}
