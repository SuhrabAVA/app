/// Правила пересчёта резерва бумаги при правке уже запущенного заказа.
///
/// Резерв — не расход, а бронь: заказ держит ровно столько метров, сколько ему
/// нужно. Отсюда три правила, и все три про разницу с тем, что уже забронировано:
///
/// * потребность не изменилась — ничего не проверяем и не пишем;
/// * потребность выросла — берём только прирост, и только его и проверяем на
///   наличие;
/// * потребность упала — лишнее возвращаем, в брони остаётся новая потребность.
///
/// Раньше на каждом сохранении бронь переписывалась целиком и заново
/// проверялась «хватает ли остатка на всю потребность». Заказ с бронью 1700 м
/// не проходил такую проверку по собственной же брони и вылетал из
/// производства в «Ожидание материалов».
library;

import 'order_model.dart';

/// Погрешность сравнения метража. Длины хранятся как double и приходят из
/// разных полей формы, поэтому точное равенство ненадёжно.
const double kReservationEpsilon = 0.001;

/// Держит ли заказ в этом состоянии бронь бумаги.
///
/// Бронь начинается не с запуска, а с момента, когда заказ признан
/// обеспеченным. «Готов к запуску» — это обещание менеджеру, что материал за
/// ним закреплён, и обещание должно быть подкреплено метрами на складе.
///
/// Прежнее правило («бронь принадлежит запуску») давало ровно обратное: заказ
/// показывал кнопку «Запустить», не держа ни метра, и сосед мог забрать бумагу
/// у него из-под ног — заказ возвращался в «Ожидание материалов» уже после
/// того, как менеджер увидел готовность. Так, например, заказ 323 поднялся в
/// готовность после прихода МЦБК с запасом 21.74 м и не занял ни метра.
///
/// Черновик и «Ожидание материалов» бумагу не держат: заказ, у которого
/// рассыпалась очередь или не хватило метража, не должен морозить рулон.
/// У завершённого заказа брони тоже нет — при завершении она списывается
/// (`finalize_order_paper_reservations`).
bool holdsPaperReservation({
  required bool assignmentCreated,
  required OrderStatus status,
}) {
  if (status == OrderStatus.completed) return false;
  // Запущенный заказ держит бумагу в любом статусе: он уже в цеху, и
  // залипший дозапускной статус не повод возвращать его метры на склад.
  if (assignmentCreated) return true;
  return status == OrderStatus.ready_to_start ||
      status == OrderStatus.in_production;
}

/// Планируемая бронь совпадает с текущей — трогать нечего.
bool sameReservationPlan(
  Map<String, double> current,
  Map<String, double> planned,
) {
  final keys = <String>{...current.keys, ...planned.keys};
  for (final key in keys) {
    final before = current[key] ?? 0;
    final after = planned[key] ?? 0;
    if ((before - after).abs() > kReservationEpsilon) return false;
  }
  return true;
}

/// Сколько метров бумаги нужно докупить сверх уже забронированного.
///
/// Ноль означает, что новый остаток искать не нужно: потребность не выросла,
/// а значит бронь либо остаётся прежней, либо часть её возвращается на склад.
double additionalReserveNeeded({
  required double alreadyReserved,
  required double plannedQty,
}) {
  final delta = plannedQty - alreadyReserved;
  return delta > kReservationEpsilon ? delta : 0;
}

/// Хватает ли бумаги, чтобы применить новую бронь.
///
/// [availableExcludingThisOrder] — складской остаток за вычетом броней ЧУЖИХ
/// заказов. Собственная бронь в него входит: заменить свои метры на свои же
/// новый остаток не требует.
bool canApplyReservation({
  required double alreadyReserved,
  required double plannedQty,
  required double availableExcludingThisOrder,
}) {
  final needed = additionalReserveNeeded(
    alreadyReserved: alreadyReserved,
    plannedQty: plannedQty,
  );
  if (needed <= 0) return true;
  return availableExcludingThisOrder + kReservationEpsilon >= plannedQty;
}
