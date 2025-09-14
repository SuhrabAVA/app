import 'package:flutter/material.dart';
import 'package:uuid/uuid.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../../services/doc_db.dart';
import 'dart:async';
import 'template_model.dart';
import 'planned_stage_model.dart';

class TemplateProvider with ChangeNotifier {
  final _uuid = const Uuid();
  final SupabaseClient _supabase = Supabase.instance.client;
  // Universal document store wrapper
  final DocDB _docDb = DocDB();

  final List<TemplateModel> _templates = [];
  // Realtime channel subscription for plan_templates collection
  RealtimeChannel? _tplChannel;
  List<TemplateModel> get templates => List.unmodifiable(_templates);

  TemplateProvider() {
    _listenTemplates();
  }

  void _listenTemplates() {
    // Cancel previous channel if exists
    if (_tplChannel != null) {
      _supabase.removeChannel(_tplChannel!);
      _tplChannel = null;
    }
    // Initial fetch from documents
    () async {
      final rows = await _docDb.list('plan_templates');
      _templates
        ..clear()
        ..addAll(rows.map((row) {
          final data = Map<String, dynamic>.from(row['data'] as Map);
          // id in data? some parts may rely on id field existing inside data; ensure it exists
          data['id'] = row['id'];
          return TemplateModel.fromMap(data);
        }));
      notifyListeners();
    }();
    // Subscribe to realtime updates
    _tplChannel = _docDb.listenCollection('plan_templates', (row, eventType) async {
      // reload list
      final rows = await _docDb.list('plan_templates');
      _templates
        ..clear()
        ..addAll(rows.map((r) {
          final data = Map<String, dynamic>.from(r['data'] as Map);
          data['id'] = r['id'];
          return TemplateModel.fromMap(data);
        }));
      notifyListeners();
    });
  }

  Future<void> createTemplate({
    required String name,
    required List<PlannedStage> stages,
  }) async {
    final id = _uuid.v4();

    // Insert into documents as plan_templates collection
    await _docDb.insert(
      'plan_templates',
      {
        'id': id,
        'name': name,
        'stages': stages.map((s) => s.toMap()).toList(),
      },
      explicitId: id,
    );
  }

  Future<void> updateTemplate({
    required String id,
    required String name,
    required List<PlannedStage> stages,
  }) async {
    // Update the document data for this template
    await _docDb.updateById(id, {
      'id': id,
      'name': name,
      'stages': stages.map((s) => s.toMap()).toList(),
    });
  }

  Future<void> deleteTemplate(String id) async {
    // Delete from documents
    await _docDb.deleteById(id);
  }
   @override
  void dispose() {
    // Remove realtime subscription
    if (_tplChannel != null) {
      _supabase.removeChannel(_tplChannel!);
    }
    super.dispose();
  }
}
