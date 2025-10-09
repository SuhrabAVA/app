// Extension to provide a 'title' getter expected by UI code.
// Maps to description by default, or falls back to type.
import 'tmc_model.dart';

extension TmcModelTitle on TmcModel {
  String get title {
    final d = (description).trim();
    if (d.isNotEmpty) return d;
    return type;
  }
}
