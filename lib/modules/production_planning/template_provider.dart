import 'dart:async';
import 'package:flutter/material.dart';
import 'package:uuid/uuid.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'template_model.dart';
import 'planned_stage_model.dart';

class TemplateProvider with ChangeNotifier {
  final _uuid = const Uuid();
  final SupabaseClient _supabase = Supabase.instance.client;

  final List<TemplateModel> _templates = [];
  StreamSubscription<List<Map<String, dynamic>>>? _sub;

  List<TemplateModel> get templates => List.unmodifiable(_templates);

  TemplateProvider() {
    _listenTemplates();
  }

  void _listenTemplates() {
    _sub?.cancel();
    _sub = _supabase
        .from('plan_templates')
        .stream(primaryKey: ['id'])
        .order('created_at', ascending: false)
        .listen((rows) {
      _templates
        ..clear()
        ..addAll(rows.map((row) =>
            TemplateModel.fromMap(Map<String, dynamic>.from(row))));
      notifyListeners();
    });
  }

  Future<void> createTemplate({
    required String name,
    required List<PlannedStage> stages,
  }) async {
    final id = _uuid.v4();
    await _supabase.from('plan_templates').insert({
      'id': id,
      'name': name,
      'stages': stages.map((s) => s.toMap()).toList(),
    });
  }

  Future<void> updateTemplate({
    required String id,
    required String name,
    required List<PlannedStage> stages,
  }) async {
    await _supabase
        .from('plan_templates')
        .update({
          'name': name,
          'stages': stages.map((s) => s.toMap()).toList(),
        })
        .eq('id', id);
  }

  Future<void> deleteTemplate(String id) async {
    await _supabase.from('plan_templates').delete().eq('id', id);
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }
}
