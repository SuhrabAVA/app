import 'package:supabase_flutter/supabase_flutter.dart';

import '../orders/product_type_route.dart';

/// Записи редактора маршрута — отдельно от состояния и вёрстки вкладки.
///
/// Вкладка перестала помещаться в лимит 500 строк, когда к панели рабочих
/// мест добавились условия, под-этапы и добавление этапа. Здесь только
/// обращения к базе: никаких диалогов и снекбаров — подтверждение и отчёт
/// остаются во вкладке, рядом с контекстом.
///
/// Все методы адресуют строки по id из уже загруженного маршрута. Это
/// безопасно ровно потому, что вкладка не даёт себя вызвать, пока не
/// убедится, что маршрут загружен из ЧЕРНОВИКА, а не из опубликованной
/// версии — см. `_canEdit`.
class ProductTypeStageActions {
  const ProductTypeStageActions(this._sb);

  final SupabaseClient _sb;

  // ── Этап ──────────────────────────────────────────────────────────────────

  Future<void> setEnabled(RouteStage stage, bool value) =>
      _sb.from('product_type_stages')
          .update({'is_enabled': value}).eq('id', stage.rowId);

  Future<void> deleteStage(String stageRowId) =>
      _sb.from('product_type_stages').delete().eq('id', stageRowId);

  /// Режим очерёдности и партнёр пишутся ОДНИМ оператором.
  ///
  /// Порознь между ними существовало бы состояние «параллельно без партнёра»
  /// или «партнёр без режима» — оба ловятся валидатором, но чинить их пришлось
  /// бы техлиду. Партнёр обнуляется явно для всех режимов, кроме
  /// `parallel_with`: оставленная ссылка означала бы, что смена режима туда и
  /// обратно молча вернула бы старого партнёра.
  Future<void> setExecution(
    String stageRowId,
    String mode,
    String? partnerRowId,
  ) =>
      _sb.from('product_type_stages').update({
        'execution_mode': mode,
        'parallel_with_stage_id': mode == 'parallel_with' ? partnerRowId : null,
      }).eq('id', stageRowId);

  /// Формула фактического количества версии настроек.
  Future<void> setFormula(String configId, String formula) =>
      _sb.from('product_type_configs').update({
        'actual_qty_formula': formula,
      }).eq('id', configId);

  /// Создаёт этап с одним рабочим местом.
  ///
  /// Общий путь для этапа верхнего уровня, под-этапа варианта и этапа-группы:
  /// различаются только ключом, подписью и родителем.
  ///
  /// Ранг НЕ передаётся: его выдаёт сервер и он же сдвигает закреплённый этап
  /// на ранг выше. Раньше ранг считал клиент как «максимум незакреплённых плюс
  /// один», и после уплотнения рангов это ровно ранг упаковки — новый этап
  /// слипся бы с ней в одну группу и стал неперемещаемым.
  Future<void> insertStage({
    required String configId,
    required String stageGroupKey,
    required String title,
    required String workplaceId,
    String? parentVariantId,
  }) =>
      _sb.rpc('insert_product_type_stage', params: {
        'p_config_id': configId,
        'p_stage_group_key': stageGroupKey,
        'p_title': title,
        'p_workplace_id': workplaceId,
        'p_parent_variant_id': parentVariantId,
      });

  // ── Рабочие места ─────────────────────────────────────────────────────────

  Future<void> addWorkplace({
    required RouteStage stage,
    required String workplaceId,
    required String? variantTitle,
    required int sortOrder,
  }) =>
      _sb.from('product_type_stage_workplaces').insert({
        'stage_id': stage.rowId,
        'workplace_id': workplaceId,
        if (variantTitle != null) 'variant_title': variantTitle,
        'is_default': false,
        'sort_order': sortOrder,
      });

  /// Обычный DELETE: он атомарен сам по себе, и каскад на под-этапы — его
  /// часть. Опасна была не потеря атомарности, а тишина, поэтому перечисление
  /// того, что уйдёт, показывает диалог ДО вызова.
  Future<void> removeWorkplace(String workplaceRowId) => _sb
      .from('product_type_stage_workplaces')
      .delete()
      .eq('id', workplaceRowId);

  Future<void> setDefaultVariant(String variantRowId) =>
      _sb.rpc('set_product_type_stage_default_variant',
          params: {'p_variant_id': variantRowId});

  /// Возвращает число удалённых под-этапов — UI отчитывается фактом, а не
  /// обещанием из диалога.
  Future<int> setSelectionMode(String stageRowId, String mode) async {
    final deleted = await _sb.rpc('set_product_type_stage_selection_mode',
        params: {'p_stage_id': stageRowId, 'p_mode': mode});
    return (deleted as num?)?.toInt() ?? 0;
  }

  // ── Порядок, условие, копирование ─────────────────────────────────────────

  /// Перенумерация всей последовательности групп одним заходом: раздельные
  /// UPDATE оставили бы при обрыве два этапа на одной позиции, а раздача
  /// позиций только уровню 0 сталкивала бы ручки с под-этапами вариантов.
  Future<void> setPositions(String configId, List<List<String>> groups) =>
      _sb.rpc('set_product_type_stage_positions',
          params: {'p_config_id': configId, 'p_ordered_groups': groups});

  /// `predicate = null` означает «всегда»: строки условий удаляются.
  Future<void> setCondition(
    String stageRowId,
    String? predicate,
    String? param,
  ) =>
      _sb.rpc('set_product_type_stage_condition', params: {
        'p_stage_id': stageRowId,
        'p_predicate': predicate,
        'p_param': param,
      });

  /// Возвращает число скопированных: функция пропускает под-этапы с уже
  /// занятым ключом, поэтому обещанное и реальное могут не совпасть.
  Future<int> copyVariantSubStages(String fromRowId, String toRowId) async {
    final copied = await _sb.rpc('copy_variant_sub_stages',
        params: {'p_from_variant_id': fromRowId, 'p_to_variant_id': toRowId});
    return (copied as num?)?.toInt() ?? 0;
  }
}
