/// Чтение и правка справочника дополнительных опций заказа.
///
/// Версий и черновиков у этих таблиц нет: правка действует сразу — так
/// заказчик и просил («добавил вариант — он появился в новых заказах»).
/// Обоснование, почему здесь это безопасно, а у настроек типа продукта нет, —
/// в шапке миграции 20260910_order_extra_options.sql.
library;

import 'package:supabase_flutter/supabase_flutter.dart';

import 'order_extra_options.dart';

/// Отказ, который нужно показать техлиду словами, а не кодом ошибки.
class OrderExtraOptionsFailure implements Exception {
  const OrderExtraOptionsFailure(this.message);

  final String message;

  @override
  String toString() => message;
}

class OrderExtraOptionsRepository {
  OrderExtraOptionsRepository({SupabaseClient? client})
      : _sb = client ?? Supabase.instance.client;

  final SupabaseClient _sb;

  static const String _defs = 'order_option_defs';
  static const String _values = 'order_option_values';
  static const String _defColumns =
      'id, product_type_id, title, kind, sort_order, is_active';
  static const String _valueColumns =
      'id, option_id, title, sort_order, is_active';

  /// Шаг между соседними позициями. Не 1: вставка между двумя строками без
  /// перенумерации всего списка тогда невозможна.
  static const int orderStep = 10;

  /// Действующие опции типа продукта вместе со ВСЕМИ их вариантами.
  ///
  /// Снятые с учёта варианты приходят намеренно: их отсеивает
  /// [buildOrderExtraOptionRows], но выбранный когда-то вариант обязан
  /// сохраниться в списке выбора, иначе правка старого заказа сбросит
  /// значение. Опции же грузятся только действующие — заказу, где значение
  /// выбрано, справочник для показа не нужен, он держит снимок.
  Future<List<OrderOptionDef>> loadForProductType(String productTypeId) async {
    final id = productTypeId.trim();
    if (id.isEmpty) return const <OrderOptionDef>[];

    final defRows = await _sb
        .from(_defs)
        .select(_defColumns)
        .eq('product_type_id', id)
        .eq('is_active', true)
        .order('sort_order');

    final defMaps = <Map<String, dynamic>>[
      for (final row in (defRows as List)) Map<String, dynamic>.from(row as Map),
    ];
    if (defMaps.isEmpty) return const <OrderOptionDef>[];

    final ids = <String>[
      for (final map in defMaps) (map['id'] ?? '').toString(),
    ]..removeWhere((value) => value.isEmpty);

    final valueRows = await _sb
        .from(_values)
        .select(_valueColumns)
        .inFilter('option_id', ids)
        .order('sort_order');

    final valuesByOption = <String, List<OrderOptionValue>>{};
    for (final row in (valueRows as List)) {
      final map = Map<String, dynamic>.from(row as Map);
      final parsed = OrderOptionValue.tryFromMap(map);
      if (parsed == null) continue;
      final optionId = (map['option_id'] ?? '').toString();
      valuesByOption.putIfAbsent(optionId, () => <OrderOptionValue>[]).add(parsed);
    }

    final result = <OrderOptionDef>[];
    for (final map in defMaps) {
      final def = OrderOptionDef.tryFromMap(
        map,
        values: valuesByOption[(map['id'] ?? '').toString()] ??
            const <OrderOptionValue>[],
      );
      if (def != null) result.add(def);
    }
    return result;
  }

  // ===== Опции =====

  Future<void> createOption({
    required String productTypeId,
    required String title,
    required String kind,
    required int sortOrder,
  }) =>
      _guard(
        () => _sb.from(_defs).insert(<String, dynamic>{
          'product_type_id': productTypeId,
          'title': title.trim(),
          'kind': kind,
          'sort_order': sortOrder,
        }),
        duplicate: 'Опция с таким названием у этого типа продукта уже есть.',
      );

  Future<void> renameOption({required String id, required String title}) =>
      _guard(
        () => _sb.from(_defs).update(<String, dynamic>{
          'title': title.trim(),
        }).eq('id', id),
        duplicate: 'Опция с таким названием у этого типа продукта уже есть.',
      );

  /// Мягкое удаление: опция уходит из формы новых заказов, а заказы со
  /// снимком продолжают показывать выбранное значение.
  Future<void> retireOption(String id) => _guard(
        () => _sb.from(_defs).update(<String, dynamic>{
          'is_active': false,
        }).eq('id', id),
      );

  Future<void> saveOptionOrder(List<String> idsInOrder) =>
      _saveOrder(_defs, idsInOrder);

  // ===== Варианты =====

  Future<void> createValue({
    required String optionId,
    required String title,
    required int sortOrder,
  }) =>
      _guard(
        () => _sb.from(_values).insert(<String, dynamic>{
          'option_id': optionId,
          'title': title.trim(),
          'sort_order': sortOrder,
        }),
        duplicate: 'Такой вариант у этой опции уже есть.',
      );

  Future<void> renameValue({required String id, required String title}) =>
      _guard(
        () => _sb.from(_values).update(<String, dynamic>{
          'title': title.trim(),
        }).eq('id', id),
        duplicate: 'Такой вариант у этой опции уже есть.',
      );

  Future<void> retireValue(String id) => _guard(
        () => _sb.from(_values).update(<String, dynamic>{
          'is_active': false,
        }).eq('id', id),
      );

  Future<void> saveValueOrder(List<String> idsInOrder) =>
      _saveOrder(_values, idsInOrder);

  /// Перенумерация списка по его новому порядку.
  ///
  /// Строк здесь единицы, поэтому цикл обновлений дешевле и понятнее, чем
  /// upsert: последний потребовал бы тащить в запрос все обязательные колонки
  /// и легко перетёр бы то, чего перетирать не просили.
  Future<void> _saveOrder(String table, List<String> idsInOrder) async {
    for (var index = 0; index < idsInOrder.length; index++) {
      await _guard(
        () => _sb.from(table).update(<String, dynamic>{
          'sort_order': index * orderStep,
        }).eq('id', idsInOrder[index]),
      );
    }
  }

  /// Превращает отказ Postgres в текст для техлида.
  ///
  /// 23505 — единственный код, который здесь ловится по смыслу: частичные
  /// уникальные индексы по названию стоят и на опциях, и на вариантах, и
  /// натыкается на них техлид регулярно. Остальное уходит наверх как есть.
  Future<void> _guard(
    Future<Object?> Function() action, {
    String? duplicate,
  }) async {
    try {
      await action();
    } on PostgrestException catch (e) {
      if (e.code == '23505' && duplicate != null) {
        throw OrderExtraOptionsFailure(duplicate);
      }
      throw OrderExtraOptionsFailure(e.message);
    }
  }
}
