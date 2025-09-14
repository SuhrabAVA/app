// Paste this method inside your WarehouseProvider / TmcProvider class.
// Make sure to add:
//   import '../../services/documents_service.dart';
// and a field:
//   final _docs = DocumentsService();
//
// If your signature differs, keep your parameters and build `data` map the same way;
// the core change is to call `_docs.insert(collection: 'tmc', data: data)`
// instead of inserting directly into a physical `tmc` table.
Future<String> addTmc({
  required String supplier,
  required String type,
  required String description,
  required num quantity,
  required String unit,
  String? format,
  num? grammage,
  num? weight,
  String? note,
  String? imageBase64,   // not recommended to store base64 in DB; prefer Storage URL
  String? imageUrl,
  num? lowThreshold,
  num? criticalThreshold,
}) async {
  final data = <String, dynamic>{
    'date': DateTime.now().toIso8601String(),
    'supplier': supplier,
    'type': type,
    'description': description,
    'quantity': quantity,
    'unit': unit,
    if (format != null) 'format': format,
    if (grammage != null) 'grammage': grammage,
    if (weight != null) 'weight': weight,
    if (note != null && note.isNotEmpty) 'note': note,
    if (imageUrl != null) 'imageUrl': imageUrl,
    if (imageBase64 != null) 'imageBase64': imageBase64, // remove if you switch fully to Storage
    if (lowThreshold != null) 'low_threshold': lowThreshold,
    if (criticalThreshold != null) 'critical_threshold': criticalThreshold,
  };

  // Write into universal `documents` store, collection = 'tmc'.
  final inserted = await _docs.insert(collection: 'tmc', data: data);
  final id = inserted['id'] as String;

  // TODO: if you keep local lists/tables, update them here and notifyListeners().
  // _allTmc.add(_rowToTmc({...data, 'id': id}));
  // notifyListeners();

  return id;
}
