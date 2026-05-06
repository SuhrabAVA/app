import 'order_stage_filter.dart';

// Product type IDs from the production routing specification.
const String kSheetProductTypeId = 'aab3ed17-1688-43f0-b623-58dac264941f';
const String kSheetProductTypeAltId = 'b07cd977-939c-4d4f-b68c-8d163341460e';
const Set<String> kSheetProducts = {
  kSheetProductTypeId,
  kSheetProductTypeAltId,
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

const String kTwoSheetPackageProductTypeId = 'package_two_sheets';
const Set<String> kTwoSheetPackageProducts = {kTwoSheetPackageProductTypeId};

const String kPTypePackageProduct = '71c889cb-b24c-4bda-9a69-ae312f9a4bbd';
const Set<String> kPTypePackageProducts = {kPTypePackageProduct};

// Workplace/stage IDs from the production routing specification.
const String kBobbinStageId = 'b92a89d1-8e95-4c6d-b990-e308486e4bf1';
const String kFlexPrintingStageId = '0571c01c-f086-47e4-81b2-5d8b2ab91218';
const String kPackagingStageId = 'edeb85db-c7a3-4a24-8f33-70ccdda4aae1';
const String kFriStageId = '92d96ee9-0519-40b9-bd17-9bec475496b6';
const String kWindowStageId = '8337f16e-c2d1-42dc-966d-6277ba3c1a50';
const String kAutoBigStageId = 'fdbf1735-a67c-47c9-a7e1-90546effe6ed';
const String kAutoSmallStageId = 'cbcbe469-b924-4064-ae05-885ccd1b842a';
const String kTubeStageId = 'e62fc013-4785-4375-b3ee-a3ca51f77199';
const String kSheetCutStageId = '19a67630-8374-4f9f-ae5b-f2f66828720b';
const String kCuttingStageId = cuttingStageId;
const String kCardboardStageId = cardboardStageId;
const String kFlatHandleStageId = flatHandleStageId;
const String kTwistedHandleStageId = twistedHandleStageId;

// The following technological stage keys are intentionally distinct even when
// a customer installation maps several of them to the same physical workplace.
const String kDieCutA1StageId = 'die_cut_a1';
const String kDieCutA2StageId = 'die_cut_a2';
const String kScotchStageId = 'scotch';
const String kFromTwoSheetsStageId = 'from_two_sheets';
const String kTubeAssemblyStageId = 'tube_assembly';
const String kBottomGlueStageId = 'bottom_glue';

const String kSwitchableVGroupKey = 'v_bottom_stage';
const String kSwitchablePGroupKey = 'p_package_stage';

class OrderStageQueueDraft {
  const OrderStageQueueDraft({
    required this.productTypeId,
    this.orderWidthB,
    this.materialWidth,
    required this.hasPaint,
    required this.hasTrimming,
    required this.hasCardboard,
    this.handleType,
    this.switchableStageKey,
    this.selectedSwitchableStageId,
  });

  final String productTypeId;
  final double? orderWidthB;
  final double? materialWidth;
  final bool hasPaint;
  final bool hasTrimming;
  final bool hasCardboard;
  final Object? handleType;
  final String? switchableStageKey;
  final String? selectedSwitchableStageId;
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
    final selectedId = selectedWorkplaceId ??
        (workplaceIds.isNotEmpty ? workplaceIds.first : stageKey);
    return {
      'stageKey': stageKey,
      'stageId': selectedId,
      'id': selectedId,
      'workplaceId': selectedId,
      'workplaceIds': List<String>.from(workplaceIds),
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
  required bool hasBobbinCutting,
  required bool hasFlexPrinting,
  Object? handleType,
  double? orderWidthB,
  double? materialWidth,
  String? switchableStageKey,
  String? selectedSwitchableStageId,
  List<Map<String, dynamic>> existingStages = const [],
  List<Map<String, dynamic>> templateStages = const [],
}) {
  final selectedFromSource = selectedSwitchableStageId ??
      _selectedSwitchableStageId(existingStages) ??
      _selectedSwitchableStageId(templateStages);
  final useLegacyBobbinFlag =
      orderWidthB == null && materialWidth == null && hasBobbinCutting;
  final draft = OrderStageQueueDraft(
    productTypeId: productTypeId,
    orderWidthB: useLegacyBobbinFlag ? 0 : orderWidthB,
    materialWidth: useLegacyBobbinFlag ? 1 : materialWidth,
    hasPaint: hasFlexPrinting,
    hasTrimming: hasCutting,
    hasCardboard: hasCardboard,
    handleType: handleType,
    switchableStageKey: switchableStageKey,
    selectedSwitchableStageId: selectedFromSource,
  );
  return buildOrderStages(draft).map((stage) => stage.toMap()).toList();
}

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
    if (orderWidth != null && material != null) return orderWidth < material;
    return false;
  }

  void _appendProductStages() {
    final productTypeId = draft.productTypeId.trim();
    if (_isSheetProduct(productTypeId)) {
      _add(_stage(kSheetCutStageId, 'Листорезка'));
      if (draft.hasTrimming) _add(_stage(kCuttingStageId, 'Резка'));
      return;
    }
    if (_isVTypeProduct(productTypeId)) {
      _add(_switchableStage(
        stageKey: kSwitchableVGroupKey,
        stageName: _vSwitchableName,
        workplaceIds: const [kFriStageId, kWindowStageId],
        groupKey: kSwitchableVGroupKey,
        fallbackSelectedId: kFriStageId,
      ));
      return;
    }
    if (_isTwoSheetPackageProduct(productTypeId)) {
      _add(_stage(kSheetCutStageId, 'Листорезка'));
      _add(_stage(kCuttingStageId, 'Резка'));
      _add(_stage(
        'die_cut_a1',
        'Высечка A1',
        workplaceIds: const [kDieCutA1StageId],
      ));
      _add(_stage(
        'die_cut_a2',
        'Высечка A2',
        workplaceIds: const [kDieCutA2StageId],
      ));
      _add(_stage(kScotchStageId, 'Скотч'));
      _add(_stage(kFromTwoSheetsStageId, 'С 2х листов'));
      _add(_stage(kTubeAssemblyStageId, 'Сборка трубы'));
      _appendCardboardStages();
      _add(_stage(kBottomGlueStageId, 'Склейка дна'));
      _appendHandleStage();
      return;
    }
    if (_isPTypePackageProduct(productTypeId)) {
      _add(_switchableStage(
        stageKey: kSwitchablePGroupKey,
        stageName: _pSwitchableName,
        workplaceIds: const [kAutoBigStageId, kAutoSmallStageId, kTubeStageId],
        groupKey: kSwitchablePGroupKey,
        fallbackSelectedId: kAutoBigStageId,
      ));
      _appendCardboardStages();
      _appendHandleStage();
    }
  }

  void _appendCardboardStages() {
    if (draft.hasCardboard) _add(_stage(kCardboardStageId, 'Картон'));
  }

  void _appendHandleStage() {
    final type = draft.handleType;
    if (type == OrderHandleType.flat) {
      _add(_stage(kFlatHandleStageId, 'Плоская ручка'));
    } else if (type == OrderHandleType.twisted) {
      _add(_stage(kTwistedHandleStageId, 'Кручёная ручка'));
    }
  }

  String get _vSwitchableName =>
      _selectedName(_selectedForGroup(kSwitchableVGroupKey, kFriStageId));

  String get _pSwitchableName =>
      _selectedName(_selectedForGroup(kSwitchablePGroupKey, kAutoBigStageId));

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
    final selected = _selectedForGroup(groupKey, fallbackSelectedId);
    return BuiltOrderStage(
      stageKey: stageKey,
      stageName: stageName,
      workplaceIds: workplaceIds,
      isSwitchable: true,
      switchableGroupKey: groupKey,
      selectedWorkplaceId: selected,
    );
  }

  String _selectedForGroup(String groupKey, String fallback) {
    final selected = draft.selectedSwitchableStageId;
    if (draft.switchableStageKey != null &&
        draft.switchableStageKey != groupKey) {
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

const Map<String, Set<String>> _switchableIdsByGroup = {
  kSwitchableVGroupKey: {kFriStageId, kWindowStageId},
  kSwitchablePGroupKey: {kAutoBigStageId, kAutoSmallStageId, kTubeStageId},
};

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
      normalized == 'в-образные';
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
      'w_bobiner',
      'w_bobbin',
      'w_flexoprint',
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
