List<String> normalizeStageSequence(Iterable<String> rawSequence) {
  final sequence = <String>[];
  for (final value in rawSequence) {
    final id = value.trim();
    if (id.isEmpty) continue;
    sequence.add(id);
  }

  if (sequence.length >= 4 && sequence.length.isEven) {
    final half = sequence.length ~/ 2;
    var isMirroredDuplicate = true;
    for (var i = 0; i < half; i++) {
      if (sequence[i] != sequence[sequence.length - 1 - i]) {
        isMirroredDuplicate = false;
        break;
      }
    }
    if (isMirroredDuplicate) {
      sequence.removeRange(half, sequence.length);
    }
  }

  final unique = <String>[];
  for (final id in sequence) {
    if (!unique.contains(id)) {
      unique.add(id);
    }
  }
  return unique;
}

const String kCardboardCuttingStageId =
    'd7d91f75-2f85-446f-8c1d-a20606bdb3b1';

typedef StageGroupingResolver = String Function(String orderId, String stageId);

class PendingStageState {
  final String stageId;
  final bool completed;
  final bool problem;
  final bool started;

  const PendingStageState({
    required this.stageId,
    required this.completed,
    this.problem = false,
    this.started = false,
  });

  bool get pending => !completed;
}

bool canRunOutOfStageSequenceByStageId(String stageId) =>
    stageId.trim() == kCardboardCuttingStageId;

bool isFirstPendingStageInOrder({
  required String orderId,
  required String currentStageId,
  required Iterable<PendingStageState> stageStates,
  required Iterable<String> orderedStages,
  StageGroupingResolver? groupResolver,
  int Function(String a, String b)? fallbackStageComparator,
}) {
  if (canRunOutOfStageSequenceByStageId(currentStageId)) return true;

  String groupKey(String stageId) =>
      groupResolver?.call(orderId, stageId) ?? stageId;

  final stages = <String, Map<String, bool>>{};
  for (final state in stageStates) {
    final key = groupKey(state.stageId);
    final current = stages[key] ??
        {
          'pending': false,
          'completed': false,
          'problem': false,
          'started': false,
        };
    stages[key] = {
      'pending': current['pending'] == true || state.pending,
      'completed': current['completed'] == true || state.completed,
      'problem': current['problem'] == true || state.problem,
      'started': current['started'] == true || state.started,
    };
  }

  final orderedList = orderedStages.toList(growable: false);
  if (orderedList.isNotEmpty) {
    final orderedKeys = <String>[];
    for (final id in orderedList) {
      final key = groupKey(id);
      if (!orderedKeys.contains(key)) orderedKeys.add(key);
    }
    final indexMap = <String, int>{};
    for (var i = 0; i < orderedKeys.length; i++) {
      indexMap.putIfAbsent(orderedKeys[i], () => i);
    }

    final currentKey = groupKey(currentStageId);
    final currentIndex = indexMap[currentKey];
    if (currentIndex == null || currentIndex <= 0) return true;

    for (var i = currentIndex - 1; i >= 0; i--) {
      final prevKey = orderedKeys[i];
      final prevState = stages[prevKey];
      if (prevState == null) continue;

      final hasPending = prevState['pending'] == true;
      final hasProblem = prevState['problem'] == true;
      final hasStarted = prevState['started'] == true;
      if (!hasPending && prevState['completed'] == true) {
        continue;
      }
      return hasStarted || prevState['completed'] == true || hasProblem;
    }
    return true;
  }

  final pendingStageIds = stages.entries
      .where((e) => e.value['pending'] == true && e.value['completed'] != true)
      .map((e) => e.key)
      .toList();
  if (pendingStageIds.isEmpty) return true;

  if (fallbackStageComparator != null) {
    pendingStageIds.sort(fallbackStageComparator);
  } else {
    pendingStageIds.sort();
  }

  return groupKey(currentStageId) == pendingStageIds.first;
}
