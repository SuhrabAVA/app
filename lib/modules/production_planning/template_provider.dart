import 'package:flutter/material.dart';
import 'package:uuid/uuid.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'template_model.dart';
import 'planned_stage_model.dart';

class TemplateProvider with ChangeNotifier {
  final _uuid = const Uuid();
  final SupabaseClient _supabase = Supabase.instance.client;

  final List<TemplateModel> _templates = [];

  TemplateProvider() {
    _listen();
  }

  List<TemplateModel> get templates => List.unmodifiable(_templates);

  void _listen() {
    _supabase.from('plan_templates').stream(primaryKey: ['id']).listen((rows) {
      _templates
        ..clear()
        ..addAll(rows.map((row) {
          final map = Map<String, dynamic>.from(row as Map);
          return TemplateModel.fromMap(map);
        }));
      notifyListeners();
    });
  }

  Future<void> createTemplate({
    required String name,
    required List<PlannedStage> stages,
  }) async {
    final id = _uuid.v4();
    final template = TemplateModel(id: id, name: name, stages: stages);
    _templates.add(template);
    notifyListeners();
    await _supabase.from('plan_templates').insert({
      'id': id,
      'name': name,
      'stages': stages.map((s) => s.toMap()).toList(),
    });
  }
}
