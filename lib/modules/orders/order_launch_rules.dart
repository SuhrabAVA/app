import '../warehouse/tmc_model.dart';
import 'material_model.dart';
import 'order_model.dart';

/// Returns whether the order can be launched from the orders list UI.
///
/// The UI gates launching by assignment/status, queue build state, and
/// available material. OrdersProvider.launchOrder repeats the queue check
/// against persisted data before creating tasks.
bool canLaunchOrder(OrderModel order, Iterable<TmcModel> allTmc) {
  if (order.assignmentCreated ||
      order.statusEnum != OrderStatus.ready_to_start ||
      QueueBuildStatus.normalize(order.queueBuildStatus) !=
          QueueBuildStatus.built) {
    return false;
  }

  final String? materialId = order.material?.id;
  final double requiredLength = (order.product.length ?? 0).toDouble();
  if (materialId == null || materialId.isEmpty || requiredLength <= 0) {
    return true;
  }

  final matches = allTmc.where((t) => t.id == materialId).toList();
  if (matches.isEmpty) return false;
  return matches.first.quantity >= requiredLength;
}

/// Строка краски заказа в том виде, в каком её проверяют правила запуска.
///
/// Отдельный тип нужен, чтобы правило не зависело ни от формы редактирования
/// (там своя изменяемая запись со ссылкой на склад), ни от таблицы
/// `order_paints` (там граммовка хранится килограммами в `qty_kg`).
class OrderPaintLine {
  const OrderPaintLine({required this.name, required this.qtyGrams});

  /// Название краски. Пустое означает пустой слот, а не позицию заказа.
  final String name;

  /// Граммовка. `null` — поле не заполнено вовсе.
  final double? qtyGrams;
}

/// Названия позиций, где материал выбран, а количество не указано.
///
/// Для бумаги это «Длина L», для краски — граммовка. Обе величины идут в бронь
/// и в списание со склада, и без них заказ невозможно ни обеспечить, ни
/// посчитать: [canLaunchOrder] и `_hasEnoughMaterialForLaunch` пропускают
/// позицию с нулевой потребностью как «нехватки нет», а `syncPaintReservations`
/// вообще не создаёт строку брони для краски без граммов. Пустая клетка молча
/// означала «всего хватает», и заказ уходил в «Готов к запуску» без единой
/// проверки материала. В базе такими оказались 7 заказов в производстве с
/// красками без граммовки (6 — вообще без строк брони) и 3 заказа без «Длины L».
///
/// Поэтому неполнота — не нехватка материала, а незаконченный заказ: правильный
/// для него статус — черновик.
///
/// Пустые слоты пропускаются: строка без названия и без id — это не позиция, а
/// заготовка, которую сотрудник ещё не заполнил.
List<String> materialsWithoutQuantity({
  required Iterable<MaterialModel> papers,
  required Iterable<OrderPaintLine> paints,
}) {
  final missing = <String>[];

  for (final paper in papers) {
    final name = paper.name.trim();
    final id = (paper.id ?? '').trim();
    if (name.isEmpty && id.isEmpty) continue;
    if (paper.quantity > 0) continue;
    missing.add(name.isEmpty ? 'бумага без названия' : 'бумага «$name»');
  }

  for (final paint in paints) {
    final name = paint.name.trim();
    if (name.isEmpty) continue;
    if ((paint.qtyGrams ?? 0) > 0) continue;
    missing.add('краска «$name»');
  }

  return missing;
}

/// Единственный производитель фразы «краску в заказ не вписали».
///
/// Текст пишут два места — пересчёт обеспеченности в `OrdersProvider` и форма
/// заказа, — а читает третье: карточка заказа, которой по этой фразе нужно
/// понять, что заказ ждёт не поставки, а решения менеджера, и покраситься
/// серым, а не красным. Поэтому формулировка живёт здесь: разъедься она хоть
/// на слово, карточка перестала бы узнавать случай.
const String kPaintNotSelectedShortageMessage = 'Не выбрана краска.';

/// Заказ с формой, в который не вписали ни одной краски.
///
/// Форма — это печатная форма: заказ, который её несёт, будет печататься, а
/// печатать нечем, пока краска не выбрана. Такой заказ готов по всему
/// остальному, но запускать его нельзя — и это не «нехватка на складе»
/// (докупать нечего, названия краски ещё нет), а незаполненное решение.
/// Отсюда и отдельная фраза [kPaintNotSelectedShortageMessage], и серая
/// карточка вместо красной.
///
/// Заказ без формы правило не трогает: не всякое изделие печатается, и
/// требовать краску от всех подряд значило бы запереть половину заказов.
///
/// [paintLineCount] — сколько красок вписано в заказ, независимо от того,
/// указана ли граммовка. Краска без граммовки — это незаконченный заказ
/// (см. [materialsWithoutQuantity]), а не отсутствие выбора: случаи ведут в
/// разные статусы, и путать их нельзя.
bool paintSelectionMissing({
  required bool hasForm,
  required int paintLineCount,
}) =>
    hasForm && paintLineCount <= 0;

/// Читатель [kPaintNotSelectedShortageMessage]: это ЕДИНСТВЕННАЯ причина?
///
/// Сравнение строгое. Когда к невыбранной краске добавилась ещё и нехватка
/// бумаги, заказ ждёт поставки по-настоящему — и карточка обязана остаться
/// красной, иначе серый «просто допишите краску» спрячет реальную проблему.
bool isPaintNotSelectedShortage(String? message) =>
    (message ?? '').trim() == kPaintNotSelectedShortageMessage;

/// Дозапускные статусы. Запущенному заказу в них делать нечего.
const Set<OrderStatus> preLaunchStatuses = <OrderStatus>{
  OrderStatus.draft,
  OrderStatus.waiting_materials,
  OrderStatus.ready_to_start,
};

/// Статус заказа после проверки доступности материалов — дозапускной конвейер
/// draft → waiting_materials → ready_to_start.
///
/// Для уже запущенного заказа наличие материала статус не решает: его бумага
/// уже в резерве, проверка свободного остатка показывает нехватку на его же
/// резерве, а пересчёт зовётся на каждом сохранении. Так запущенный заказ
/// уходил в «Ожидание материалов», следующим сохранением — в «Готовы к
/// запуску», и там залипал: assignment_created остаётся true, значит
/// [canLaunchOrder] возвращает false и кнопка запуска не работает.
///
/// Поэтому запущенный заказ, живущий в производственном статусе, не трогаем —
/// null. Но если он уже провалился в дозапускной статус, поднять его обязаны
/// мы: больше этого не делает никто. Прежняя версия возвращала null всегда, и
/// заказ оставался в «Ожидании материалов» навсегда — даже после того, как
/// нехватка исчезала и текст ошибки стирался. Ровно в этом состоянии нашлись
/// семь запущенных заказов: has_material_shortage = false, сообщение пустое,
/// этапы идут, а карточка висит в «Ожидании материалов».
///
/// Снятый с производства заказ (resetLaunchedOrderForRelaunch) сюда не попадёт:
/// там вместе со статусом сбрасывается и assignment_created.
/// [materialDataComplete] — у всех выбранных материалов указано количество,
/// см. [materialsWithoutQuantity]. Незаполненное количество роняет заказ в
/// черновик, а не в «Ожидание материалов»: материала на складе может быть
/// сколько угодно, вопрос в том, что заказ не дописан.
/// [requiredBlocksComplete] — заполнены все блоки, отмеченные техлидом как
/// обязательные для этого типа продукта (`product_type_form_blocks
/// .is_required`, правило — `order_required_blocks.dart`). Роняет заказ в
/// черновик по той же причине, что и незаполненное количество: это не нехватка
/// на складе, а недописанный заказ.
///
/// Проверка нужна отдельно от [hasEnoughMaterial], потому что та разрешительная
/// по построению — отвечает «хватает ли ВЫБРАННОГО». Заказ, в который не
/// вписали ни одной бумаги, проходил её как «нехватки нет» и уезжал в
/// готовность пустым.
OrderStatus? materialAvailabilityStatus({
  required OrderModel order,
  required bool queueBuilt,
  required bool hasEnoughMaterial,
  required bool materialDataComplete,
  required bool requiredBlocksComplete,
}) {
  if (order.assignmentCreated) {
    return preLaunchStatuses.contains(order.statusEnum)
        ? OrderStatus.in_production
        : null;
  }
  if (!queueBuilt) return OrderStatus.draft;
  if (!requiredBlocksComplete) return OrderStatus.draft;
  if (!materialDataComplete) return OrderStatus.draft;
  if (!hasEnoughMaterial) return OrderStatus.waiting_materials;
  // Из ожидания материалов заказ поднимается в готовность; прочие статусы
  // (например черновик) наличие материала само по себе не меняет.
  return order.statusEnum == OrderStatus.waiting_materials
      ? OrderStatus.ready_to_start
      : order.statusEnum;
}