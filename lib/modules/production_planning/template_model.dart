import 'planned_stage_model.dart';

class TemplateModel {
  final String id;
  final String name;
  final List<PlannedStage> stages;

  TemplateModel({
    required this.id,
    required this.name,
    required this.stages,
  });

  Map<String, dynamic> toMap() => {
        'id': id,
        'name': name,
        'stages': stages.map((s) => s.toMap()).toList(),
      };

  factory TemplateModel.fromMap(Map<String, dynamic> map) => TemplateModel(
        id: map['id'] as String,
        name: map['name'] as String? ?? '',
        stages: decodePlannedStages(map['stages']),
      );
}