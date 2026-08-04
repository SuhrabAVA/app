/// Единственное место в проекте, где допустимы uuid-литералы рабочих мест и
/// типов продукта.
///
/// Раньше эти id были раскиданы строковыми литералами по `stage_queue_builder`,
/// `order_stage_filter`, `stage_sequence_utils` и `tasks_screen`. Одни и те же
/// этапы объявлялись по два-три раза, и при очередном копировании в них
/// заводились опечатки: `flatHandleStageId` (`6ffdf2d9` вместо `6fdff2d9`),
/// `twistedHandleStageId` и `kCardboardInsertStageId` в фильтре указывали на
/// несуществующие рабочие места. Ошибка не проявлялась — сравнение строк просто
/// никогда не совпадало.
///
/// Правило: **новые id добавляются только сюда**. За этим следит
/// `test/modules/orders/production_ids_test.dart`, который сверяет реестр со
/// снимком справочника `test/fixtures/workplaces_snapshot.json` и запрещает
/// uuid-литералы в остальных файлах.
///
/// Каждый id объявлен дважды: голой строкой `…Uuid` (её можно использовать в
/// const-выражениях — Dart не умеет читать поля const-объекта) и типизированной
/// обёрткой с именем, по которой работают проверки.
library;

/// Рабочее место из справочника `public.workplaces`.
///
/// Хранит не только uuid, но и имя: тест сверяет пару целиком, поэтому
/// перестановка символов, случайно попавшая в чужой существующий uuid, тоже
/// будет поймана.
class WorkplaceId {
  const WorkplaceId(this.uuid, this.name);

  /// `workplaces.id`.
  final String uuid;

  /// `workplaces.name` на момент занесения в реестр.
  final String name;

  @override
  String toString() => '$name ($uuid)';
}

/// Тип продукта из справочника `public.warehouse_categories`.
class ProductTypeId {
  const ProductTypeId(this.uuid, this.title);

  /// `warehouse_categories.id`.
  final String uuid;

  /// `warehouse_categories.title` на момент занесения в реестр.
  final String title;

  @override
  String toString() => '$title ($uuid)';
}

// === Рабочие места =========================================================

const String wpBobbinUuid = 'b92a89d1-8e95-4c6d-b990-e308486e4bf1';
const String wpFlexPrintingUuid = '0571c01c-f086-47e4-81b2-5d8b2ab91218';
const String wpPackagingUuid = 'edeb85db-c7a3-4a24-8f33-70ccdd4aaae1';
const String wpSheetCutUuid = '19a67630-8374-4f9f-ae5b-f2f66828720b';
const String wpCuttingUuid = 'c828062f-a6a6-4fe5-b01b-c51e36fe5fba';

// Переключаемые рабочие места В-образных пакетов.
const String wpFriUuid = '92d96ee9-0519-40b9-bd17-9bec475496b6';
const String wpWindowUuid = '8337f16e-c2d1-42dc-966d-6277ba3c1a50';

// Переключаемые рабочие места П-образных пакетов.
const String wpAutoBigUuid = 'fdbf1735-a67c-47c9-a7e1-90546e1fe6ed';
const String wpAutoSmallUuid = 'cbcbe469-b924-4064-ae05-885ccd1b842a';
const String wpTubeUuid = 'e62fc013-4785-43f3-b3ee-a3ca51777199';

// Картон.
const String wpCardboardCuttingUuid = 'd7d91f75-2f85-446f-8c1d-a20606bdb3b1';
const String wpCardboardInsertUuid = 'ce15da53-34bb-4a48-acef-610dddfad42e';
const String wpBottomWithCardboardAssemblyUuid =
    'd15da69b-9842-4967-96ed-28a4834b409e';

// Пакет из 2х листов.
const String wpDieCutA1Uuid = '7c168998-76b8-4a4c-9708-af45c2dbd4f0';
const String wpDieCutA2Uuid = '5a47821b-c276-4deb-90de-f196539fc95d';
const String wpScotchUuid = 'a9e21c59-e145-4074-8d24-f2db089c8747';
const String wpFromTwoSheetsUuid = '008a5bbd-86f8-48c1-a98b-0034f80492a6';
const String wpTubeAssemblyUuid = '4e4750b0-5849-42be-94b8-a721a68b85da';

// Склейка дна — три альтернативных рабочих места одного шага.
const String wpBottomGlueManualUuid = 'dee83c5c-4624-4ca4-b36c-47673dc5cd72';
const String wpBottomGlueHotUuid = 'ad504db5-86c3-4284-8266-42bbf967b064';
const String wpBottomGlueColdUuid = '96075b60-77d8-4fb2-91b0-bfbe6c1ed13c';

// Ручки.
//
// `wpFlatHandleUuid` до этого рефакторинга был объявлен как `6ffdf2d9…` —
// перестановка символов, не существующая в справочнике. Значение исправлено.
const String wpFlatHandleUuid = '6fdff2d9-3f57-45ca-9fad-dd700ac5c320';
const String wpTwistedHandleUuid = 'c5c1eb2e-dac8-4068-9e4c-ced8fb975626';
const String wpManualHandleUuid = 'c25ac6fa-390a-4e87-84aa-536055e013f4';
const String wpDieCutHandleUuid = '4925309c-a2c6-4f5f-9f3e-7dd5ff38827d';

const WorkplaceId wpBobbin = WorkplaceId(wpBobbinUuid, 'Бабинорезка');
const WorkplaceId wpFlexPrinting =
    WorkplaceId(wpFlexPrintingUuid, 'Флексопечать');
const WorkplaceId wpPackaging = WorkplaceId(wpPackagingUuid, 'Упаковка');
const WorkplaceId wpSheetCut = WorkplaceId(wpSheetCutUuid, 'Листорезка');
const WorkplaceId wpCutting = WorkplaceId(wpCuttingUuid, 'Резка');
const WorkplaceId wpFri = WorkplaceId(wpFriUuid, 'Фри');
const WorkplaceId wpWindow = WorkplaceId(wpWindowUuid, 'Окно');
const WorkplaceId wpAutoBig = WorkplaceId(wpAutoBigUuid, 'Автомат большой');
const WorkplaceId wpAutoSmall =
    WorkplaceId(wpAutoSmallUuid, 'Автомат маленький');
const WorkplaceId wpTube = WorkplaceId(wpTubeUuid, 'Труба');
const WorkplaceId wpCardboardCutting =
    WorkplaceId(wpCardboardCuttingUuid, 'Резка картона');
const WorkplaceId wpCardboardInsert =
    WorkplaceId(wpCardboardInsertUuid, 'Вставка картона');
const WorkplaceId wpBottomWithCardboardAssembly =
    WorkplaceId(wpBottomWithCardboardAssemblyUuid, 'Сборка дно+картон');
const WorkplaceId wpDieCutA1 = WorkplaceId(wpDieCutA1Uuid, 'Высечка А1');
const WorkplaceId wpDieCutA2 = WorkplaceId(wpDieCutA2Uuid, 'Высечка А2');
const WorkplaceId wpScotch = WorkplaceId(wpScotchUuid, 'Скотч');
const WorkplaceId wpFromTwoSheets =
    WorkplaceId(wpFromTwoSheetsUuid, 'С 2х листов');
const WorkplaceId wpTubeAssembly =
    WorkplaceId(wpTubeAssemblyUuid, 'Сборка трубы');
const WorkplaceId wpBottomGlueManual =
    WorkplaceId(wpBottomGlueManualUuid, 'Склейка дна(ручная)');
const WorkplaceId wpBottomGlueHot =
    WorkplaceId(wpBottomGlueHotUuid, 'Склейка дна (Горячая)');
const WorkplaceId wpBottomGlueCold =
    WorkplaceId(wpBottomGlueColdUuid, 'Склейка дна (Холодная)');
const WorkplaceId wpFlatHandle =
    WorkplaceId(wpFlatHandleUuid, 'Ручка-склейка плоская');
const WorkplaceId wpTwistedHandle =
    WorkplaceId(wpTwistedHandleUuid, 'Ручка-склейка крученая');
const WorkplaceId wpManualHandle =
    WorkplaceId(wpManualHandleUuid, 'Ручка-склейка ручная');
const WorkplaceId wpDieCutHandle = WorkplaceId(wpDieCutHandleUuid, 'Вырубка');

/// Все рабочие места реестра. Обход этого списка — основа проверок в тестах.
const List<WorkplaceId> kAllWorkplaceIds = <WorkplaceId>[
  wpBobbin,
  wpFlexPrinting,
  wpPackaging,
  wpSheetCut,
  wpCutting,
  wpFri,
  wpWindow,
  wpAutoBig,
  wpAutoSmall,
  wpTube,
  wpCardboardCutting,
  wpCardboardInsert,
  wpBottomWithCardboardAssembly,
  wpDieCutA1,
  wpDieCutA2,
  wpScotch,
  wpFromTwoSheets,
  wpTubeAssembly,
  wpBottomGlueManual,
  wpBottomGlueHot,
  wpBottomGlueCold,
  wpFlatHandle,
  wpTwistedHandle,
  wpManualHandle,
  wpDieCutHandle,
];

// === Типы продукта =========================================================

const String ptSheetUuid = 'aab3ed17-1688-43f0-b623-58dac264941f';
const String ptVWindowUuid = '448b731a-eafe-40f1-9268-bc5dd6ba57bc';
const String ptVPackageUuid = '688ce20b-2db5-43ed-a414-dda08443a06a';
const String ptVFriUuid = 'd2323dba-74c9-4e86-adfb-18cd47be9480';
const String ptVCornerUuid = 'dfd3beb1-1afd-4c06-9b3b-5da680377b0d';
const String ptTwoSheetPackageUuid = 'b07cd977-939c-4d4f-b68c-8d163341460e';
const String ptPPackageUuid = '71c889cb-b24c-4bda-9a69-ae312f9a4bbd';

const ProductTypeId ptSheet = ProductTypeId(ptSheetUuid, 'Листы');
const ProductTypeId ptVWindow =
    ProductTypeId(ptVWindowUuid, 'В-образный окно');
const ProductTypeId ptVPackage =
    ProductTypeId(ptVPackageUuid, 'В-образный пакет');
const ProductTypeId ptVFri = ProductTypeId(ptVFriUuid, 'В-образный фри');
const ProductTypeId ptVCorner =
    ProductTypeId(ptVCornerUuid, 'В-образный уголок');
const ProductTypeId ptTwoSheetPackage =
    ProductTypeId(ptTwoSheetPackageUuid, 'Пакет из 2х листов');
const ProductTypeId ptPPackage =
    ProductTypeId(ptPPackageUuid, 'П-образный пакет');

/// Типы продукта, для которых в автосборщике есть правила маршрута.
///
/// «Рулонная печать» и «Готовая продукция» сюда намеренно не входят: правил
/// для них нет, и очередь у таких заказов состоит только из базовых этапов.
const List<ProductTypeId> kAllProductTypeIds = <ProductTypeId>[
  ptSheet,
  ptVWindow,
  ptVPackage,
  ptVFri,
  ptVCorner,
  ptTwoSheetPackage,
  ptPPackage,
];
