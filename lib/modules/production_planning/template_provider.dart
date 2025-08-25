import 'package:flutter/material.dart';
import 'package:uuid/uuid.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'template_model.dart';
import 'planned_stage_model.dart';

class TemplateProvider with ChangeNotifier {
  final _uuid = const Uuid();
  final SupabaseClient _supabase = Supabase.instance.client;

  final List<TemplateModel> _templates = [];
  List<TemplateModel> get templates => List.unmodifiable(_templates);

  TemplateProvider() {
    fetchTemplates();
  }

  Future<void> fetchTemplates() async {
    // Без дженериков: возвращается dynamic -> приводим к List<Map<String, dynamic>>
    final dynamic res = await _supabase
        .from('plan_templates')
        .select('*')
        .order('created_at', ascending: false);

    final rows = (res as List)
        .map((e) => Map<String, dynamic>.from(e as Map))
        .toList();

    _templates
      ..clear()
      ..addAll(rows.map((row) => TemplateModel.fromMap(row)));
    notifyListeners();
  }

  Future<void> createTemplate({
    required String name,
    required List<PlannedStage> stages,
  }) async {
    final id = _uuid.v4();

    _templates.insert(0, TemplateModel(id: id, name: name, stages: stages));
    notifyListeners();

    await _supabase.from('plan_templates').insert({
      'id': id,
      'name': name,
      'stages': stages.map((s) => s.toMap()).toList(),
    });

    await fetchTemplates();
  }

  Future<void> updateTemplate({
    required String id,
    required String name,
    required List<PlannedStage> stages,
  }) async {
    final i = _templates.indexWhere((t) => t.id == id);
    if (i != -1) {
      _templates[i] = TemplateModel(id: id, name: name, stages: stages);
      notifyListeners();
    }

    await _supabase
        .from('plan_templates')
        .update({
          'name': name,
          'stages': stages.map((s) => s.toMap()).toList(),
        })
        .eq('id', id);

    await fetchTemplates();
  }

  Future<void> deleteTemplate(String id) async {
    _templates.removeWhere((t) => t.id == id);
    notifyListeners();
    await _supabase.from('plan_templates').delete().eq('id', id);
  }
}
