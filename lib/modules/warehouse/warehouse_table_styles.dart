import 'package:flutter/material.dart';

/// Common hover styling for warehouse tables.
/// Highlights the entire row with a soft orange color when the pointer hovers
/// over it so users clearly see which row they are about to act on.
final MaterialStateProperty<Color?> warehouseRowHoverColor =
    MaterialStateProperty.resolveWith<Color?>((Set<MaterialState> states) {
  if (states.contains(MaterialState.hovered)) {
    return Colors.orange.shade100;
  }
  return null;
});
