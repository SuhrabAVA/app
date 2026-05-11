import 'order_stage_filter.dart';
import 'material_model.dart';

// Product type IDs from the production routing specification.
const String kSheetProductTypeId = 'aab3ed17-1688-43f0-b623-58dac264941f';
const Set<String> kSheetProducts = {
  kSheetProductTypeId,
};

const String kVTypeProductId = '448b731a-eafe-40f1-9268-bc5dd6ba57bc';
const String kVTypeProductAltId = '688ce20b-2db5-43ed-a414-dda08443a06a';
const String kVTypeProductAlt2Id = 'd2323dba-74c9-4e86-adfb-18cd47be9480';
const String kVTypeProductAlt3Id = 'dfd3beb1-1afd-4c06-9b3b-5da680377b0d';
const Set<String> kVTypeProducts = {
  kVTypeProductId,
  kVTypeProductAltId,
  kVTypeProductAlt2Id,
  kVTypeProductAlt3Id,
};

const String kTwoSheetPackageProductTypeId =
    'b07cd977-939c-4d4f-b68c-8d163341460e';
const Set<String> kTwoSheetPackageProducts = {kTwoSheetPackageProductTypeId};

const String kPTypePackageProduct = '71c889cb-b24c-4bda-9a69-ae312f9a4bbd';
const Set<String> kPTypePackageProducts = {kPTypePackageProduct};

// Workplace/stage IDs from the production routing specification.
const String kBobbinStageId = 'b92a89d1-8e95-4c6d-b990-e308486e4bf1';
const String kFlexPrintingStageId = '0571c01c-f086-47e4-81b2-5d8b2ab91218';
const Set<String> kLegacyBobbinStageAliases = {'w_bobiner', 'w_bobbin'};
const Set<String> kLegacyFlexPrintingStageAliases = {'w_flexoprint', 'w_flexo'};
const String kPackagingStageId = 'edeb85db-c7a3-4a24-8f33-70ccdda4aae1';
const String kFriStageId = '92d96ee9-0519-40b9-bd17-9bec475496b6';
const String kWindowStageId = '8337f16e-c2d1-42dc-966d-6277ba3c1a50';
const String kAutoBigStageId = 'fdbf1735-a67c-47c9-a7e1-90546effe6ed';
const String kAutoSmallStageId = 'cbcbe469-b924-4064-ae05-885ccd1b842a';
const String kTubeStageId = 'e62fc013-4785-4375-b3ee-a3ca51f77199';
const String kSheetCutStageId = '19a67630-8374-49f1-ae5b-f2f66828720b';
const String kCuttingStageId = cuttingStageId;
const String kCardboardCuttingStageId =
    'd7d91f75-2f85-446f-8c1d-a20606bdb3b1';
const String kCardboardInsertStageId =
    'ce15da53-34bb-4a48-acef-610ddfd4a42e';
const String kBottomWithCardboardAssemblyStageId =
    'd15da69b-9842-4967-96ed-28a4834b409e';
const String kFlatHandleStageId = flatHandleStageId;
const String kTwistedHandleStageId = twistedHandleStageId;
const String kManualHandleStageId = manualHandleStageId;
const String kDieCutHandleStageId = dieCutHandleStageId;

const String kDieCutA1WorkplaceId = '7c168998-76b8-4a4c-9708-af45c2dbd4f0';
const String kDieCutA2WorkplaceId = '5a47821b-c276-4deb-90de-f196539fc95d';
const String kBottomGlueWorkplaceId = 'dee83c5c-4624-4ca4-b36c-47673dc5cd72';
const String kBottomGlueAltWorkplaceId = 'ad504db5-86c3-4284-8266-42bbf967b064';
const String kBottomGlueSecondAltWorkplaceId =
    '96075b60-77d8-4fb2-91b0-bfbe6c1ed13c';
const String kTwistedHandleWorkplaceId = 'c51ebb2e-dac8-4068-9e4c-ce0d8b975626';
const String kSharedHandleWorkplaceId = kManualHandleStageId;
const String kFlatHandleWorkplaceId = kFlatHandleStageId;

// The following technological stage keys are intentionally distinct even when
// a customer installation maps several of them to the same physical workplace.
const String kDieCutA1A2StageId = 'die_cut_a1_a2';
const String kScotchStageId = 'a9e21c59-e145-4074-8d24-f2db089c8747';
const String kFromTwoSheetsStageId = '008a5bbd-86f8-48c1-a98b-0034f80492a6';
const String kTubeAssemblyStageId = '4e4750b0-5849-42be-94b8-a721a68b85da';
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
  return normalizeBuiltOrderStageQueue(
    buildOrderStages(draft).map((stage) => stage.toMap()).toList(),
  );
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
    } else if (_isPackagingStage(map, canonicalId)) {
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
    if (_isPackagingStage(stage, id)) {
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

bool _isPackagingStage(Map<String, dynamic> map, String? stageId) {
  if (stageId == kPackagingStageId) return true;
  return _stageNameFromMap(map).contains('упаков');
}

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
    if (draft.hasCardboard) {
      _add(_stage(kCardboardCuttingStageId, 'Резка картона'));
      if (selectedWorkplaceId == kAutoBigStageId ||
          selectedWorkplaceId == kAutoSmallStageId) {
        _add(_stage(kCardboardInsertStageId, 'Вставка картона'));
      } else if (selectedWorkplaceId == kTubeStageId) {
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
