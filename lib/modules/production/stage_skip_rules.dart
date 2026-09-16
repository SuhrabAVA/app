/// Правила кнопки «Пропустить этап» в деталях производства.
///
/// Зачем файл: кнопка задумывалась тестовой, а на 14.09 ею закрыто 229 задач
/// и 86 из 149 завершённых заказов. Исполнителем при этом записывался
/// `system` — кто и почему пропустил этап, узнать было нельзя, а пропуск
/// флексопечати молча оставлял краску заказа несписанной (23 заказа).
library;

import '../orders/production_ids.dart';

/// Причина короче этого считается неуказанной: «.», «-», «ок» ничего не
/// объясняют тому, кто будет разбирать заказ.
const int kMinSkipReasonLength = 3;

/// Причина пропуска пригодна для записи.
bool isValidSkipReason(String? reason) =>
    (reason ?? '').trim().length >= kMinSkipReasonLength;

/// Текст отметки в ленте этапа: причина и кто пропустил.
String skipStageNote({required String reason, String? actorName}) {
  final who = (actorName ?? '').trim();
  final base = 'Этап пропущен: ${reason.trim()}';
  return who.isEmpty ? base : '$base ($who)';
}

/// Имя для журнала склада, если пропуск закрывает этап списания бумаги.
/// Пустое имя возвращает `system`, как было раньше, — чтобы запись не
/// осталась совсем без автора.
String skipStageActor(String? actorName) {
  final who = (actorName ?? '').trim();
  return who.isEmpty ? 'system' : who;
}

/// Предупреждения о последствиях пропуска, которые нужно показать ДО
/// подтверждения.
List<String> skipStageWarnings(Iterable<String> stageIds) {
  final ids = stageIds.map((id) => id.trim()).toSet();
  return <String>[
    if (ids.contains(wpFlexPrintingUuid))
      'Краска заказа НЕ спишется автоматически: списание краски есть только '
          'в диалоге завершения флексопечати. Спишите её со склада вручную.',
    'Количество на этапе не будет записано, исполнителей у этапа не будет.',
  ];
}
