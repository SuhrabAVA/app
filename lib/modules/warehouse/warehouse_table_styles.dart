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

/// A reusable helper for building hoverable [DataRow]s in warehouse tables.
///
/// Keeps spacing, typography and action icons intact while enabling the same
/// hover feedback across all tables (web & desktop). Simply pass the list of
/// [cells] you already use in your `DataTable`.
DataRow warehouseHoverableDataRow({
  required List<DataCell> cells,
  Key? key,
  bool selected = false,
  ValueChanged<bool?>? onSelectChanged,
}) {
  return DataRow(
    key: key,
    color: warehouseRowHoverColor,
    selected: selected,
    onSelectChanged: onSelectChanged,
    cells: cells,
  );
}
