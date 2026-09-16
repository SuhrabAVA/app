/// Комментарии об изменении бумаги и красок из рабочего пространства.
///
/// Текст комментария хранится структурированным пейлоадом (как `time_event`),
/// а не готовой строкой: в карточке заказа его рисует
/// `TaskChangeCommentBody` — со всеми полями материала, зачёркнутым старым
/// значением и подсвеченным новым. Для лент, которые умеют показывать только
/// текст (аналитика, история заказа), тот же пейлоад разворачивается в
/// [changeCommentPlainText].
///
/// Ничего не сокращаем: печатаются все поля, изменившиеся — выделяются.
library;

import 'dart:convert';

/// Что произошло со строкой материала.
enum ChangeRowOp { changed, added, removed }

/// Поле карточки: подпись («Ф», «Гр», «L») и значение. Пустая подпись —
/// значение печатается само по себе (количество краски с её комментарием).
class ChangeField {
  const ChangeField(this.label, this.value);

  final String label;
  final String value;

  /// «Ф 333» либо просто «180 г • ву».
  String get display => label.isEmpty ? value : '$label $value';

  Map<String, dynamic> toJson() => <String, dynamic>{'l': label, 'v': value};

  static ChangeField fromJson(Map<String, dynamic> json) => ChangeField(
        (json['l'] ?? '').toString(),
        (json['v'] ?? '').toString(),
      );

  @override
  bool operator ==(Object other) =>
      other is ChangeField && other.label == label && other.value == value;

  @override
  int get hashCode => Object.hash(label, value);
}

/// Одна строка изменения: «Бумага №1», «Краска №2».
class ChangeRow {
  const ChangeRow({
    required this.slot,
    required this.op,
    this.beforeName = '',
    this.afterName = '',
    this.before = const <ChangeField>[],
    this.after = const <ChangeField>[],
    this.delta = '',
  });

  final int slot;
  final ChangeRowOp op;

  /// Название до правки (пусто у добавленной строки).
  final String beforeName;

  /// Название после правки (пусто у удалённой строки).
  final String afterName;

  final List<ChangeField> before;
  final List<ChangeField> after;

  /// Готовая дельта количества, например «+50.00 м». Пусто — не показывать.
  final String delta;

  /// Название для показа: у изменённой строки — актуальное.
  String get name => afterName.isNotEmpty ? afterName : beforeName;

  /// Переименование материала — печатаем «было → стало» отдельно.
  bool get renamed =>
      op == ChangeRowOp.changed &&
      beforeName.isNotEmpty &&
      afterName.isNotEmpty &&
      beforeName != afterName;

  /// Подписи полей, значения которых изменились.
  Set<String> get changedLabels {
    if (op != ChangeRowOp.changed) return const <String>{};
    final afterByLabel = <String, String>{
      for (final field in after) field.label: field.value,
    };
    return <String>{
      for (final field in before)
        if (afterByLabel[field.label] != field.value) field.label,
    };
  }

  /// Поля со стороны «стало», которые действительно поменялись.
  List<ChangeField> get changedAfterFields {
    final labels = changedLabels;
    return <ChangeField>[
      for (final field in after)
        if (labels.contains(field.label)) field,
    ];
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
        'slot': slot,
        'op': op.name,
        if (beforeName.isNotEmpty) 'bn': beforeName,
        if (afterName.isNotEmpty) 'an': afterName,
        if (before.isNotEmpty)
          'b': before.map((f) => f.toJson()).toList(growable: false),
        if (after.isNotEmpty)
          'a': after.map((f) => f.toJson()).toList(growable: false),
        if (delta.isNotEmpty) 'd': delta,
      };

  static ChangeRow fromJson(Map<String, dynamic> json) {
    List<ChangeField> fields(Object? raw) => <ChangeField>[
          if (raw is List)
            for (final item in raw)
              if (item is Map)
                ChangeField.fromJson(Map<String, dynamic>.from(item)),
        ];
    final opName = (json['op'] ?? '').toString();
    return ChangeRow(
      slot: (json['slot'] as num?)?.toInt() ?? 0,
      op: ChangeRowOp.values.firstWhere(
        (value) => value.name == opName,
        orElse: () => ChangeRowOp.changed,
      ),
      beforeName: (json['bn'] ?? '').toString(),
      afterName: (json['an'] ?? '').toString(),
      before: fields(json['b']),
      after: fields(json['a']),
      delta: (json['d'] ?? '').toString(),
    );
  }
}

/// Разобранный комментарий об изменении.
class ChangeComment {
  const ChangeComment({
    required this.kind,
    required this.reason,
    required this.rows,
  });

  /// `paper` или `paint`.
  final String kind;
  final String reason;
  final List<ChangeRow> rows;

  bool get isPaper => kind == 'paper';

  /// Заголовок карточки — как раньше в первой строке текста.
  String get title => isPaper
      ? 'Изменение бумаги из рабочего пространства'
      : 'Изменение красок из рабочего пространства';

  /// «Бумага» / «Краска» — префикс номера строки.
  String get rowLabel => isPaper ? 'Бумага' : 'Краска';
}

const String _payloadMarker = 'workspace_change';

/// Сериализация пейлоада в текст комментария.
String encodeChangeComment(ChangeComment comment) => jsonEncode(<String, dynamic>{
      't': _payloadMarker,
      'v': 1,
      'kind': comment.kind,
      'reason': comment.reason,
      'rows': comment.rows.map((row) => row.toJson()).toList(growable: false),
    });

/// Разбор текста комментария. null — это не наш пейлоад (старый
/// комментарий обычным текстом либо чужой формат): такой текст показывается
/// как есть, ничего не теряя.
ChangeComment? decodeChangeComment(String text) {
  final trimmed = text.trim();
  if (!trimmed.startsWith('{') || !trimmed.contains(_payloadMarker)) return null;
  try {
    final decoded = jsonDecode(trimmed);
    if (decoded is! Map) return null;
    final map = Map<String, dynamic>.from(decoded);
    if ((map['t'] ?? '').toString() != _payloadMarker) return null;
    final rawRows = map['rows'];
    return ChangeComment(
      kind: (map['kind'] ?? 'paper').toString(),
      reason: (map['reason'] ?? '').toString(),
      rows: <ChangeRow>[
        if (rawRows is List)
          for (final item in rawRows)
            if (item is Map) ChangeRow.fromJson(Map<String, dynamic>.from(item)),
      ],
    );
  } catch (_) {
    return null;
  }
}

/// Текстовое представление для лент без богатого рендерера.
String changeCommentPlainText(ChangeComment comment) {
  final lines = <String>['${comment.title}.'];
  for (final row in comment.rows) {
    final prefix = '${comment.rowLabel} №${row.slot}';
    switch (row.op) {
      case ChangeRowOp.added:
        lines.add('$prefix добавлена: ${row.name}'
            '${_fieldsText(row.after, leading: ', ')}');
      case ChangeRowOp.removed:
        lines.add('$prefix удалена: ${row.name}'
            '${_fieldsText(row.before, leading: ', ')}');
      case ChangeRowOp.changed:
        final head = row.renamed
            ? '${row.beforeName} → ${row.afterName}'
            : row.name;
        // Значения «до» уже напечатаны полностью — после стрелки идут только
        // новые, иначе то же самое повторялось бы дважды.
        final changes = row.changedAfterFields
            .map((field) => field.display)
            .join(', ');
        final delta = row.delta.isEmpty ? '' : ' (Δ ${row.delta})';
        lines.add('$prefix $head'
            '${_fieldsText(row.before, leading: ': ')}'
            '${changes.isEmpty ? '' : ' → $changes'}$delta');
    }
  }
  if (comment.reason.trim().isNotEmpty) {
    lines.add('Причина: ${comment.reason.trim()}');
  }
  return lines.join('\n');
}

String _fieldsText(List<ChangeField> fields, {required String leading}) {
  if (fields.isEmpty) return '';
  return '$leading${fields.map((f) => f.display).join(', ')}';
}

// --------------------------------------------------------------- построение

/// Строка бумаги в том виде, в каком её сравнивает комментарий.
class PaperChangeRow {
  const PaperChangeRow({
    required this.name,
    this.format,
    this.grammage,
    this.widthB,
    this.blQuantity,
    required this.lengthMeters,
  });

  final String name;
  final String? format;
  final String? grammage;

  /// Ширина «Ш» из бобинорезки.
  final double? widthB;

  /// Количество «К» — свободная строка из карточки заказа.
  final String? blQuantity;

  /// Длина «L», метры.
  final double lengthMeters;
}

/// Строка краски.
class PaintChangeRow {
  const PaintChangeRow({
    required this.name,
    this.grams,
    this.info,
  });

  final String name;
  final double? grams;
  final String? info;
}

/// Число без хвостовых нулей: 333.0 → «333», 22.5 → «22.5».
String formatChangeNumber(double? value) {
  if (value == null || value <= 0) return '—';
  if (value == value.roundToDouble()) return value.toStringAsFixed(0);
  return value
      .toStringAsFixed(2)
      .replaceFirst(RegExp(r'0+$'), '')
      .replaceFirst(RegExp(r'\.$'), '');
}

String _name(String value) {
  final trimmed = value.trim();
  return trimmed.isEmpty ? 'Без названия' : trimmed;
}

String _orDash(String? value) {
  final trimmed = (value ?? '').trim();
  return trimmed.isEmpty ? '—' : trimmed;
}

List<ChangeField> _paperFields(PaperChangeRow row) => <ChangeField>[
      ChangeField('Ф', _orDash(row.format)),
      ChangeField('Гр', _orDash(row.grammage)),
      ChangeField('Ш', formatChangeNumber(row.widthB)),
      ChangeField('К', _orDash(row.blQuantity)),
      ChangeField('L', '${row.lengthMeters.toStringAsFixed(2)} м'),
    ];

/// Количество и комментарий краски идут одним значением: правка любой из
/// половин меняет строку целиком, и в карточке это одна пара «было → стало».
List<ChangeField> _paintFields(PaintChangeRow row) {
  final grams = row.grams;
  final qty = grams == null || grams <= 0
      ? '— г'
      : '${formatChangeNumber(grams)} г';
  final info = (row.info ?? '').trim();
  return <ChangeField>[
    ChangeField('', info.isEmpty ? qty : '$qty • $info'),
  ];
}

String _deltaText(double before, double after) {
  final delta = after - before;
  if (delta == 0) return '';
  final sign = delta > 0 ? '+' : '−';
  return '$sign${delta.abs().toStringAsFixed(2)} м';
}

/// Комментарий об изменении бумаги.
String buildPaperChangeComment({
  required List<PaperChangeRow> before,
  required List<PaperChangeRow> after,
  required String reason,
}) =>
    encodeChangeComment(ChangeComment(
      kind: 'paper',
      reason: reason,
      rows: _rows<PaperChangeRow>(
        before: before,
        after: after,
        fields: _paperFields,
        nameOf: (row) => _name(row.name),
        delta: (oldRow, newRow) =>
            _deltaText(oldRow.lengthMeters, newRow.lengthMeters),
      ),
    ));

/// Комментарий об изменении красок.
String buildPaintChangeComment({
  required List<PaintChangeRow> before,
  required List<PaintChangeRow> after,
  required String reason,
}) =>
    encodeChangeComment(ChangeComment(
      kind: 'paint',
      reason: reason,
      rows: _rows<PaintChangeRow>(
        before: before,
        after: after,
        fields: _paintFields,
        nameOf: (row) => _name(row.name),
        delta: (_, __) => '',
      ),
    ));

List<ChangeRow> _rows<T>({
  required List<T> before,
  required List<T> after,
  required List<ChangeField> Function(T row) fields,
  required String Function(T row) nameOf,
  required String Function(T oldRow, T newRow) delta,
}) {
  final rows = <ChangeRow>[];
  final maxLen = before.length > after.length ? before.length : after.length;
  for (var i = 0; i < maxLen; i++) {
    final oldRow = i < before.length ? before[i] : null;
    final newRow = i < after.length ? after[i] : null;
    final slot = i + 1;
    if (oldRow != null && newRow != null) {
      rows.add(ChangeRow(
        slot: slot,
        op: ChangeRowOp.changed,
        beforeName: nameOf(oldRow),
        afterName: nameOf(newRow),
        before: fields(oldRow),
        after: fields(newRow),
        delta: delta(oldRow, newRow),
      ));
    } else if (newRow != null) {
      rows.add(ChangeRow(
        slot: slot,
        op: ChangeRowOp.added,
        afterName: nameOf(newRow),
        after: fields(newRow),
      ));
    } else if (oldRow != null) {
      rows.add(ChangeRow(
        slot: slot,
        op: ChangeRowOp.removed,
        beforeName: nameOf(oldRow),
        before: fields(oldRow),
      ));
    }
  }
  return rows;
}
