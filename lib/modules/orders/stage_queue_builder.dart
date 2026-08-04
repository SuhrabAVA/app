import '../tasks/stage_sequence_utils.dart' as stage_sequence;
import 'material_model.dart';
import 'order_handle_type.dart';
import 'production_ids.dart';

export 'order_handle_type.dart' show OrderHandleType;

// Идентификаторы приходят из единого реестра production_ids.dart —
// собственных uuid-литералов в этом файле быть не должно.

// Product type IDs.
const String kSheetProductTypeId = ptSheetUuid;
const Set<String> kSheetProducts = {
  kSheetProductTypeId,
};

const String kVTypeProductId = ptVWindowUuid;
const String kVTypeProductAltId = ptVPackageUuid;
const String kVTypeProductAlt2Id = ptVFriUuid;
const String kVTypeProductAlt3Id = ptVCornerUuid;
const Set<String> kVTypeProducts = {
  kVTypeProductId,
  kVTypeProductAltId,
  kVTypeProductAlt2Id,
  kVTypeProductAlt3Id,
};

const String kTwoSheetPackageProductTypeId = ptTwoSheetPackageUuid;
const Set<String> kTwoSheetPackageProducts = {kTwoSheetPackageProductTypeId};

const String kPTypePackageProduct = ptPPackageUuid;
const Set<String> kPTypePackageProducts = {kPTypePackageProduct};

// Workplace/stage IDs.
const String kBobbinStageId = wpBobbinUuid;
const String kFlexPrintingStageId = wpFlexPrintingUuid;
const Set<String> kLegacyBobbinStageAliases = {'w_bobiner', 'w_bobbin'};
const Set<String> kLegacyFlexPrintingStageAliases = {'w_flexoprint', 'w_flexo'};
const String kPackagingStageId = stage_sequence.kPackagingStageId;
const String kFriStageId = wpFriUuid;
const String kWindowStageId = wpWindowUuid;
const String kAutoBigStageId = wpAutoBigUuid;
const String kAutoSmallStageId = wpAutoSmallUuid;
const String kTubeStageId = wpTubeUuid;
const String kSheetCutStageId = wpSheetCutUuid;
const String kCuttingStageId = wpCuttingUuid;
const String kCardboardCuttingStageId = wpCardboardCuttingUuid;
const String kCardboardInsertStageId = wpCardboardInsertUuid;
const String kBottomWithCardboardAssemblyStageId =
    wpBottomWithCardboardAssemblyUuid;
const String kManualHandleStageId = wpManualHandleUuid;
const String kDieCutHandleStageId = wpDieCutHandleUuid;

const String kDieCutA1WorkplaceId = wpDieCutA1Uuid;
const String kDieCutA2WorkplaceId = wpDieCutA2Uuid;
const String kBottomGlueWorkplaceId = wpBottomGlueManualUuid;
const String kBottomGlueAltWorkplaceId = wpBottomGlueHotUuid;
const String kBottomGlueSecondAltWorkplaceId = wpBottomGlueColdUuid;
const String kTwistedHandleWorkplaceId = wpTwistedHandleUuid;

const String kSharedHandleWorkplaceId = kManualHandleStageId;
const String kFlatHandleWorkplaceId = wpFlatHandleUuid;

// The following technological stage keys are intentionally distinct even when
// a customer installation maps several of them to the same physical workplace.
const String kDieCutA1A2StageId = 'die_cut_a1_a2';
const String kScotchStageId = wpScotchUuid;
const String kFromTwoSheetsStageId = wpFromTwoSheetsUuid;
const String kTubeAssemblyStageId = wpTubeAssemblyUuid;
const String kBottomGlueStageId = 'bottom_glue_group';
const String kTwistedHandleGroupStageId = 'twisted_handle_group';
const String kFlatHandleGroupStageId = 'flat_handle_group';

const String kVMainSwitchStageKey = 'v_main_switch';
const String kPMainSwitchStageKey = 'p_main_switch';
const String kSwitchableVGroupKey = 'v_bottom_stage';
const String kSwitchablePGroupKey = 'p_package_stage';

double? _parseLeadingNumber(String? source) {
  if (source == null) return null;
  final match = RegExp(r'[0-9]+(?:[.,][0-9]+)?')
      .firstMatch(source.replaceAll(',', '.'));
  if (match == null) return null;
  return double.tryParse(match.group(0)!);
}

double? parseMaterialWidth(MaterialModel? material) {
  return _parseLeadingNumber(material?.format);
}

class OrderStageQueueDraft {
  const OrderStageQueueDraft({
    required this.productTypeId,
    this.orderWidthB,
    this.materialWidth,
    required this.hasPaint,
    required this.hasTrimming,
    required this.hasCardboard,
    this.requiresBobbinCutting,
    this.handleType,
    this.switchableStageKey,
    this.selectedSwitchableStageId,
    this.selectedSwitchableStageIdsByStageKey = const <String, String>{},
  });

  final String productTypeId;
  final double? orderWidthB;
  final double? materialWidth;
  final bool hasPaint;
  final bool hasTrimming;
  final bool hasCardboard;
  final bool? requiresBobbinCutting;
  final Object? handleType;
  final String? switchableStageKey;
  final String? selectedSwitchableStageId;
  final Map<String, String> selectedSwitchableStageIdsByStageKey;

  OrderStageQueueDraft copyWithSwitchableSelections(
    Map<String, String> selections,
  ) {
    return OrderStageQueueDraft(
      productTypeId: productTypeId,
      orderWidthB: orderWidthB,
      materialWidth: materialWidth,
      hasPaint: hasPaint,
      hasTrimming: hasTrimming,
      hasCardboard: hasCardboard,
      requiresBobbinCutting: requiresBobbinCutting,
      handleType: handleType,
      switchableStageKey: switchableStageKey,
      selectedSwitchableStageId: selectedSwitchableStageId,
      selectedSwitchableStageIdsByStageKey: selections,
    );
  }
}

class BuiltOrderStage {
  const BuiltOrderStage({
    required this.stageKey,
    required this.stageName,
    required this.workplaceIds,
    this.sortOrder = 0,
    this.isSwitchable = false,
    this.switchableGroupKey,
    this.selectedWorkplaceId,
  });

  final String stageKey;
  final String stageName;
  final List<String> workplaceIds;
  final int sortOrder;
  final bool isSwitchable;
  final String? switchableGroupKey;
  final String? selectedWorkplaceId;

  BuiltOrderStage copyWith({int? sortOrder, String? selectedWorkplaceId}) {
    return BuiltOrderStage(
      stageKey: stageKey,
      stageName: stageName,
      workplaceIds: workplaceIds,
      sortOrder: sortOrder ?? this.sortOrder,
      isSwitchable: isSwitchable,
      switchableGroupKey: switchableGroupKey,
      selectedWorkplaceId: selectedWorkplaceId ?? this.selectedWorkplaceId,
    );
  }

  Map<String, dynamic> toMap() {
    final selectedId = (selectedWorkplaceId != null &&
            workplaceIds.contains(selectedWorkplaceId))
        ? selectedWorkplaceId!
        : (workplaceIds.isNotEmpty ? workplaceIds.first : stageKey);
    final alternativeIds = workplaceIds
        .where((id) => id.trim().isNotEmpty && id != selectedId)
        .toList();
    return {
      'stageKey': stageKey,
      'stageId': selectedId,
      'id': selectedId,
      'workplaceId': selectedId,
      'workplaceIds': List<String>.from(workplaceIds),
      if (alternativeIds.isNotEmpty) 'alternativeStageIds': alternativeIds,
      'stageName': stageName,
      'workplaceName': stageName,
      'sortOrder': sortOrder,
      'order': sortOrder,
      'isSwitchable': isSwitchable,
      if (switchableGroupKey != null) 'switchableGroupKey': switchableGroupKey,
      if (selectedWorkplaceId != null) 'selectedWorkplaceId': selectedWorkplaceId,
    };
  }
}

List<BuiltOrderStage> buildOrderStages(OrderStageQueueDraft draft) {
  final builder = _OrderStageQueueBuilder(draft);
  return builder.build();
}

List<Map<String, dynamic>> buildOrderStageQueue({
  required String productTypeId,
  required bool hasCutting,
  required bool hasCardboard,
  required bool hasFlexPrinting,
  Object? handleType,
  bool? requiresBobbinCutting,
  double? orderWidthB,
  double? materialWidth,
  String? switchableStageKey,
  String? selectedSwitchableStageId,
  Map<String, String> selectedSwitchableStageIdsByStageKey =
      const <String, String>{},
  List<Map<String, dynamic>> existingStages = const [],
  List<Map<String, dynamic>> templateStages = const [],
}) {
  final selectedByStageKey = <String, String>{
    ..._selectedSwitchableStageIdsByStageKey(templateStages),
    ..._selectedSwitchableStageIdsByStageKey(existingStages),
    ...selectedSwitchableStageIdsByStageKey,
  };
  final selectedFromSource = selectedSwitchableStageId ??
      _selectedSwitchableStageId(existingStages) ??
      _selectedSwitchableStageId(templateStages);
  final draft = OrderStageQueueDraft(
    productTypeId: productTypeId,
    orderWidthB: orderWidthB,
    materialWidth: materialWidth,
    hasPaint: hasFlexPrinting,
    hasTrimming: hasCutting,
    hasCardboard: hasCardboard,
    requiresBobbinCutting: requiresBobbinCutting,
    handleType: handleType,
    switchableStageKey: switchableStageKey,
    selectedSwitchableStageId: selectedFromSource,
    selectedSwitchableStageIdsByStageKey: selectedByStageKey,
  );
  final built = normalizeBuiltOrderStageQueue(
    buildOrderStages(draft).map((stage) => stage.toMap()).toList(),
  );
  return _preserveSwitchableBobbinFlexOrder(built, existingStages);
}

List<Map<String, dynamic>> _preserveSwitchableBobbinFlexOrder(
  List<Map<String, dynamic>> built,
  List<Map<String, dynamic>> existingStages,
) {
  if (built.length < 2 || existingStages.length < 2) return built;

  final existingBobbinIndex = existingStages.indexWhere(
    (stage) => _isBobbinStage(stage, _stageIdFromMap(stage)),
  );
  final existingFlexIndex = existingStages.indexWhere(
    (stage) => _isFlexPrintingStage(stage, _stageIdFromMap(stage)),
  );
  if (existingBobbinIndex < 0 || existingFlexIndex < 0) return built;

  final builtBobbinIndex = built.indexWhere(
    (stage) => _isBobbinStage(stage, _stageIdFromMap(stage)),
  );
  final builtFlexIndex = built.indexWhere(
    (stage) => _isFlexPrintingStage(stage, _stageIdFromMap(stage)),
  );
  if (builtBobbinIndex < 0 || builtFlexIndex < 0) return built;

  final existingFlexBeforeBobbin = existingFlexIndex < existingBobbinIndex;
  final builtFlexBeforeBobbin = builtFlexIndex < builtBobbinIndex;
  if (existingFlexBeforeBobbin == builtFlexBeforeBobbin) return built;

  final reordered = built
      .map((stage) => Map<String, dynamic>.from(stage))
      .toList(growable: true);
  final flexStage = reordered.removeAt(builtFlexIndex);
  final bobbinIndexAfterRemove = reordered.indexWhere(
    (stage) => _isBobbinStage(stage, _stageIdFromMap(stage)),
  );
  if (bobbinIndexAfterRemove < 0) return built;
  reordered.insert(
    existingFlexBeforeBobbin
        ? bobbinIndexAfterRemove
        : bobbinIndexAfterRemove + 1,
    flexStage,
  );

  for (var i = 0; i < reordered.length; i++) {
    reordered[i]['sortOrder'] = i + 1;
    reordered[i]['order'] = i + 1;
  }
  return reordered;
}


bool requiresBobbinCuttingForOrder({
  required Iterable<MaterialModel> papers,
  required double? defaultOrderWidthB,
  String? mainMaterialFormatFallback,
}) {
  const double epsilon = 0.001;
  var index = 0;
  for (final paper in papers) {
    final formatWidth = parseMaterialWidth(paper) ??
        (index == 0 ? _parseLeadingNumber(mainMaterialFormatFallback) : null);
    final productWidth = index == 0
        ? defaultOrderWidthB
        : (_materialExtraDouble(paper, 'widthB') ?? defaultOrderWidthB);
    if (formatWidth != null &&
        productWidth != null &&
        productWidth > 0 &&
        (productWidth + epsilon) < formatWidth) {
      return true;
    }
    index += 1;
  }
  return false;
}

double? _materialExtraDouble(MaterialModel paper, String key) {
  final value = paper.extra?[key];
  if (value is num) return value.toDouble();
  if (value is String) {
    final normalized = value.trim().replaceAll(',', '.');
    if (normalized.isEmpty) return null;
    return double.tryParse(normalized);
  }
  return null;
}

List<Map<String, dynamic>> normalizeBuiltOrderStageQueue(
  List<Map<String, dynamic>> stages,
) {
  final normalized = <Map<String, dynamic>>[];
  final seen = <String>{};
  final seenStageIdLabels = <String>{};

  for (final source in stages) {
    final map = Map<String, dynamic>.from(source);
    final stageId = _stageIdFromMap(map);
    final canonicalId = _canonicalStageId(stageId);
    final dedupeKey = _dedupeStageKey(map, canonicalId);
    if (!seen.add(dedupeKey)) continue;
    if (canonicalId != null && canonicalId.isNotEmpty) {
      map['stageId'] = canonicalId;
      map['workplaceId'] = canonicalId;
      map['id'] = canonicalId;
    }
    if (_isBobbinStage(map, canonicalId)) {
      map['stageName'] = 'Бабинорезка';
      map['workplaceName'] = 'Бабинорезка';
    } else if (_isFlexPrintingStage(map, canonicalId)) {
      map['stageName'] = 'Флексопечать';
      map['workplaceName'] = 'Флексопечать';
    } else if (isPackagingStage(map, canonicalId)) {
      map['stageName'] = 'Упаковка';
      map['workplaceName'] = 'Упаковка';
    }
    if (!_allowsDuplicateStage(map)) {
      final labelKey = _semanticStageLabelKey(map);
      if (canonicalId != null && canonicalId.isNotEmpty && labelKey.isNotEmpty) {
        final stageIdLabelKey = '${canonicalId.toLowerCase()}::$labelKey';
        if (!seenStageIdLabels.add(stageIdLabelKey)) continue;
      }
    }
    normalized.add(map);
  }

  final ordered = _hasPersistedStageOrder(normalized)
      ? normalized
      : _withPackagingStagesLast(normalized);

  for (var i = 0; i < ordered.length; i++) {
    ordered[i]['sortOrder'] = i + 1;
    ordered[i]['order'] = i + 1;
  }
  return ordered;
}

bool _hasPersistedStageOrder(List<Map<String, dynamic>> stages) {
  return stages.any((stage) {
    for (final key in const <String>[
      'sortOrder',
      'order',
      'step',
      'step_no',
      'seq',
    ]) {
      if (stage.containsKey(key) && stage[key] != null) return true;
    }
    return false;
  });
}

List<Map<String, dynamic>> _withPackagingStagesLast(
  List<Map<String, dynamic>> stages,
) {
  final products = <Map<String, dynamic>>[];
  final packaging = <Map<String, dynamic>>[];

  for (final stage in stages) {
    final id = _stageIdFromMap(stage);
    if (isPackagingStage(stage, id)) {
      packaging.add(stage);
    } else {
      products.add(stage);
    }
  }

  return <Map<String, dynamic>>[
    ...products,
    ...packaging,
  ];
}

String? _stageIdFromMap(Map<String, dynamic> map) => (map['stageId'] ??
        map['stage_id'] ??
        map['stageid'] ??
        map['workplaceId'] ??
        map['workplace_id'] ??
        map['id'])
    ?.toString();

String? _canonicalStageId(String? stageId) {
  if (stageId == null) return null;
  final normalized = stageId.toLowerCase();
  if (kLegacyFlexPrintingStageAliases.contains(normalized)) {
    return kFlexPrintingStageId;
  }
  if (kLegacyBobbinStageAliases.contains(normalized)) return kBobbinStageId;
  return stageId;
}

String _dedupeStageKey(Map<String, dynamic> map, String? stageId) {
  if (_isBobbinStage(map, stageId)) return 'position:bob_cutter';
  if (_isFlexPrintingStage(map, stageId)) return 'position:print';
  final stageKey = (map['stageKey'] ??
          map['stage_key'] ??
          map['stage_group_key'] ??
          map['stageGroupKey'])
      ?.toString()
      .trim();
  if (stageKey != null && stageKey.isNotEmpty) return 'stageKey:$stageKey';
  return 'stage:${stageId ?? ''}';
}

bool _allowsDuplicateStage(Map<String, dynamic> map) {
  for (final key in const <String>[
    'allowDuplicate',
    'allow_duplicate',
    'repeatAllowed',
    'repeat_allowed',
  ]) {
    final value = map[key];
    if (value == true) return true;
    if (value?.toString().toLowerCase().trim() == 'true') return true;
  }
  return false;
}

String _semanticStageLabelKey(Map<String, dynamic> map) {
  final label = _stageNameFromMap(map);
  return label.replaceAll(RegExp(r'\s+'), ' ').trim().toLowerCase();
}

bool _isBobbinStage(Map<String, dynamic> map, String? stageId) {
  final normalizedId = (stageId ?? '').toLowerCase();
  if (stageId == kBobbinStageId ||
      kLegacyBobbinStageAliases.contains(normalizedId)) {
    return true;
  }
  final name = _stageNameFromMap(map);
  return name.contains('бобин') || name.contains('бабин') || name.contains('bobbin');
}

bool _isFlexPrintingStage(Map<String, dynamic> map, String? stageId) {
  final normalizedId = (stageId ?? '').toLowerCase();
  if (stageId == kFlexPrintingStageId ||
      kLegacyFlexPrintingStageAliases.contains(normalizedId)) {
    return true;
  }
  final name = _stageNameFromMap(map);
  return name.contains('флекс') || name.contains('flexo');
}

bool isPackagingStage(Map<String, dynamic> map, String? stageId) =>
    stage_sequence.isPackagingStage(
      stageId: stageId,
      stageName: _stageNameFromMap(map),
      stageType: (map['stageType'] ?? map['stage_type'] ?? map['type'])
          ?.toString(),
      stageGroupKey: (map['stageGroupKey'] ??
              map['stage_group_key'] ??
              map['queueStageKey'] ??
              map['queue_stage_key'])
          ?.toString(),
    );

String _stageNameFromMap(Map<String, dynamic> map) => (map['stageName'] ??
        map['stage_name'] ??
        map['workplaceName'] ??
        map['workplace_name'] ??
        map['title'] ??
        map['name'] ??
        '')
    .toString()
    .trim()
    .toLowerCase();

class _OrderStageQueueBuilder {
  _OrderStageQueueBuilder(this.draft);

  final OrderStageQueueDraft draft;
  final List<BuiltOrderStage> _stages = <BuiltOrderStage>[];

  List<BuiltOrderStage> build() {
    _appendBaseStages();
    _appendProductStages();
    _add(_stage(kPackagingStageId, 'Упаковка'));
    return _finalize();
  }

  void _appendBaseStages() {
    if (_needsBobbinCutting) {
      _add(_stage(kBobbinStageId, 'Бабинорезка'));
    }
    if (draft.hasPaint) {
      _add(_stage(kFlexPrintingStageId, 'Флексопечать'));
    }
  }

  bool get _needsBobbinCutting {
    final orderWidth = draft.orderWidthB;
    final material = draft.materialWidth;
    if (draft.requiresBobbinCutting != null) {
      return draft.requiresBobbinCutting!;
    }
    if (orderWidth == null || material == null) return false;
    return orderWidth > 0 && material > 0 && orderWidth < material;
  }

  void _appendProductStages() {
    final productTypeId = draft.productTypeId.trim();
    if (_isSheetProduct(productTypeId)) {
      _add(_stage(kSheetCutStageId, 'Листорезка'));
      if (draft.hasTrimming) _add(_stage(kCuttingStageId, 'Резка'));
      _appendHandleStage();
      return;
    }
    if (_isVTypeProduct(productTypeId)) {
      _add(_switchableStage(
        stageKey: kVMainSwitchStageKey,
        stageName: _vSwitchableName,
        workplaceIds: const [kFriStageId, kWindowStageId],
        groupKey: kSwitchableVGroupKey,
        fallbackSelectedId: kFriStageId,
      ));
      if (draft.hasTrimming) _add(_stage(kCuttingStageId, 'Резка'));
      _appendHandleStage();
      return;
    }
    if (_isTwoSheetPackageProduct(productTypeId)) {
      _appendTwoSheetPackageStages();
      return;
    }
    if (_isPTypePackageProduct(productTypeId)) {
      _appendPTypePackageStages();
    }
  }

  void _appendPTypePackageStages() {
    final selectedWorkplaceId = _selectedForSwitchable(
      stageKey: kPMainSwitchStageKey,
      groupKey: kSwitchablePGroupKey,
      fallback: kAutoBigStageId,
    );

    _add(_switchableStage(
      stageKey: kPMainSwitchStageKey,
      stageName: _selectedName(selectedWorkplaceId),
      workplaceIds: const [kAutoBigStageId, kAutoSmallStageId, kTubeStageId],
      groupKey: kSwitchablePGroupKey,
      fallbackSelectedId: kAutoBigStageId,
    ));
    if (draft.hasTrimming) _add(_stage(kCuttingStageId, 'Резка'));

    // Труба — другой способ сборки: дно собирают и склеивают всегда, даже
    // без картона. Раньше эти этапы жили внутри ветки картона, поэтому
    // переключение автомата на трубу без картона вообще не меняло маршрут.
    final bool isTube = selectedWorkplaceId == kTubeStageId;

    if (draft.hasCardboard) {
      _add(_stage(kCardboardCuttingStageId, 'Резка картона'));
      // На автоматах картон вставляют отдельным этапом; у трубы он входит
      // в сборку дна ниже, поэтому «Вставка картона» здесь не нужна.
      if (!isTube) {
        _add(_stage(kCardboardInsertStageId, 'Вставка картона'));
      }
    }

    if (isTube) {
      _add(_stage(
        kBottomWithCardboardAssemblyStageId,
        'Сборка дно+картон',
      ));
      _add(_stage(
        kBottomGlueStageId,
        'Склейка дна',
        workplaceIds: const [
          kBottomGlueWorkplaceId,
          kBottomGlueAltWorkplaceId,
          kBottomGlueSecondAltWorkplaceId,
        ],
      ));
    }
    _appendHandleStage();
  }

  void _appendTwoSheetPackageStages() {
    _add(_stage(kSheetCutStageId, 'Листорезка'));
    if (draft.hasTrimming) _add(_stage(kCuttingStageId, 'Резка'));
    _add(_stage(
      kDieCutA1A2StageId,
      'Высечка A1/A2',
      workplaceIds: const [kDieCutA1WorkplaceId, kDieCutA2WorkplaceId],
    ));
    _add(_stage(kScotchStageId, 'Скотч'));
    _add(_stage(kFromTwoSheetsStageId, 'С 2х листов'));
    _add(_stage(kTubeAssemblyStageId, 'Сборка трубы'));
    if (draft.hasCardboard) {
      _add(_stage(kCardboardCuttingStageId, 'Резка картона'));
    }
    _add(_stage(
      kBottomWithCardboardAssemblyStageId,
      'Сборка дно+картон',
    ));
    _add(_stage(
      kBottomGlueStageId,
      'Склейка дна',
      workplaceIds: const [
        kBottomGlueWorkplaceId,
        kBottomGlueAltWorkplaceId,
        kBottomGlueSecondAltWorkplaceId,
      ],
    ));
    _appendHandleStage();
  }

  void _appendHandleStage() {
    final type = draft.handleType;
    if (type == OrderHandleType.flat) {
      _add(_stage(
        kFlatHandleGroupStageId,
        'Плоская ручка',
        workplaceIds: const [
          kFlatHandleWorkplaceId,
          kSharedHandleWorkplaceId,
        ],
      ));
    } else if (type == OrderHandleType.twisted) {
      _add(_stage(
        kTwistedHandleGroupStageId,
        'Кручёная ручка',
        workplaceIds: const [
          kTwistedHandleWorkplaceId,
          kSharedHandleWorkplaceId,
        ],
      ));
    } else if (type == OrderHandleType.dieCut) {
      _add(_stage(kDieCutHandleStageId, 'Вырубка'));
    }
  }

  String get _vSwitchableName => _selectedName(_selectedForSwitchable(
        stageKey: kVMainSwitchStageKey,
        groupKey: kSwitchableVGroupKey,
        fallback: kFriStageId,
      ));

  BuiltOrderStage _stage(
    String stageKey,
    String stageName, {
    List<String>? workplaceIds,
  }) {
    final ids = workplaceIds ?? <String>[stageKey];
    return BuiltOrderStage(
      stageKey: stageKey,
      stageName: stageName,
      workplaceIds: ids,
      selectedWorkplaceId: ids.isNotEmpty ? ids.first : null,
    );
  }

  BuiltOrderStage _switchableStage({
    required String stageKey,
    required String stageName,
    required List<String> workplaceIds,
    required String groupKey,
    required String fallbackSelectedId,
  }) {
    final selected = _selectedForSwitchable(
      stageKey: stageKey,
      groupKey: groupKey,
      fallback: fallbackSelectedId,
    );
    return BuiltOrderStage(
      stageKey: stageKey,
      stageName: stageName,
      workplaceIds: workplaceIds,
      isSwitchable: true,
      switchableGroupKey: groupKey,
      selectedWorkplaceId: selected,
    );
  }

  String _selectedForSwitchable({
    required String stageKey,
    required String groupKey,
    required String fallback,
  }) {
    final selectedByStageKey =
        draft.selectedSwitchableStageIdsByStageKey[stageKey];
    if (selectedByStageKey != null &&
        _switchableIdsByStageKey[stageKey]!.contains(selectedByStageKey)) {
      return selectedByStageKey;
    }

    final selected = draft.selectedSwitchableStageId;
    if (draft.switchableStageKey != null &&
        draft.switchableStageKey != groupKey &&
        draft.switchableStageKey != stageKey) {
      return fallback;
    }
    if (selected != null &&
        _switchableIdsByGroup[groupKey]!.contains(selected)) {
      return selected;
    }
    return fallback;
  }

  void _add(BuiltOrderStage stage) {
    _stages.add(stage);
  }

  List<BuiltOrderStage> _finalize() {
    final deduped = <BuiltOrderStage>[];
    final seenKeys = <String>{};
    BuiltOrderStage? packaging;

    for (final stage in _stages) {
      if (stage.stageKey == kPackagingStageId) {
        packaging = stage;
        continue;
      }
      if (seenKeys.add(stage.stageKey)) deduped.add(stage);
    }

    packaging ??= _stage(kPackagingStageId, 'Упаковка');
    deduped.add(packaging);

    return [
      for (var i = 0; i < deduped.length; i++)
        deduped[i].copyWith(sortOrder: i + 1),
    ];
  }
}

const Map<String, Set<String>> _switchableIdsByStageKey = {
  kVMainSwitchStageKey: {kFriStageId, kWindowStageId},
  kPMainSwitchStageKey: {kAutoBigStageId, kAutoSmallStageId, kTubeStageId},
};

const Map<String, String> _switchableGroupKeyByStageKey = {
  kVMainSwitchStageKey: kSwitchableVGroupKey,
  kPMainSwitchStageKey: kSwitchablePGroupKey,
};

const Map<String, Set<String>> _switchableIdsByGroup = {
  kSwitchableVGroupKey: {kFriStageId, kWindowStageId},
  kSwitchablePGroupKey: {kAutoBigStageId, kAutoSmallStageId, kTubeStageId},
};

bool isSheetProductType(String productTypeId) => _isSheetProduct(productTypeId);

bool isVTypeProductType(String productTypeId) => _isVTypeProduct(productTypeId);

bool isTwoSheetPackageProductType(String productTypeId) =>
    _isTwoSheetPackageProduct(productTypeId);

bool isPTypePackageProductType(String productTypeId) =>
    _isPTypePackageProduct(productTypeId);

bool supportsCardboardForProductType(String productTypeId) =>
    !_isSheetProduct(productTypeId) && !_isVTypeProduct(productTypeId);

bool _isSheetProduct(String productTypeId) {
  final normalized = _normalizeProductType(productTypeId);
  return kSheetProducts.contains(productTypeId) || normalized == 'листы';
}

bool _isVTypeProduct(String productTypeId) {
  final normalized = _normalizeProductType(productTypeId);
  return kVTypeProducts.contains(productTypeId) ||
      normalized == 'v пакет' ||
      normalized == 'v-пакет' ||
      normalized == 'в образные' ||
      normalized == 'в-образные' ||
      normalized == 'в-образный окно' ||
      normalized == 'в-образный пакет' ||
      normalized == 'в-образный фри' ||
      normalized == 'в-образный уголок';
}

bool _isTwoSheetPackageProduct(String productTypeId) {
  final normalized = _normalizeProductType(productTypeId);
  return kTwoSheetPackageProducts.contains(productTypeId) ||
      normalized == 'пакет из 2х листов' ||
      normalized == 'пакет из 2 листов';
}

bool _isPTypePackageProduct(String productTypeId) {
  final normalized = _normalizeProductType(productTypeId);
  return kPTypePackageProducts.contains(productTypeId) ||
      normalized == 'п пакет' ||
      normalized == 'п-пакет' ||
      normalized == 'п образный пакет' ||
      normalized == 'п-образный пакет';
}

String _normalizeProductType(String value) {
  return value
      .trim()
      .toLowerCase()
      .replaceAll('ё', 'е')
      .replaceAll(RegExp(r'\s+'), ' ');
}

String _selectedName(String stageId) {
  switch (stageId) {
    case kFriStageId:
      return 'Фри';
    case kWindowStageId:
      return 'Окно';
    case kAutoBigStageId:
      return 'Автомат большой';
    case kAutoSmallStageId:
      return 'Автомат маленький';
    case kTubeStageId:
      return 'Труба';
    default:
      return '';
  }
}

Map<String, String> collectSwitchableStageSelectionsByStageKey(
  List<Map<String, dynamic>> stages,
) =>
    _selectedSwitchableStageIdsByStageKey(stages);

Map<String, String> _selectedSwitchableStageIdsByStageKey(
  List<Map<String, dynamic>> stages,
) {
  final selections = <String, String>{};
  for (final stage in stages) {
    final rawStageKey = (stage['stageKey'] ?? stage['stage_key'])?.toString();
    final rawGroupKey = stage['switchableGroupKey']?.toString();
    final selectedId = _selectedSwitchableIdFromStage(stage);
    if (selectedId == null) continue;
    final stageKey = _normalizeSwitchableStageKey(rawStageKey, rawGroupKey) ??
        _switchableStageKeyForWorkplaceId(selectedId);
    if (stageKey == null) continue;
    if (_switchableIdsByStageKey[stageKey]!.contains(selectedId)) {
      selections[stageKey] = selectedId;
    }
  }
  return selections;
}

String? _normalizeSwitchableStageKey(String? stageKey, String? groupKey) {
  if (stageKey != null && _switchableIdsByStageKey.containsKey(stageKey)) {
    return stageKey;
  }
  if (stageKey == kSwitchableVGroupKey || groupKey == kSwitchableVGroupKey) {
    return kVMainSwitchStageKey;
  }
  if (stageKey == kSwitchablePGroupKey || groupKey == kSwitchablePGroupKey) {
    return kPMainSwitchStageKey;
  }
  return null;
}

String? _switchableStageKeyForWorkplaceId(String workplaceId) {
  for (final entry in _switchableIdsByStageKey.entries) {
    if (entry.value.contains(workplaceId)) return entry.key;
  }
  return null;
}

String? _selectedSwitchableIdFromStage(Map<String, dynamic> stage) {
  final id = (stage['selectedWorkplaceId'] ??
          stage['stageId'] ??
          stage['stage_id'] ??
          stage['stageid'] ??
          stage['workplaceId'] ??
          stage['workplace_id'] ??
          stage['id'])
      ?.toString();
  if (id == null || id.isEmpty) return null;
  if (id == kVMainSwitchStageKey ||
      id == kPMainSwitchStageKey ||
      id == kSwitchableVGroupKey ||
      id == kSwitchablePGroupKey) {
    return null;
  }
  return id;
}

String? _selectedSwitchableStageId(List<Map<String, dynamic>> stages) {
  for (final stage in stages) {
    final id = (stage['selectedWorkplaceId'] ??
            stage['stageId'] ??
            stage['stage_id'] ??
            stage['stageid'] ??
            stage['workplaceId'] ??
            stage['workplace_id'] ??
            stage['id'])
        ?.toString();
    if (id == null || id.isEmpty) continue;
    if (id == kSwitchableVGroupKey || id == kSwitchablePGroupKey) {
      continue;
    }
    if (_switchableIdsByGroup.values.any((ids) => ids.contains(id))) return id;
  }
  return null;
}

List<Map<String, dynamic>> insertProductStageAfterBaseStages(
  List<Map<String, dynamic>> queue,
  Map<String, dynamic> productStage,
) {
  bool isBaseStage(Map<String, dynamic> stage) {
    final id = (stage['stageId'] ?? stage['id'] ?? '').toString().toLowerCase();
    final name = (stage['stageName'] ??
            stage['workplaceName'] ??
            stage['title'] ??
            stage['name'] ??
            '')
        .toString()
        .toLowerCase();
    const baseIds = <String>{
      ...kLegacyBobbinStageAliases,
      ...kLegacyFlexPrintingStageAliases,
      kBobbinStageId,
      kFlexPrintingStageId,
    };
    if (baseIds.contains(id)) return true;
    return name.contains('бобин') ||
        name.contains('бабин') ||
        name.contains('флексо') ||
        name.contains('flexo') ||
        name.contains('печать');
  }

  var insertAt = -1;
  for (var i = 0; i < queue.length; i++) {
    if (isBaseStage(queue[i])) insertAt = i;
  }
  final next = List<Map<String, dynamic>>.from(queue);
  next.insert(insertAt + 1, productStage);
  return next;
}

String? toggleProductStage(String stageId) {
  switch (stageId) {
    case kFriStageId:
      return kWindowStageId;
    case kWindowStageId:
      return kFriStageId;
    case kAutoBigStageId:
      return kAutoSmallStageId;
    case kAutoSmallStageId:
      return kTubeStageId;
    case kTubeStageId:
      return kAutoBigStageId;
    default:
      return null;
  }
}

Map<String, dynamic>? toggleProductStageObject(Map<String, dynamic> stage) {
  final currentId = _selectedSwitchableIdFromStage(stage);
  if (currentId == null) return null;
  final stageKey = _normalizeSwitchableStageKey(
        (stage['stageKey'] ?? stage['stage_key'])?.toString(),
        stage['switchableGroupKey']?.toString(),
      ) ??
      _switchableStageKeyForWorkplaceId(currentId);
  if (stageKey == null) return null;
  final toggledId = toggleProductStage(currentId);
  if (toggledId == null ||
      !_switchableIdsByStageKey[stageKey]!.contains(toggledId)) {
    return null;
  }

  final updated = Map<String, dynamic>.from(stage);
  final stageName = _selectedName(toggledId);
  updated['stageKey'] = stageKey;
  updated['stageId'] = toggledId;
  updated['stage_id'] = toggledId;
  updated['stageid'] = toggledId;
  updated['id'] = toggledId;
  updated['workplaceId'] = toggledId;
  updated['workplace_id'] = toggledId;
  updated['stageName'] = stageName;
  updated['workplaceName'] = stageName;
  updated['isSwitchable'] = true;
  updated['switchableGroupKey'] = _switchableGroupKeyByStageKey[stageKey];
  updated['selectedWorkplaceId'] = toggledId;
  updated['workplaceIds'] =
      List<String>.from(_switchableIdsByStageKey[stageKey]!);
  updated['alternativeStageIds'] = _switchableIdsByStageKey[stageKey]!
      .where((id) => id != toggledId)
      .toList(growable: false);
  return updated;
}