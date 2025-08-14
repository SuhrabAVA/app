import 'package:flutter/material.dart';
import 'package:uuid/uuid.dart';
import 'package:firebase_database/firebase_database.dart';

import 'stage_model.dart';

class StageProvider with ChangeNotifier {
  final _uuid = const Uuid();
  final DatabaseReference _stagesRef =
      FirebaseDatabase.instance.ref('stages');

  final List<StageModel> _stages = [];

  StageProvider() {
    _listenToStages();
  }

  List<StageModel> get stages => List.unmodifiable(_stages);

  void _listenToStages() {
    _stagesRef.onValue.listen((event) {
      final data = event.snapshot.value;
      _stages.clear();
      if (data is Map) {
        data.forEach((key, value) {
          if (value is Map) {
            final map = Map<String, dynamic>.from(value as Map);
            map['id'] = key;
            _stages.add(StageModel.fromMap(map));
          }
        });
      }
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
    _stagesRef.child(stage.id).set(stage.toMap());
    return stage;
  }
}