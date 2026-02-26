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

