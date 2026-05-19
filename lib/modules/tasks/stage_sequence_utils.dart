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

const String kPackagingStageId = 'edeb85db-c7a3-4a24-8f33-70ccdd4aaae1';

const Set<String> _packagingAliases = <String>{
  'упаковка',
  'packaging',
  'package',
};

const Set<String> _packagingGroupKeys = <String>{
  'pack',
  'packing',
  'packaging',
  'package',
  'packaging_stage',
  'package_stage',
  'packaging_group',
  'package_group',
  'pack_stage',
  'упаковка',
};

String _normalizePackagingLookupValue(String? value) => (value ?? '')
    .trim()
    .toLowerCase()
    .replaceAll('-', '_')
    .replaceAll(RegExp(r'\s+'), '_');

bool _matchesPackagingText(String? value) {
  final normalized = _normalizePackagingLookupValue(value);
  if (normalized.isEmpty) return false;
  if (_packagingAliases.contains(normalized)) return true;
  return normalized.contains('упаков') ||
      normalized.contains('packaging') ||
      normalized == 'package';
}

bool isPackagingStage({
  String? stageId,
  String? stageName,
  String? stageType,
  String? stageGroupKey,
}) {
  if ((stageId ?? '').trim() == kPackagingStageId) return true;
  if (_matchesPackagingText(stageName) || _matchesPackagingText(stageType)) {
    return true;
  }

  final normalizedGroupKey = _normalizePackagingLookupValue(stageGroupKey);
  if (_packagingGroupKeys.contains(normalizedGroupKey)) return true;
  return normalizedGroupKey.contains('упаков');
}

typedef StageGroupingResolver = String Function(String orderId, String stageId);

class PendingStageState {
  final String stageId;
  final String? stageName;
  final String? stageType;
  final String? stageGroupKey;
  final bool completed;
  final bool problem;
  final bool started;

  const PendingStageState({
    required this.stageId,
    this.stageName,
    this.stageType,
    this.stageGroupKey,
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
  String? currentStageName,
  String? currentStageType,
  String? currentStageGroupKey,
}) {
  if (canRunOutOfStageSequenceByStageId(currentStageId)) return true;

  String groupKey(String stageId) =>
      groupResolver?.call(orderId, stageId) ?? stageId;

  final stages = <String, Map<String, bool>>{};
  var currentIsPackaging = isPackagingStage(
    stageId: currentStageId,
    stageName: currentStageName,
    stageType: currentStageType,
    stageGroupKey: currentStageGroupKey,
  );
  for (final state in stageStates) {
    final key = groupKey(state.stageId);
    if (state.stageId == currentStageId ||
        (currentStageGroupKey != null &&
            state.stageGroupKey == currentStageGroupKey)) {
      currentIsPackaging = currentIsPackaging ||
          isPackagingStage(
            stageId: state.stageId,
            stageName: state.stageName,
            stageType: state.stageType,
            stageGroupKey: state.stageGroupKey,
          );
    }
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

    if (currentIsPackaging && currentIndex == orderedKeys.length - 1) {
      final previousState = stages[orderedKeys[currentIndex - 1]];
      return _stageUnlocksNext(previousState);
    }

    for (var i = currentIndex - 1; i >= 0; i--) {
      final prevKey = orderedKeys[i];
      final prevState = stages[prevKey];
      if (prevState == null) continue;

      final hasPending = prevState['pending'] == true;
      if (!hasPending && prevState['completed'] == true) {
        continue;
      }
      return _stageUnlocksNext(prevState);
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


bool canStartPackagingOutOfQueue({
  required String orderId,
  required String currentStageId,
  required Iterable<PendingStageState> stageStates,
  required Iterable<String> orderedStages,
  required bool hasPackagingAccess,
  StageGroupingResolver? groupResolver,
  String? currentStageName,
  String? currentStageType,
  String? currentStageGroupKey,
  bool enforceSinglePerformer = true,
}) {
  final currentIsPackaging = isPackagingStage(
    stageId: currentStageId,
    stageName: currentStageName,
    stageType: currentStageType,
    stageGroupKey: currentStageGroupKey,
  );
  if (!currentIsPackaging) return false;
  if (!hasPackagingAccess) return false;

  String groupKey(String stageId) =>
      groupResolver?.call(orderId, stageId) ?? stageId;

  final orderedList = orderedStages.toList(growable: false);
  if (orderedList.isEmpty) return false;

  final orderedKeys = <String>[];
  for (final id in orderedList) {
    final key = groupKey(id);
    if (!orderedKeys.contains(key)) orderedKeys.add(key);
  }

  final currentKey = groupKey(currentStageId);
  final currentIndex = orderedKeys.indexOf(currentKey);
  if (currentIndex != orderedKeys.length - 1 || currentIndex <= 0) return false;

  final previousKey = orderedKeys[currentIndex - 1];

  bool packagingCompleted = false;
  bool packagingAlreadyStarted = false;
  bool previousStarted = false;

  for (final state in stageStates) {
    final key = groupKey(state.stageId);
    if (key == currentKey) {
      if (state.completed) packagingCompleted = true;
      if (state.started) packagingAlreadyStarted = true;
    }
    if (key == previousKey && (state.started || state.completed || state.problem)) {
      previousStarted = true;
    }
  }

  if (packagingCompleted) return false;
  if (!previousStarted) return false;
  if (enforceSinglePerformer && packagingAlreadyStarted) return false;

  return true;
}

@Deprecated('Use canStartPackagingOutOfQueue')
bool canStartPackagingEarly({
  required String orderId,
  required String currentStageId,
  required Iterable<PendingStageState> stageStates,
  required Iterable<String> orderedStages,
  required bool hasPackagingAccess,
  StageGroupingResolver? groupResolver,
  String? currentStageName,
  String? currentStageType,
  String? currentStageGroupKey,
  bool enforceSinglePerformer = true,
}) =>
    canStartPackagingOutOfQueue(
      orderId: orderId,
      currentStageId: currentStageId,
      stageStates: stageStates,
      orderedStages: orderedStages,
      hasPackagingAccess: hasPackagingAccess,
      groupResolver: groupResolver,
      currentStageName: currentStageName,
      currentStageType: currentStageType,
      currentStageGroupKey: currentStageGroupKey,
      enforceSinglePerformer: enforceSinglePerformer,
    );

bool _stageUnlocksNext(Map<String, bool>? stage) {
  if (stage == null) return false;
  return stage['started'] == true ||
      stage['completed'] == true ||
      stage['problem'] == true;
}
