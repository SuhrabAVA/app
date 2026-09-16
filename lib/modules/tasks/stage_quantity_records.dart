/// Какие записи количества формируют ФАКТ по заказу (`orders.actual_qty`).
///
/// Записи количества в `tasks.comments` служат двум разным целям, и раньше их
/// не различали:
///
///   * **тираж этапа** — сколько реально сделано. Это `quantity_done`
///     (отдельный исполнитель), `quantity_team_total` (финал совместного
///     режима) и `quantity_share`, записанный на пересмене инициатором.
///   * **персональная доля** — сколько засчитано конкретному помощнику для
///     выработки и зарплаты. Это `quantity_share`, записанный на помощника:
///     RPC `complete_task_stage` пишет его каждому помощнику при завершении
///     совместного этапа.
///
/// Сумма по задаче складывала и то, и другое. На совместном этапе с одним
/// помощником в `orders.actual_qty` уходило 2Q вместо Q: доля помощника плюс
/// `quantity_team_total` владельца. Отгрузка и списания считаются от этого
/// числа, поэтому цена ошибки — реальный склад, а не только отчёт.
///
/// Роль определяется тем же правилом, что и в аналитике
/// (`AnalyticsRepository.loadAllMonthData`): помощник — автор комментария
/// `joined`, не совпадающий с первым в `assignees`. Единое правило важнее
/// точности эвристик: разъехавшись, аналитика и факт заказа дали бы два
/// разных ответа на вопрос «кто здесь помощник».
///
/// Новый учёт (`quantity_stage_total` + рассчитанные на сервере доли) делает
/// это разделение структурным: тираж лежит отдельной записью, а доли помечены
/// `generated` и в факт не идут — ни помощника, ни основного исполнителя.
library;

import 'quantity_status_service.dart' show tryDecodeQuantityPayload;

/// Тираж этапа: одна запись на сегмент (пересмена, завершение).
const String kStageTotalCommentType = 'quantity_stage_total';

/// Типы записей, из которых складывается количество этапа.
const Set<String> kOrderQuantityCommentTypes = <String>{
  kStageTotalCommentType,
  'quantity_share',
  'quantity_done',
  'quantity_team_total',
};

/// Число из текста записи количества.
///
/// Количество В ЕДИНИЦАХ РАБОЧЕГО МЕСТА — то, что засчитывается сотруднику.
///
/// Упаковки (`packs`) имеют приоритет: на упаковке сдельная считается за
/// упаковку, а подпись записи человеческая («12030 шт · 121 уп») — регулярка
/// вытащила бы из неё штуки и умножила выплату на фасовку.
///
/// Для вопроса «сколько сделано из тиража» нужен [parseStageQuantityActual]:
/// план упаковки задан в штуках, и сравнивать его с упаковками нельзя.
double parseStageQuantityText(String raw) {
  final packs = tryDecodeQuantityPayload(raw)?['packs'];
  if (packs is num && packs > 0) return packs.toDouble();
  return _quantityFromFreeText(raw);
}

/// Сколько СДЕЛАНО по заказу — в тех же единицах, в которых задан план этапа.
///
/// Второй парсер рядом с [parseStageQuantityText] заведён не по недосмотру: на
/// упаковке одна и та же запись отвечает на два разных вопроса.
///
///   * «сколько засчитать сотруднику» — УПАКОВКИ: коэффициент рабочего места
///     задан за упаковку и умножается прямо на это число в сдельной части
///     (см. `TaskAnalyticsMapper._parseQty`). Подменить их штуками значит
///     умножить выплату на фасовку;
///   * «сколько сделано из тиража» — ШТУКИ: план упаковки
///     ([getExpectedQuantity]) задан в штуках, потому что при некратном тираже
///     количество штук по числу упаковок уже не восстановить.
///
/// Пока парсер был один, второй вопрос получал ответ на первый: этап упаковки
/// на 4878 штук из 5000 показывался как «49 из 5000» и горел красным
/// «недодали −99 %», хотя недобор был 2 %.
///
/// `packs` остаётся запасным вариантом: у старых записей поля `actual` нет
/// вовсе, и там это единственное имеющееся число.
double parseStageQuantityActual(String raw) {
  final payload = tryDecodeQuantityPayload(raw);
  final actual = payload?['actual'];
  if (actual is num) return actual.toDouble();
  final packs = payload?['packs'];
  if (packs is num && packs > 0) return packs.toDouble();
  return _quantityFromFreeText(raw);
}

/// Число из человеческой подписи вроде «12030 шт · 121 уп» — запасной разбор
/// для записей без JSON-payload.
double _quantityFromFreeText(String raw) {
  final normalized = raw.replaceAll(',', '.').trim();
  final match = RegExp(r'-?[0-9]+(?:\.[0-9]+)?').firstMatch(normalized);
  if (match != null) return double.tryParse(match.group(0)!) ?? 0;
  return double.tryParse(normalized) ?? 0;
}

/// Исполнители задачи из сырого значения колонки `assignees`.
List<String> assigneesFromRaw(dynamic raw) {
  if (raw is! List) return const <String>[];
  final result = <String>[];
  for (final item in raw) {
    final value = (item?.toString() ?? '').trim();
    if (value.isNotEmpty) result.add(value);
  }
  return result;
}

/// Основной исполнитель (владелец) этапа — первый в `assignees`.
///
/// То же правило действует в рабочем пространстве: добавлять и удалять
/// помощников может только основной исполнитель.
String stageOwnerId(List<String> assignees) =>
    assignees.isEmpty ? '' : assignees.first;

/// Тип комментария.
String stageCommentType(Map<String, dynamic> comment) =>
    (comment['type'] ?? '').toString();

/// Автор комментария. Ключ приходит и в camelCase, и в snake_case.
String stageCommentUserId(Map<String, dynamic> comment) =>
    (comment['userId'] ?? comment['user_id'] ?? '').toString().trim();

/// Помощники задачи: авторы `joined`, не совпадающие с владельцем.
///
/// Удалённый помощник из `assignees` исчезает, но его `joined` остаётся —
/// поэтому его доля продолжает распознаваться как персональная.
Set<String> helperIdsFromComments({
  required List<String> assignees,
  required Iterable<Map<String, dynamic>> comments,
}) {
  final owner = stageOwnerId(assignees);
  // Владельца не определить — считаем, что помощников нет. Так задача без
  // `assignees` (легаси) ведёт себя ровно как до появления этого правила.
  if (owner.isEmpty) return const <String>{};

  final helpers = <String>{};
  for (final comment in comments) {
    if (stageCommentType(comment) != 'joined') continue;
    final userId = stageCommentUserId(comment);
    if (userId.isEmpty || userId == owner) continue;
    helpers.add(userId);
  }
  return helpers;
}

/// Рассчитанная сервером персональная доля (`recompute_task_quantity_shares`).
///
/// Помечается в payload флагом `generated`, чтобы её нельзя было спутать с
/// количеством, введённым человеком: доли пересчитываются идемпотентно, а
/// ручные записи и правки техлида — нет.
bool isGeneratedShare(Map<String, dynamic> comment) {
  final payload = tryDecodeQuantityPayload((comment['text'] ?? '').toString());
  return payload?['generated'] == true;
}

/// Идёт ли запись количества в факт по заказу.
///
/// Не идут:
///   * рассчитанные доли — их сумма превышает тираж (округление вверх), и
///     складывать их с самим тиражом значит считать этап дважды;
///   * доли помощников из старого учёта — там каждому писалось полное Q, и
///     сумма выходила тиражом, умноженным на число участников.
bool countsTowardOrderQuantity({
  required Map<String, dynamic> comment,
  required Set<String> helperIds,
}) {
  if (!kOrderQuantityCommentTypes.contains(stageCommentType(comment))) {
    return false;
  }
  if (isGeneratedShare(comment)) return false;
  if (helperIds.isEmpty) return true;
  return !helperIds.contains(stageCommentUserId(comment));
}
