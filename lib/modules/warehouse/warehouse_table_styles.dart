import 'package:flutter/material.dart';

/// Common hover styling for data tables across the warehouse and related
/// modules. Highlights the entire row with a soft orange color when the pointer
/// hovers over it so users clearly see which row they are about to act on.
final MaterialStateProperty<Color?> warehouseRowHoverColor =
    MaterialStateProperty.resolveWith<Color?>((Set<MaterialState> states) {
  if (states.contains(MaterialState.hovered)) {
    return Colors.orange.shade100;
  }
  return null;
});

/// Helper to build [DataRow]s that automatically share the same hover styling
/// everywhere in the warehouse module. This keeps padding, typography and
/// action icons untouched while giving consistent pointer feedback for Web and
/// Desktop.
DataRow warehouseHoverableRow({
  required List<DataCell> cells,
  ValueChanged<bool?>? onSelectChanged,
  bool selected = false,
}) {
  return DataRow(
    color: warehouseRowHoverColor,
    onSelectChanged: onSelectChanged,
    selected: selected,
    cells: cells,
  );
}
