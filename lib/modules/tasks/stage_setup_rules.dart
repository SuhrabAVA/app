/// Когда наладка станка считается закрытой.
///
/// Что чинит
/// ---------
/// 08.09 Равиль Вуколов начал наладку на этапе «Фри» и в 19:59 ушёл на
/// пересмену. 09.09 в 08:07 этап поднял Бакытжан Жылкыбай, закрыл наладку
/// своим `setup_done` и запустил производство — станок отработал 8,5 часов.
///
/// Но `setup_done` записывается на того, кто нажал кнопку, а незакрытость
/// считалась ПО КАЖДОМУ СОТРУДНИКУ ОТДЕЛЬНО. Поэтому `setup_start` Вуколова
/// от 08.09 остался висеть навсегда: его собственного `setup_done` не было и
/// быть не могло — наладку закрыл другой человек.
///
/// Когда Вуколов вернулся, строка кнопок попадала в фазу `setupProblem`, и
/// этап запирался наглухо:
///   * «Продолжить наладку» гасло условием `!productionStarted` — тираж-то уже
///     шёл;
///   * «Вернуть в работу» гасло, потому что фазы `setupProblem` нет в списке
///     разрешённых для старта.
/// Оставалась одна «Пересмена». Вуколов нажал её четыре раза подряд и каждый
/// раз возвращался в то же состояние.
///
/// Правило
/// -------
/// Наладка — состояние СТАНКА, а не человека. Она закрыта, если после её
/// начала произошло любое из двух:
///   * тот же сотрудник нажал «Завершить наладку» (`setup_done`);
///   * на этапе пошло производство — станок в тираже, налаживать нечего,
///     кто бы наладку ни закрывал.
///
/// Второе условие намеренно общее для всего этапа, а первое — личное: в
/// раздельном режиме двое могут налаживать свои станки одновременно, и чужой
/// `setup_done` не должен закрывать чужую наладку. А вот запуск тиража
/// закрывает её у всех.
library;

/// Состояние наладки этапа: у кого она осталась незакрытой.
class StageSetupState {
  StageSetupState({
    required Map<String, int> lastStartByUser,
    required Map<String, int> lastDoneByUser,
    required List<int> productionStarts,
  })  : _lastStartByUser = lastStartByUser,
        _lastDoneByUser = lastDoneByUser,
        _lastProductionStart = productionStarts.fold<int>(
          0,
          (best, value) => value > best ? value : best,
        );

  final Map<String, int> _lastStartByUser;
  final Map<String, int> _lastDoneByUser;

  /// Самый поздний запуск производства на этапе; 0 — тираж ещё не шёл.
  final int _lastProductionStart;

  /// Пустое состояние: наладку никто не начинал.
  static final StageSetupState empty = StageSetupState(
    lastStartByUser: const <String, int>{},
    lastDoneByUser: const <String, int>{},
    productionStarts: const <int>[],
  );

  /// У [userId] осталась незакрытая наладка.
  bool unfinishedFor(String userId) {
    final start = _lastStartByUser[userId] ?? 0;
    if (start <= 0) return false;
    if ((_lastDoneByUser[userId] ?? 0) > start) return false;
    return _lastProductionStart <= start;
  }

  /// Хоть у кого-то на этапе наладка осталась незакрытой.
  bool get pendingForStage =>
      _lastStartByUser.keys.any(unfinishedFor);

  /// Кто именно не закрыл наладку. Для диагностики и сообщений цеху.
  List<String> get usersWithUnfinishedSetup =>
      _lastStartByUser.keys.where(unfinishedFor).toList(growable: false);
}
