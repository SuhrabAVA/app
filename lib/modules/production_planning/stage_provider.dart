import 'package:flutter/material.dart';
import 'package:uuid/uuid.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'stage_model.dart';

class StageProvider with ChangeNotifier {
  final _uuid = const Uuid();
  final SupabaseClient _supabase = Supabase.instance.client;

  final List<StageModel> _stages = [];

  StageProvider() {
    _listenToStages();
  }

  List<StageModel> get stages => List.unmodifiable(_stages);

  void _listenToStages() {
    _supabase.from('stages').stream(primaryKey: ['id']).listen((rows) {
      _stages
        ..clear()
        ..addAll(rows.map((row) {
          final map = Map<String, dynamic>.from(row as Map);
          return StageModel.fromMap(map);
        }));
      notifyListeners();
    });
  }

  StageModel createStage({
    required String name,
    required String description,
    required String workplaceId,
  }) {
    final stage = StageModel(
      id: _uuid.v4(),
      name: name,
      description: description,
      workplaceId: workplaceId,
    );
    _stages.add(stage);
    notifyListeners();
    final data = stage.toMap();
    _supabase.from('stages').insert(data);
    return stage;
  }
}