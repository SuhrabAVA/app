
// lib/modules/orders/edit_order_screen.dart
import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:uuid/uuid.dart';
import '../../services/app_auth.dart';
import '../../utils/auth_helper.dart';
import 'package:file_picker/file_picker.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../../services/storage_service.dart';
import 'package:image_picker/image_picker.dart';
import 'dart:typed_data';
import 'orders_provider.dart';
import 'order_edit_gate.dart';
import 'order_edit_lease.dart';
import 'order_extra_options.dart';
import 'order_extra_options_block.dart';
import 'order_extra_options_repository.dart';
import 'order_form_design.dart';
import 'order_handle_type.dart';
import 'order_required_blocks.dart';
import 'stage_queue_builder.dart';
import 'order_queue_service.dart';
import 'order_queue_validity.dart';
import 'orders_repository.dart';
import 'order_launch_rules.dart';
import 'order_model.dart';
import 'paper_usage_rules.dart';
import 'paper_length_rules.dart';
import 'order_form_rules.dart';
import 'product_model.dart';
import 'product_type_route.dart';
import 'product_type_settings.dart';
import 'material_model.dart';
import '../products/products_provider.dart';
import '../production_planning/template_provider.dart';
import '../production_planning/template_model.dart';
import '../warehouse/warehouse_provider.dart';
import '../warehouse/stock_tables.dart';
import '../warehouse/paint_stock_rules.dart';
import '../warehouse/tmc_model.dart';
import '../personnel/personnel_provider.dart';
import '../common/pdf_view_screen.dart';
import '../../utils/media_viewer.dart';
import '../../utils/enter_key_behavior.dart';
import 'order_comments_timeline.dart';
import '../../widgets/error_overlay.dart' show appNavigatorKey;

/// Подпись под полем количества, когда запрошено больше доступного.
///
/// Одна на бумагу и на краску: обе меряются одинаково — складской остаток
/// минус брони чужих заказов, — и разные формулировки у соседних полей
/// читались бы как разные правила.
const String kNotEnoughMaterialError = 'Недостаточно материала';

/// Показывает snackbar поверх текущего экрана приложения — нужен для
/// уведомлений о результате фонового сохранения заказа, когда экран
/// редактирования уже закрыт (и обычный ScaffoldMessenger экрана недоступен).
void _showBackgroundSaveSnackBar(String message, {bool isError = false}) {
  final ctx = appNavigatorKey.currentContext;
  if (ctx == null) return;
  ScaffoldMessenger.of(ctx).showSnackBar(
    SnackBar(
      content: Text(message),
      backgroundColor: isError ? Colors.red.shade700 : null,
    ),
  );
}

/// Экран редактирования или создания заказа.
/// Если [order] передан, экран открывается для редактирования существующего заказа.
class EditOrderScreen extends StatelessWidget {
  const EditOrderScreen({super.key, this.order, this.initialOrder});
  final OrderModel? order;
  final OrderModel? initialOrder;

  @override
  Widget build(BuildContext context) => order == null
      ? _OrderEditor(initialOrder: initialOrder)
      : OrderEditGate(
          orderId: order!.id,
          initialOrder: order,
          builder: (fresh, lease) => _OrderEditor(order: fresh, lease: lease),
          fallbackBuilder: (stale) => _OrderEditor(order: stale),
        );
}

class _OrderEditor extends StatefulWidget {
  final OrderModel? order;

  /// Если [initialOrder] передан, экран заполняется данными, но создаётся
  /// новый заказ, а не редактируется существующий.
  final OrderModel? initialOrder;
  const _OrderEditor({this.order, this.initialOrder, this.lease});
  final OrderEditLease? lease;
  @override
  State<_OrderEditor> createState() => _EditOrderScreenState();
}

const bool _disableSwitchableStageDotTooltipDiagnostic =
    bool.fromEnvironment('DISABLE_SWITCHABLE_STAGE_DOT_TOOLTIP_DIAGNOSTIC');

class _SwitchableStageOption {
  const _SwitchableStageOption(this.stageId, this.label);

  final String stageId;
  final String label;
}

class _SwitchableStageDot extends StatelessWidget {
  const _SwitchableStageDot({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final fillColor = selected
        ? colors.primary.withValues(alpha: 0.18)
        : colors.surfaceContainerHighest.withValues(alpha: 0.3);
    final borderColor = selected
        ? colors.primary.withValues(alpha: 0.72)
        : colors.outlineVariant.withValues(alpha: 0.9);

    final dot = Semantics(
      button: true,
      selected: selected,
      label: label,
      child: InkResponse(
        onTap: onTap,
        radius: 18,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 160),
          curve: Curves.easeOut,
          width: 20,
          height: 20,
          padding: const EdgeInsets.all(4),
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: fillColor,
            border: Border.all(color: borderColor, width: 1.5),
          ),
          child: selected
              ? DecoratedBox(
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: colors.primary.withValues(alpha: 0.78),
                  ),
                )
              : null,
        ),
      ),
    );

    // Diagnostic-only escape hatch for Windows accessibility spam checks.
    // Keep this local to the suspected form-choice dot instead of disabling
    // Tooltip, SnackBar, FocusNode, or Semantics globally.
    if (_disableSwitchableStageDotTooltipDiagnostic) {
      return dot;
    }

    return Tooltip(
      message: label,
      child: dot,
    );
  }
}

class _PaintEntry {
  TmcModel? tmc;
  String? name;
  double? qtyGrams;
  String memo;
  bool exceeded;
  bool nameNotFound;

  /// Ровно то, что набрано в поле, без обрезки краёв.
  ///
  /// Без этого поля поиск нельзя было набрать: [name] хранился обрезанным
  /// (`value.trim()`), [displayName] возвращал его же, а fieldViewBuilder на
  /// каждой перерисовке возвращал текст контроллера к [displayName]. Пробел,
  /// набранный в конце, исчезал в тот же кадр — «192 красный» напечатать было
  /// невозможно, поиск обрывался на первом слове. `null` — поле ещё не
  /// трогали руками, показываем [displayName].
  String? rawInput;

  _PaintEntry(
      {this.tmc,
      this.name,
      this.qtyGrams,
      this.memo = '',
      this.exceeded = false,
      this.nameNotFound = false,
      this.rawInput});

  String get displayName => tmc?.description ?? name ?? '';
  bool get hasName => displayName.trim().isNotEmpty;
  double? get qtyKg => qtyGrams == null ? null : qtyGrams! / 1000;
  set qtyKg(double? value) => qtyGrams = value == null ? null : value * 1000;
}

/// Прежнее зашитое правило «нет картона у Листов и В-образных».
///
/// С миграции 20260806 оно живёт в данных (`product_type_form_blocks`), а здесь
/// остаётся фолбэком на то время, пока настройки ещё не приехали из базы, —
/// иначе на первом кадре чекбокс «Картон» мигал бы. Тесты
/// `edit_order_screen_cardboard_test.dart` проверяют именно этот фолбэк.
bool supportsCardboardForTesting(String productTypeId) =>
    supportsCardboardForProductType(productTypeId);

List<Map<String, dynamic>> _buildStageMapsForProductionPlanSave({
  required List<Map<String, dynamic>> stagePreviewStages,
  required String? stageTemplateId,
  required List<Map<String, dynamic>> selectedTemplateStages,
  required List<Map<String, dynamic>> Function({
    required List<Map<String, dynamic>> templateStages,
  }) buildStageQueueFromCurrentDraft,
}) {
  return buildStageQueueFromCurrentDraft(
    templateStages: selectedTemplateStages,
  );
}

@visibleForTesting
List<Map<String, dynamic>> buildStageMapsForProductionPlanSaveForTesting({
  required List<Map<String, dynamic>> stagePreviewStages,
  required String? stageTemplateId,
  required List<Map<String, dynamic>> selectedTemplateStages,
  required List<Map<String, dynamic>> Function({
    required List<Map<String, dynamic>> templateStages,
  }) buildStageQueueFromCurrentDraft,
}) =>
    _buildStageMapsForProductionPlanSave(
      stagePreviewStages: stagePreviewStages,
      stageTemplateId: stageTemplateId,
      selectedTemplateStages: selectedTemplateStages,
      buildStageQueueFromCurrentDraft: buildStageQueueFromCurrentDraft,
    );

class _EditOrderScreenState extends State<_OrderEditor> {
  // A failed later save step must not create a second order on retry.
  OrderModel? _createdDuringSave;
  OrderEditLease? _createdLease;

  static const String _paintInfoParamLabel = 'Информация для красок:';

  String _trimTrailingFractionZeros(String value) {
    if (!value.contains('.')) return value;
    return value
        .replaceFirst(RegExp(r'0+$'), '')
        .replaceFirst(RegExp(r'\.$'), '');
  }

  String _extractFormExtraInfoFromSeries(String? seriesValue) {
    final series = (seriesValue ?? '').trim();
    if (series.isEmpty) return '';
    final match = RegExp(r'\(([^()]*)\)\s*$').firstMatch(series);
    return (match?.group(1) ?? '').trim();
  }

  Future<void> _pickFormImage() async {
    final picker = ImagePicker();
    final img = await picker.pickImage(source: ImageSource.gallery);
    if (img == null) return;
    _formImageBytes = await img.readAsBytes();
    if (mounted) setState(() {});
  }

  // ======= Формы (поиск/выбор со склада) =======
  // Переключатель новая/старая форма
  // В UI далее используем _useOldForm для показа блоков
  final TextEditingController _formSearchCtl = TextEditingController();
  final FocusNode _formSearchFocusNode = FocusNode();
  Timer? _formSearchDebounce;
  String _formSeries = 'F';
  List<Map<String, dynamic>> _formResults = [];
  Map<String, dynamic>? _selectedOldFormRow;
  String? _selectedOldFormImageUrl;
  bool _loadingForms = false;

  bool _useOldForm = false;
  final TextEditingController _formSizeCtl = TextEditingController();
  final TextEditingController _formTypeCtl = TextEditingController();
  final TextEditingController _formColorsCtl = TextEditingController();
  final TextEditingController _formNumberCtl = TextEditingController();
  final ScrollController _formScrollController = ScrollController();
  final TextEditingController _paperSearchController = TextEditingController();
  final TextEditingController _paintSearchController = TextEditingController();
  final TextEditingController _categorySearchController =
      TextEditingController();
  final ScrollController _paperListController = ScrollController();
  final ScrollController _paintListController = ScrollController();
  final ScrollController _categoryListController = ScrollController();
  String _paperSearch = '';
  String _paintSearch = '';
  String _categorySearch = '';
  Uint8List? _formImageBytes;

  Future<void> _loadOrderFormDisplay() async {
    try {
      final row = await _sb
          .from('orders')
          .select('has_form, is_old_form, form_id, new_form_no, form_series, form_code')
          .eq('id', widget.order!.id)
          .maybeSingle();
      if (!mounted) return;
      final bool? isOld = (row?['is_old_form'] as bool?);
      final int? no = ((row?['new_form_no'] as num?)?.toInt());
      final String series = (row?['form_series'] ?? '').toString();
      final String code = (row?['form_code'] ?? '').toString();
      final bool hasForm = (row?['has_form'] as bool?) ??
          (isOld != null || no != null || code.isNotEmpty);
      String display = '-';
      if (code.isNotEmpty) {
        display = code;
      } else if (series.isNotEmpty && no != null) {
        display = series + no.toString().padLeft(4, '0');
      } else if (no != null) {
        display = no.toString();
      }
      setState(() {
        _orderFormId = row?['form_id']?.toString();
        _orderFormIsOld = isOld;
        _orderFormNo = no;
        _orderFormSeries = series.isNotEmpty ? series : null;
        _orderFormCode = code.isNotEmpty ? code : null;
        _orderFormDisplay = display;
        if (!_formStateInitialized) {
          _hasForm = hasForm;
          if (isOld != null) {
            _isOldForm = isOld;
          }
          _editingForm = hasForm ? !(no != null || code.isNotEmpty) : false;
          _formStateInitialized = true;
        }
      });
      final extractedFormExtra = _extractFormExtraInfoFromSeries(series);
      if (_formExtraInfoController.text.trim() != extractedFormExtra) {
        _formExtraInfoController.value = TextEditingValue(
          text: extractedFormExtra,
          selection:
              TextSelection.collapsed(offset: extractedFormExtra.length),
        );
      }

      // Загрузка дополнительных деталей формы (размер, цвета, изображение)
      try {
        final formId = await findFormIdByOrderFormRef(
          formId: _orderFormId,
          formCode: code,
          formSeries: series,
          formNo: no,
        );
        if (formId != null) {
          final form = await _sb
              .from('forms')
              .select(
                  'title, description, image_url, size, product_type, colors')
              .eq('id', formId)
              .maybeSingle();
          if (mounted) {
            setState(() {
              final sizeValue =
                  (form?['size'] ?? form?['title'] ?? '').toString();
              final colorsValue =
                  (form?['colors'] ?? form?['description'] ?? '').toString();
              _orderFormSize = sizeValue;
              _orderFormProductType = (form?['product_type'] ?? '').toString();
              _orderFormColors = colorsValue;
              final url = form?['image_url'];
              if (url is String && url.isNotEmpty) {
                _orderFormImageUrl = url;
              } else {
                _orderFormImageUrl = null;
              }
            });
          }
        }
      } catch (_) {}

      // PDF привязанной формы. Без этой загрузки список «PDF» показывал
      // только файлы самого заказа, и документы старой формы в редакторе
      // не появлялись вовсе — их было видно лишь в карточке заказа.
      if (hasForm && (isOld ?? false)) {
        await _ensureAssignedFormPdfsLoaded();
      }
    } catch (_) {}
  }

  /// Резолвит id привязанной к заказу формы и подтягивает её PDF.
  Future<void> _ensureAssignedFormPdfsLoaded() async {
    try {
      final formId = await findFormIdByOrderFormRef(
        formId: _orderFormId,
        formCode: _orderFormCode,
        formSeries: _orderFormSeries,
        formNo: _orderFormNo,
      );
      if (!mounted || formId == null || formId.isEmpty) return;
      if (_oldFormPdfsFormId == formId && _oldFormSavedPdfs.isNotEmpty) return;
      await _loadOldFormPdfsFor(formId);
    } catch (_) {
      // Отсутствие PDF формы не должно ломать открытие заказа.
    }
  }

  Future<void> _reloadForms({String? search}) async {
    final query = (search ?? _formSearchCtl.text).trim();
    if (query.isEmpty) {
      if (!mounted) return;
      setState(() {
        _formResults = [];
        _loadingForms = false;
      });
      return;
    }

    if (mounted) {
      setState(() {
        _loadingForms = true;
      });
    }

    try {
      if (!mounted) return;
      final wp = context.read<WarehouseProvider>();
      final results = await wp.searchForms(
        query: query,
        limit: 50,
      );
      if (!mounted) return;
      setState(() {
        _formResults = results
            .where((row) {
              final dynamic enabledRaw = row['is_enabled'];
              final bool enabled = enabledRaw is bool
                  ? enabledRaw
                  : ((row['status'] ?? '') != 'disabled');
              return enabled;
            })
            .map((row) => Map<String, dynamic>.from(row))
            .toList();
        _loadingForms = false;
      });
    } catch (_) {
      if (mounted) {
        setState(() {
          _loadingForms = false;
          _formResults = [];
        });
      }
    }
  }

  void _onFormSearchChanged(String value) {
    final trimmed = value.trim();
    setState(() {
      if (trimmed.isEmpty) {
        _selectedOldFormRow = null;
        _selectedOldForm = null;
        _formResults = [];
        _loadingForms = false;
        _selectedOldFormImageUrl = null;
        _oldFormPdfsFormId = null;
        _oldFormSavedPdfs = [];
      } else {
        final selectedValue = _selectedOldFormRow != null
            ? _oldFormInputValue(_selectedOldFormRow!)
            : null;
        if (_selectedOldFormRow != null && selectedValue != trimmed) {
          _selectedOldFormRow = null;
          _selectedOldFormImageUrl = null;
          _oldFormPdfsFormId = null;
          _oldFormSavedPdfs = [];
        }
        if (_selectedOldFormRow == null) {
          _selectedOldForm = trimmed;
        }
      }
    });

    _formSearchDebounce?.cancel();
    if (trimmed.isEmpty) return;
    _formSearchDebounce = Timer(
        const Duration(milliseconds: 250), () => _reloadForms(search: value));
  }

  void _onStockExtraSearchChanged(String value) {
    final trimmed = value.trim();
    _stockExtraSearchDebounce?.cancel();
    setState(() {
      _selectedStockExtraRow = null;
      _stockExtraResults = [];
      _stockExtra = null;
      _stockExtraItem = null;
      _stockExtraSelectedQty = null;
      _stockExtraQtyTouched = false;
      _product.leftover = null;
      if (_writeOffStockExtra) {
        _writeOffStockExtra = false;
      }
      _stockExtraAutoloaded = true;
    });
    _updateStockExtraQtyController();
    if (trimmed.isEmpty) {
      _updateStockExtra(query: '');
    } else {
      _stockExtraSearchDebounce = Timer(const Duration(milliseconds: 250),
          () => _updateStockExtra(query: trimmed));
    }
  }

  void _selectStockExtraRow(Map<String, dynamic> row) {
    final description = (row['description'] ?? '').toString();
    final qv = row['quantity'];
    final qty =
        (qv is num) ? qv.toDouble() : double.tryParse('${qv ?? ''}') ?? 0.0;
    double? defaultQty;
    if (_product.leftover != null && _product.leftover! > 0) {
      defaultQty = math.max(0, math.min(_product.leftover!, qty));
    } else if (qty > 0) {
      defaultQty = qty;
    }
    _stockExtraSearchDebounce?.cancel();
    setState(() {
      _selectedStockExtraRow = Map<String, dynamic>.from(row);
      _stockExtra = qty;
      _stockExtraResults = _stockExtraResults;
      _loadingStockExtra = false;
      _stockExtraSelectedQty = defaultQty;
      _stockExtraQtyTouched = false;
      _product.leftover =
          defaultQty != null && defaultQty > 0 ? defaultQty : null;
      if (_writeOffStockExtra && (_stockExtraSelectedQty ?? 0) <= 0) {
        _writeOffStockExtra = false;
      }
    });
    _updateStockExtraQtyController();
    _stockExtraSearchController.value = TextEditingValue(
      text: description,
      selection: TextSelection.collapsed(offset: description.length),
    );
    _stockExtraFocusNode.unfocus();
  }

  Widget _buildStockExtraResults() {
    if (_stockExtraResults.isEmpty) {
      if (_loadingStockExtra ||
          _stockExtraSearchController.text.trim().isEmpty) {
        return const SizedBox.shrink();
      }
      return Align(
        alignment: Alignment.centerLeft,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Text(
            'Ничего не найдено',
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ),
      );
    }

    return ConstrainedBox(
      constraints: const BoxConstraints(maxHeight: 200),
      child: Material(
        elevation: 2,
        borderRadius: BorderRadius.circular(12),
        clipBehavior: Clip.antiAlias,
        child: ListView.separated(
          shrinkWrap: true,
          itemCount: _stockExtraResults.length,
          separatorBuilder: (_, __) => const Divider(height: 1),
          itemBuilder: (context, index) {
            final row = _stockExtraResults[index];
            final description = (row['description'] ?? '').toString().trim();
            final sizeLabel = (row['size'] ?? '').toString().trim();
            final qv = row['quantity'];
            final qty = (qv is num)
                ? qv.toDouble()
                : double.tryParse('${qv ?? ''}') ?? 0.0;
            final selected = _selectedStockExtraRow != null &&
                (_selectedStockExtraRow!['id']?.toString() ==
                    row['id']?.toString());
            final subtitleParts = <String>[];
            subtitleParts.add('Количество: ${qty.toStringAsFixed(2)}');
            if (sizeLabel.isNotEmpty) {
              subtitleParts.add('Размер: $sizeLabel');
            }
            return ListTile(
              title: Text(description.isEmpty ? 'Без названия' : description),
              subtitle: Text(subtitleParts.join('\n')),
              selected: selected,
              trailing: selected ? const Icon(Icons.check) : null,
              onTap: () => _selectStockExtraRow(row),
            );
          },
        ),
      ),
    );
  }

  void _updateManagerDisplayController() {
    final selectedName = (_selectedManager?.trim().isNotEmpty ?? false)
        ? _selectedManager!.trim()
        : (widget.order?.manager ?? '');
    if (_managerDisplayController.text == selectedName) {
      return;
    }
    _managerDisplayController.value = TextEditingValue(
      text: selectedName,
      selection: TextSelection.collapsed(offset: selectedName.length),
    );
  }

  String _formatDimensionsInput() {
    final parts = <String>[];
    void add(double? value) {
      if (value != null && value > 0) {
        parts.add(_formatDecimal(value));
      }
    }

    add(_product.width);
    add(_product.height);
    add(_product.depth);
    return parts.join(' ');
  }

  void _applyDimensionsInput(String input) {
    final matches =
        RegExp(r'[0-9]+(?:[\\.,][0-9]+)?').allMatches(input.trim());
    final values = matches
        .map((m) => double.tryParse(m.group(0)!.replaceAll(',', '.')))
        .whereType<double>()
        .toList();
    setState(() {
      // Размеры сохраняются в порядке: 1) длина, 2) ширина, 3) глубина.
      _product.width = values.isNotEmpty ? values[0] : 0;
      _product.height = values.length > 1 ? values[1] : 0;
      _product.depth = values.length > 2 ? values[2] : 0;
    });
    _scheduleStagePreviewUpdate();
  }

  final _formKey = GlobalKey<FormState>();
  final _uuid = const Uuid();
  final SupabaseClient _sb = Supabase.instance.client;
  late final OrderQueueService _orderQueueService = OrderQueueService(_sb);

  // Персонал: выбранный менеджер из списка сотрудников с ролью «Менеджер»
  String? _selectedManager;
  final TextEditingController _managerDisplayController =
      TextEditingController();
  // Список доступных менеджеров (ФИО), загружается из PersonnelProvider
  List<String> _managerNames = [];
  // Клиент и комментарии
  late TextEditingController _customerController;
  late TextEditingController _formExtraInfoController;
  late TextEditingController _commentsController;
  late TextEditingController _packagingController;
  late final TextEditingController _lengthController;
  late final TextEditingController _widthController;
  late final TextEditingController _depthController;
  DateTime? _orderDate;
  DateTime? _dueDate;
  late ProductModel _product;
  List<String> _selectedParams = [];
  // Ручки (из склада)
  String? _selectedHandleId;
  String _selectedHandleDescription = '-';
  // Картон: либо «нет», либо «есть»
  String _selectedCardboard = 'нет';
  bool _cardboardChecked = false;
  bool _trimming = false;
  double _makeready = 0;
  double _val = 0;
  String? _stageTemplateId;
  final TextEditingController _stageTemplateController =
      TextEditingController();
  final FocusNode _stageTemplateFocusNode = FocusNode();
  String _stageTemplateSearchText = '';
  String? _selectedStageTemplateName;
  List<Map<String, dynamic>> _stagePreviewStages = <Map<String, dynamic>>[];
  bool _stageOrderManuallyChanged = false;
  bool _stagePreviewLoading = false;
  String? _stagePreviewError;
  bool _stagePreviewScheduled = false;
  bool _stagePreviewInitialized = false;
  bool _isStageQueueBuilt = false;
  String _queueBuildStatus = QueueBuildStatus.notBuilt;
  String? _selectedVStage;
  String? _selectedPStage;
  Map<String, dynamic>? _queueSignature;
  bool _updatingStageTemplateText = false;
  bool _lastPreviewPaintsFilled = false;
  MaterialModel? _selectedMaterial;
  TmcModel? _selectedMaterialTmc;
  // Дополнительные типы бумаги в заказе (без искусственного лимита).
  final List<MaterialModel> _extraPaperMaterials = <MaterialModel>[];
  int _activePaperSlotIndex = 0;
  // === Каскадный выбор Материал → Формат → Грамаж (строгий) ===
  final TextEditingController _matNameCtl = TextEditingController();
  final TextEditingController _matFormatCtl = TextEditingController();
  final TextEditingController _matGramCtl = TextEditingController();
  String? _matSelectedName;
  String? _matSelectedFormat;
  String? _matSelectedGrammage;
  String? _matNameError;
  String? _matFormatError;
  String? _matGramError;

  // Готовая продукция (лишнее)
  TmcModel? _stockExtraItem;
  double? _stockExtra;
  double? _stockExtraSelectedQty;
  final TextEditingController _stockExtraSearchController =
      TextEditingController();
  final FocusNode _stockExtraFocusNode = FocusNode();
  Timer? _stockExtraSearchDebounce;
  bool _loadingStockExtra = false;
  List<Map<String, dynamic>> _stockExtraResults = [];
  Map<String, dynamic>? _selectedStockExtraRow;
  bool _writeOffStockExtra =
      false; // <-- добавлено: списывать ли лишнее при сохранении
  bool _stockExtraQtyTouched = false;
  final TextEditingController _stockExtraQtyController =
      TextEditingController();

  List<PlatformFile> _pickedOrderPdfs = [];
  List<Map<String, dynamic>> _savedOrderPdfs = [];
  bool _loadingOrderPdfs = false;
  // Черновик возобновления: objectPath файлов, исключённых пользователем из
  // переноса. Реальные объекты Storage/order_files архивного заказа при этом
  // не трогаются — удаление до сохранения только локальное.
  final Set<String> _draftRemovedOrderPdfPaths = <String>{};
  // Краски (мультисекция)
  final List<_PaintEntry> _paints = <_PaintEntry>[];
  String _paintInfo = '';
  final TextEditingController _paintInfoController = TextEditingController();
  bool _paintsRestored = false;
  bool _fetchedOrderForm = false;
  // Форма: отдельная галочка наличия + выбор старая/новая.
  bool _hasForm = false;
  bool _isOldForm = false;
  bool _userManuallySelectedFormType = false;
  bool _editingForm = false;
  bool _formStateInitialized = false;
  // Список существующих форм (номера) из склада
  // Считанные из БД параметры формы для существующего заказа (только просмотр)
  bool? _orderFormIsOld;
  int? _orderFormNo;
  String? _orderFormSeries;
  String? _orderFormCode;
  String? _orderFormId;
  String? _editingFormInitialText;
  String? _orderFormDisplay;
  // Детали формы для существующего заказа
  String? _orderFormSize;
  String? _orderFormProductType;
  String? _orderFormColors;
  String? _orderFormImageUrl;

  List<String> _availableForms = [];
  // Номер новой формы по умолчанию (max+1)
  int _defaultFormNumber = 1;
  // PDF новой формы (при создании) — стейджится, заливается после сохранения заказа.
  List<PlatformFile> _newFormPdfs = [];
  // PDF уже существующей (старой) формы — грузятся/удаляются немедленно.
  String? _oldFormPdfsFormId;
  List<Map<String, dynamic>> _oldFormSavedPdfs = [];
  bool _loadingOldFormPdfs = false;
  // Выбранный номер старой формы
  String? _selectedOldForm;
  // Фактическое количество (пока не вычисляется)
  String _actualQuantity = '';
  // ===== Категории склада для поля "Наименование изделия" =====
  List<String> _categoryTitles = [];
  bool _catsLoading = false;
  bool _stockExtraAutoloaded = false;
  bool _launchedNoStartedStages = false;
  bool _launchedWithStartedStages = false;
  // Расход бумаги по факту: после первого списания бумага в форме заперта.
  PaperUsageState? _paperUsage;
  bool _isSavingOrder = false;

  Future<void> _loadCategoriesForProduct() async {
    setState(() => _catsLoading = true);
    try {
      // Справочник типов продукта и настройки блоков формы приезжают одним
      // прогревом и живут в кэше на сессию, поэтому отдельного запроса при
      // открытии заказа нет. Метод вызывается дважды из initState — второй
      // вызов попадает в кэш и запроса не делает.
      await ProductTypeSettings.instance.ensureLoaded();
      final names = ProductTypeSettings.instance.productTypeTitles.toList()
        ..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
      if (!mounted) return;
      setState(() {
        _categoryTitles = names;
        // Настройки приходят позже первого кадра, а картон мог быть скрыт не
        // только прежним зашитым правилом, но и настройкой техлида. Поэтому
        // зависимое поле пересчитывается здесь ещё раз.
        if (!_isBlockVisible(kOrderFormBlockCardboard)) {
          _cardboardChecked = false;
          _selectedCardboard = 'нет';
        }
      });
    } catch (e) {
      debugPrint('load categories error: $e');
    } finally {
      if (mounted) setState(() => _catsLoading = false);
    }
  }

  /// Uuid выбранного типа продукта или null, если тип не выбран либо не найден
  /// в справочнике.
  ///
  /// null означает «значение неизвестно», и тогда ключ `product_type_id` в
  /// payload не попадает вовсе — см. комментарий в [OrderModel.toMap]. Слать
  /// null нельзя: сохранение заказа стирало бы уже проставленный тип.
  String? _currentProductTypeId() =>
      ProductTypeSettings.instance.resolveProductTypeId(_product.type);

  // ===== Дополнительные опции заказа =====

  final OrderExtraOptionsRepository _extraOptionsRepo =
      OrderExtraOptionsRepository();

  List<OrderExtraOptionRow> _extraOptionRows = const <OrderExtraOptionRow>[];

  /// Справочник опций уже прочитан хотя бы раз.
  ///
  /// До этого момента сохранение НЕ отправляет `extra_options`: пустые строки
  /// на недогруженном справочнике означали бы «опций не выбрано», и быстрый
  /// сейв стёр бы выбранное в заказе. Отсутствие ключа оставляет колонку
  /// нетронутой — см. [OrderModel.extraOptions].
  bool _extraOptionsReady = false;

  /// Читает справочник опций для текущего типа продукта и кладёт поверх него
  /// снимок заказа.
  ///
  /// Кэша нет намеренно: техлид правит опции без публикации, и закэшированный
  /// на сессию список означал бы «добавил вариант, а менеджер его не видит до
  /// перезапуска» — ровно то, чего просили избежать.
  Future<void> _loadExtraOptions({
    required List<OrderOptionSelection> saved,
  }) async {
    List<OrderOptionDef> defs = const <OrderOptionDef>[];
    try {
      await ProductTypeSettings.instance.ensureLoaded();
      final typeId = _currentProductTypeId();
      if (typeId != null) {
        defs = await _extraOptionsRepo.loadForProductType(typeId);
      }
    } catch (e) {
      // Справочник недоступен — строки всё равно строим: сохранённые значения
      // придут из снимка как снятые с учёта и не потеряются при сохранении.
      debugPrint('❌ extra options load failed: $e');
    }
    if (!mounted) return;
    setState(() {
      _extraOptionRows = buildOrderExtraOptionRows(defs: defs, saved: saved);
      _extraOptionsReady = true;
    });
  }

  /// Снимок для записи; `null` — справочник ещё не читался.
  List<OrderOptionSelection>? _extraOptionsForPersist() =>
      _extraOptionsReady ? selectionsFromRows(_extraOptionRows) : null;

  /// Активен ли блок формы для текущего типа продукта.
  ///
  /// Пока настройки не загружены, для картона держим прежнее зашитое правило —
  /// иначе на первом кадре чекбокс мигал бы у Листов и В-образных. Остальные
  /// блоки в этом окне видны, как и до появления настроек.
  bool _isBlockVisible(String blockCode) {
    final settings = ProductTypeSettings.instance;
    if (!settings.isLoaded) {
      return blockCode == kOrderFormBlockCardboard
          ? supportsCardboardForProductType(_product.type)
          : true;
    }
    return settings.isBlockVisible(_product.type, blockCode);
  }

  bool _dataLoaded = false;

  @override
  void initState() {
// Доп. попытка загрузить номер формы после первой отрисовки
    bool _defensiveFormLoadScheduled = false;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_defensiveFormLoadScheduled && widget.order != null) {
        _defensiveFormLoadScheduled = true;
        _loadOrderFormDisplay();
      }
    });
    if (widget.order != null ||
        (widget.initialOrder?.restartedFromOrderId?.trim().isNotEmpty ??
            false)) {
      _loadSavedOrderPdfs();
    }
    // Свой резерв красок — чтобы при редактировании он не выглядел занятым.
    _loadOwnPaintReservations();

    _stageTemplateController.text = '';
    _stageTemplateController.addListener(_onStageTemplateTextChanged);
    _lastPreviewPaintsFilled = _hasAnyPaints();

    super.initState();

    // order передан при редактировании, initialOrder - при создании на основе шаблона
    final template = widget.order ?? widget.initialOrder;
    // Текущий менеджер будет выбран позже в didChangeDependencies, когда загрузится список менеджеров.
    // Здесь просто запомним имя менеджера из шаблона для последующего выбора.
    final initialManager =
        template is OrderModel ? (template as OrderModel).manager : '';
    _selectedManager = initialManager.isNotEmpty ? initialManager : null;
    if (widget.order == null) {
      final currentUser = AuthHelper.currentUserName?.trim();
      if (currentUser != null && currentUser.isNotEmpty) {
        _selectedManager = currentUser;
      }
    }
    _updateManagerDisplayController();
    _customerController = TextEditingController(text: template?.customer ?? '');
    _formExtraInfoController = TextEditingController();
    _commentsController = TextEditingController(text: template?.comments ?? '');
    _orderDate = template?.orderDate;
    _dueDate = template?.dueDate;
    // Поля "договор/оплата" временно исключены из сценария создания/редактирования.
    _selectedParams = List<String>.from(template?.additionalParams ?? const []);
    _packagingController = TextEditingController(
      text: _extractPackagingFromParams(_selectedParams),
    );
    _trimming = _selectedParams.contains('Подрезка');
    final initialHandle = template?.handle?.trim();
    if (initialHandle != null &&
        initialHandle.isNotEmpty &&
        initialHandle != '-') {
      _selectedHandleDescription = initialHandle;
    } else {
      _selectedHandleDescription = '-';
    }

    // Заменяем старое значение «офсет» на «есть», если встречается в переданном заказе
    final rawCardboard = template?.cardboard ?? 'нет';
    _selectedCardboard = rawCardboard == 'офсет' ? 'есть' : rawCardboard;
    _cardboardChecked = _selectedCardboard == 'есть';
    _makeready = template?.makeready ?? 0;
    _val = template?.val ?? 0;
    _stageTemplateId = template?.stageTemplateId;
    _queueBuildStatus =
        widget.order?.queueBuildStatus ?? QueueBuildStatus.notBuilt;
    _selectedVStage = widget.order?.selectedVStage;
    _selectedPStage = widget.order?.selectedPStage;
    _queueSignature = widget.order?.queueSignature == null
        ? null
        : Map<String, dynamic>.from(widget.order!.queueSignature!);
    final List<MaterialModel> initialPapers = template != null
        ? (template.paperMaterials.isNotEmpty
            ? List<MaterialModel>.from(template.paperMaterials)
            : <MaterialModel>[
                if (template.material != null) template.material!,
              ])
        : const <MaterialModel>[];
    _selectedMaterial = initialPapers.isNotEmpty ? initialPapers.first : null;
    _extraPaperMaterials
      ..clear()
      ..addAll(initialPapers.skip(1));
    if (template != null) {
      final p = template.product;
      _product = ProductModel(
        id: p.id,
        type: p.type,
        quantity: p.quantity,
        width: p.width,
        height: p.height,
        depth: p.depth,
        parameters: p.parameters,
        roll: p.roll,
        widthB: p.widthB,
        blQuantity: p.blQuantity,
        length: p.length,
        leftover: p.leftover,
      );
    } else {
      _product = ProductModel(
        id: _uuid.v4(),
        type: 'П-пакет',
        quantity: 0,
        width: 0,
        height: 0,
        depth: 0,
        parameters: '',
        roll: null,
        widthB: null,
        blQuantity: null,
        length: null,
        leftover: null,
      );
    }
    _hasForm = template?.hasForm ?? false;
    // Создание на основе шаблона (возобновление из архива): переносим
    // реквизиты привязанной формы. Штатные async-загрузчики form-полей
    // работают только при widget.order != null, и без этого сида
    // привязка формы терялась при возобновлении.
    if (widget.order == null && widget.initialOrder != null) {
      final t = widget.initialOrder!;
      final hasFormRef = t.hasForm &&
          (t.newFormNo != null || (t.formCode?.trim().isNotEmpty ?? false));
      if (hasFormRef) {
        _orderFormIsOld = t.isOldForm;
        _orderFormNo = t.newFormNo;
        _orderFormSeries = t.formSeries;
        _orderFormCode = t.formCode;
        _orderFormId = t.formId;
        _orderFormDisplay = _buildFormDisplayValue(
          code: t.formCode,
          series: t.formSeries,
          number: t.newFormNo,
        );
        _isOldForm = t.isOldForm;
        // «Доп. информация формы» не имеет своей колонки — она закодирована
        // суффиксом «(…)» внутри form_series; штатное извлечение в
        // _loadOrderFormDisplay работает только при widget.order != null.
        final extraInfo = _extractFormExtraInfoFromSeries(t.formSeries);
        if (extraInfo.isNotEmpty) {
          _formExtraInfoController.text = extraInfo;
        }
        // PDF переносимой формы. Microtask — загрузчики зовут setState,
        // что недопустимо синхронно в initState. _editingForm не трогаем:
        // программная инициализация не должна отключать реюз-ветку.
        Future.microtask(() {
          if (!mounted) return;
          if (t.isOldForm) {
            findFormIdByOrderFormRef(
              formId: t.formId,
              formCode: t.formCode,
              formSeries: t.formSeries,
              formNo: t.newFormNo,
            ).then((formId) {
              if (mounted && formId != null && _isOldForm) {
                _loadOldFormPdfsFor(formId);
              }
            }).catchError((_) {});
          }
        });
      }
    }
    final initialFormResult = applyOrderFormRules(
      draft: _buildCurrentOrderDraft(),
      hasPaints: _hasAnyPaints(),
      userManuallySelectedFormType: _userManuallySelectedFormType,
    );
    _hasForm = initialFormResult.hasForm;
    _isOldForm = initialFormResult.isOldForm;

    // Инициализация каскадных полей (если есть материал в шаблоне)
    _matNameCtl.text = (_selectedMaterial?.name ?? '').trim();
    _matFormatCtl.text = (_selectedMaterial?.format ?? '').trim();
    _matGramCtl.text = (_selectedMaterial?.grammage ?? '').trim();
    _matSelectedName = _matNameCtl.text.isEmpty ? null : _matNameCtl.text;
    _matSelectedFormat = _matFormatCtl.text.isEmpty ? null : _matFormatCtl.text;
    _matSelectedGrammage = _matGramCtl.text.isEmpty ? null : _matGramCtl.text;

    final actualQty = template?.actualQty;
    if (actualQty != null) {
      _actualQuantity = _formatActualQuantity(actualQty);
    } else {
      _actualQuantity = '';
    }
    _loadCategoriesForProduct(); // загрузка категорий склада
    _lengthController = TextEditingController(
      text: _product.width > 0 ? _formatDecimal(_product.width) : '',
    );
    _widthController = TextEditingController(
      text: _product.height > 0 ? _formatDecimal(_product.height) : '',
    );
    _depthController = TextEditingController(
      text: _product.depth > 0 ? _formatDecimal(_product.depth) : '',
    );
    if (!_isBlockVisible(kOrderFormBlockCardboard)) {
      _cardboardChecked = false;
      _selectedCardboard = 'нет';
    }
    _stockExtraSelectedQty =
        (_product.leftover != null && _product.leftover! > 0)
            ? _product.leftover
            : null;
    _stockExtraQtyTouched = _stockExtraSelectedQty != null;
    _updateStockExtraQtyController();
    // ensure at least one paint row only for new orders (not editing)
    if (_paints.isEmpty && widget.order == null)
      _paints.add(_PaintEntry(memo: _paintInfo));
    _loadCategoriesForProduct();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final warehouse = context.read<WarehouseProvider>();
      warehouse.fetchTmc();
    });

    if (widget.order != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _loadRuntimeEditLocks();
        _scheduleStagePreviewUpdate(immediate: true);
      });
    }

    // Снимок берём из шаблона: при возобновлении из архива опции переезжают
    // в новое поколение вместе с остальными реквизитами заказа.
    _loadExtraOptions(
      saved: List<OrderOptionSelection>.from(
        template?.extraOptions ?? const <OrderOptionSelection>[],
      ),
    );
  }

  String _formatActualQuantity(double value) {
    if (value.isNaN || value.isInfinite) return '';
    if ((value - value.round()).abs() < 1e-6) {
      return value.round().toString();
    }
    return _trimTrailingFractionZeros(value.toStringAsFixed(3));
  }

  bool _looksLikeFlexo(String text) {
    final lower = text.toLowerCase();
    return lower.contains('флекс') || lower.contains('flexo');
  }

  bool _hasTaskActivity(Map<String, dynamic> row) {
    final status = (row['status'] ?? '').toString().toLowerCase();
    if (status.isNotEmpty && status != 'waiting') return true;
    final dynamic comments = row['comments'];
    if (comments is List) {
      for (final item in comments) {
        if (item is! Map) continue;
        final type = (item['type'] ?? '').toString().toLowerCase();
        if (type == 'start' ||
            type == 'resume' ||
            type == 'setup_start' ||
            type == 'setup_done' ||
            type == 'user_done') {
          return true;
        }
      }
    }
    return false;
  }

  Future<void> _loadPaperUsageLock(String orderId) async {
    try {
      final usage = await OrdersRepository().getPaperUsageState(orderId);
      if (!mounted) return;
      setState(() => _paperUsage = usage);
    } catch (e) {
      debugPrint('⚠️ не удалось проверить расход бумаги заказа: $e');
    }
  }

  Future<void> _loadRuntimeEditLocks() async {
    final order = widget.order;
    if (order == null || !order.assignmentCreated) return;
    unawaited(_loadPaperUsageLock(order.id));
    try {
      final taskRows = await _sb
          .from('tasks')
          .select('stage_id, status, comments')
          .eq('order_id', order.id);
      if (taskRows is! List || !mounted) return;
      final List<Map<String, dynamic>> tasks = taskRows
          .whereType<Map>()
          .map((row) => Map<String, dynamic>.from(row))
          .toList(growable: false);
      if (tasks.isEmpty) {
        setState(() {
          _launchedWithStartedStages = false;
          _launchedNoStartedStages = true;
        });
        return;
      }
      final anyStageStarted = tasks.any(_hasTaskActivity);

      String? firstStageId;
      try {
        final plan = await _sb
            .from('prod_plans')
            .select('id')
            .eq('order_id', order.id)
            .maybeSingle();
        final String? planId = plan?['id']?.toString();
        if (planId != null && planId.isNotEmpty) {
          // Порядок этапов несёт step_no; seq — лишь уникальный ключ, и при
          // схеме step*1000+offset сортировка по нему ставит поздние шаги
          // раньше ранних. seq вторым ключом держит стабильный порядок
          // внутри шага с несколькими рабочими местами.
          final firstStage = await _sb
              .from('prod_plan_stages')
              .select('stage_id')
              .eq('plan_id', planId)
              .order('step_no', ascending: true)
              .order('seq', ascending: true)
              .limit(1)
              .maybeSingle();
          firstStageId = firstStage?['stage_id']?.toString();
        }
      } catch (_) {}

      bool firstStarted = false;
      if (firstStageId != null && firstStageId.isNotEmpty) {
        firstStarted = tasks
            .where((row) => (row['stage_id'] ?? '').toString() == firstStageId)
            .any(_hasTaskActivity);
      } else {
        firstStarted = anyStageStarted;
      }

      final stageIds = tasks
          .map((row) => (row['stage_id'] ?? '').toString().trim())
          .where((id) => id.isNotEmpty)
          .toSet()
          .toList(growable: false);
      final flexoStageIds = <String>{};
      if (stageIds.isNotEmpty) {
        try {
          final wpRows = await _sb
              .from('workplaces')
              // У workplaces нет title/short_name/stage_name: с ними запрос
              // всегда падал, и флексопечать здесь не распознавалась.
              .select('id,name')
              .inFilter('id', stageIds);
          if (wpRows is List) {
            for (final raw in wpRows.whereType<Map>()) {
              final map = Map<String, dynamic>.from(raw);
              final id = (map['id'] ?? '').toString().trim();
              if (id.isEmpty) continue;
              final probes = [map['name'], id];
              final isFlexo =
                  probes.any((value) => _looksLikeFlexo((value ?? '').toString()));
              if (isFlexo) {
                flexoStageIds.add(id);
              }
            }
          }
        } catch (_) {}
      }
      final flexoStarted = tasks.where((row) {
        final stageId = (row['stage_id'] ?? '').toString();
        return flexoStageIds.contains(stageId);
      }).any(_hasTaskActivity);

      final hasStartedProtectedStages =
          anyStageStarted || firstStarted || flexoStarted;
      if (!mounted) return;
      setState(() {
        _launchedWithStartedStages = hasStartedProtectedStages;
        _launchedNoStartedStages = !hasStartedProtectedStages;
      });
    } catch (_) {}
  }

  TemplateModel? _findTemplateById(
      List<TemplateModel> templates, String? templateId) {
    if (templateId == null || templateId.isEmpty) return null;
    for (final tpl in templates) {
      if (tpl.id == templateId) return tpl;
    }
    return null;
  }

  String _resolveStageName(Map<String, dynamic> stage) {
    final baseName = (() {
      final dynamic raw = stage['stageName'] ??
          stage['stage_name'] ??
          stage['workplaceName'] ??
          stage['workplace_name'] ??
          stage['title'] ??
          stage['name'];
      if (raw is String && raw.trim().isNotEmpty) {
        return raw.trim();
      }
      return '';
    })();

    final altNames = <String>[];
    final rawAlt = stage['alternativeStageNames'];
    if (rawAlt is List) {
      altNames.addAll(
        rawAlt
            .whereType<String>()
            .map((e) => e.trim())
            .where((e) => e.isNotEmpty),
      );
    }

    final ordered = <String>[];
    final seen = <String>{};
    void addName(String value) {
      // Некоторые источники уже сохраняют объединённые названия в виде
      // "Этап A / Этап B". Разбиваем их на части, чтобы убрать дубли на уровне
      // каждого рабочего места, а не всей строки целиком.
      final parts = value
          .split('/')
          .map((part) => part.trim())
          .where((part) => part.isNotEmpty);
      for (final part in parts) {
        final key = part.toLowerCase();
        if (!seen.add(key)) continue;
        ordered.add(part);
      }
    }

    for (final alt in altNames) {
      addName(alt);
    }
    addName(baseName);

    if (ordered.isEmpty) return 'Без названия';
    return ordered.join(' / ');
  }

  void _setStageTemplateText(String value) {
    _updatingStageTemplateText = true;
    _stageTemplateController.value = TextEditingValue(
      text: value,
      selection: TextSelection.collapsed(offset: value.length),
    );
    _updatingStageTemplateText = false;
    _stageTemplateSearchText = value;
  }

  void _onStageTemplateSelected(TemplateModel template) {
    _setStageTemplateText(template.name);
    _stageTemplateFocusNode.unfocus();

    if (_stageTemplateId == template.id &&
        _selectedStageTemplateName == template.name) {
      _scheduleStagePreviewUpdate(immediate: true);
      return;
    }

    setState(() {
      _stageTemplateId = template.id;
      _selectedStageTemplateName = template.name;
      _markQueueOutdatedIfBuilt();
      _stagePreviewStages = <Map<String, dynamic>>[];
      _stagePreviewError = null;
      _stagePreviewLoading = true;
      _stagePreviewInitialized = false;
      _stagePreviewScheduled = false;
      _stageOrderManuallyChanged = false;
      _isStageQueueBuilt = false;
    });

    _scheduleStagePreviewUpdate(immediate: true);
  }


  /// Разбор переехал в `order_handle_type.dart`: тот же тип ручки спрашивает
  /// проверка обязательных блоков, а две копии сопоставления разошлись бы на
  /// первом же новом названии ручки.
  OrderHandleType _resolveSelectedHandleType() =>
      orderHandleTypeFromDescription(_selectedHandleDescription);

  MaterialModel? _mainMaterialForStageQueue() {
    if (_selectedMaterial != null) return _selectedMaterial;
    final selectedPapers = _collectSelectedPapers();
    return selectedPapers.isNotEmpty ? selectedPapers.first : null;
  }

  OrderStageQueueDraft _currentStageQueueDraft() {
    final mainMaterial = _mainMaterialForStageQueue();
    final orderWidth = (_product.widthB ?? _product.width).toDouble();
    final selectedPapers = _collectSelectedPapers();
    return OrderStageQueueDraft(
      productTypeId: _product.type.trim(),
      orderWidthB: orderWidth,
      materialWidth: parseMaterialWidth(mainMaterial),
      requiresBobbinCutting: requiresBobbinCuttingForOrder(
        papers: selectedPapers,
        defaultOrderWidthB: orderWidth,
        mainMaterialFormatFallback: _matSelectedFormat,
      ),
      hasPaint: _hasAnyPaints(),
      hasTrimming: _trimming,
      hasCardboard: _cardboardChecked,
      handleType: _resolveSelectedHandleType(),
    );
  }


  Map<String, dynamic> _currentQueueSignature() {
    final mainMaterial = _mainMaterialForStageQueue();
    return buildQueueSignature(
      product: _product,
      paperMaterials: _collectSelectedPapers(),
      materialWidth: parseMaterialWidth(mainMaterial),
      hasPaint: _hasAnyPaints(),
      hasTrimming: _trimming,
      hasCardboard: _cardboardChecked,
      handle: _selectedHandleDescription,
      templateId: _stageTemplateId,
    );
  }

  bool _sameQueueSignature(
    Map<String, dynamic>? left,
    Map<String, dynamic>? right,
  ) {
    if (left == null || right == null) return left == right;
    return jsonEncode(left) == jsonEncode(right);
  }

  void _syncSwitchableStageSelectionFields(
    List<Map<String, dynamic>> stages,
  ) {
    final selections = collectSwitchableStageSelectionsByStageKey(stages);
    _selectedVStage = selections[kVMainSwitchStageKey];
    _selectedPStage = selections[kPMainSwitchStageKey];
  }

  void _markQueueOutdatedIfBuilt() {
    if (_queueBuildStatus == QueueBuildStatus.built) {
      _queueBuildStatus = QueueBuildStatus.outdated;
    }
  }

  bool _isSwitchablePreviewStage(Map<String, dynamic> stage) {
    final value = stage['isSwitchable'];
    if (value == true) return true;
    if (value is String && value.toLowerCase().trim() == 'true') return true;
    return _switchableStageKeyFromPreviewStage(stage) != null;
  }

  String? _switchableStageKeyFromPreviewStage(Map<String, dynamic> stage) {
    final stageKey = (stage['stageKey'] ?? stage['stage_key'])?.toString();
    final groupKey = stage['switchableGroupKey']?.toString();
    if (stageKey == kVMainSwitchStageKey ||
        stageKey == kSwitchableVGroupKey ||
        stageKey == kFriStageId ||
        stageKey == kWindowStageId ||
        groupKey == kSwitchableVGroupKey) {
      return kVMainSwitchStageKey;
    }
    if (stageKey == kPMainSwitchStageKey ||
        stageKey == kSwitchablePGroupKey ||
        stageKey == kAutoBigStageId ||
        stageKey == kAutoSmallStageId ||
        stageKey == kTubeStageId ||
        groupKey == kSwitchablePGroupKey) {
      return kPMainSwitchStageKey;
    }

    final selectedId = _selectedSwitchableIdFromPreviewStage(stage);
    if (selectedId == kFriStageId || selectedId == kWindowStageId) {
      return kVMainSwitchStageKey;
    }
    if (selectedId == kAutoBigStageId ||
        selectedId == kAutoSmallStageId ||
        selectedId == kTubeStageId) {
      return kPMainSwitchStageKey;
    }

    // Этап, заведённый в редакторе типов продукта: ключ переключателя — его
    // собственный ключ. Без этой ветки карточка такого этапа вообще не
    // оборачивалась в нажимаемый слой, и клик по нему ничего не делал.
    if (isRouteSwitchableStageKey(
      ProductTypeSettings.instance.routeFor(_product.type),
      stageKey,
    )) {
      return stageKey;
    }
    return null;
  }

  String? _selectedSwitchableIdFromPreviewStage(Map<String, dynamic> stage) {
    final id = (stage['selectedWorkplaceId'] ??
            stage['stageId'] ??
            stage['stage_id'] ??
            stage['stageid'] ??
            stage['workplaceId'] ??
            stage['workplace_id'] ??
            stage['id'])
        ?.toString()
        .trim();
    if (id == null || id.isEmpty) return null;
    return id;
  }

  List<_SwitchableStageOption> _switchableOptionsForStageKey(
    String stageKey,
  ) {
    if (stageKey == kVMainSwitchStageKey) {
      return const [
        _SwitchableStageOption(kFriStageId, 'Фри'),
        _SwitchableStageOption(kWindowStageId, 'Окно'),
      ];
    }
    if (stageKey == kPMainSwitchStageKey) {
      return const [
        _SwitchableStageOption(kAutoBigStageId, 'Автомат большой'),
        _SwitchableStageOption(kAutoSmallStageId, 'Автомат маленький'),
        _SwitchableStageOption(kTubeStageId, 'Труба'),
      ];
    }
    // Переключаемые этапы, заведённые в редакторе типов продукта. Раньше
    // список вариантов был только для двух зашитых этапов, а для остальных
    // возвращался пустым — из-за этого переключатель у своих этапов не
    // предлагал ничего и молча не работал.
    final route = ProductTypeSettings.instance.routeFor(_product.type);
    if (route != null) {
      for (final stage in route.stages) {
        if (stage.key != stageKey || !stage.isSwitchable) continue;
        return <_SwitchableStageOption>[
          for (final workplace in stage.workplaces)
            _SwitchableStageOption(
              workplace.workplaceId,
              (workplace.variantTitle ?? '').trim().isNotEmpty
                  ? workplace.variantTitle!.trim()
                  : ProductTypeSettings.instance
                      .workplaceName(workplace.workplaceId),
            ),
        ];
      }
    }
    return const <_SwitchableStageOption>[];
  }

  /// Выбор варианта для этапов из редактора.
  ///
  /// У двух зашитых переключателей выбор хранится в полях заказа
  /// (`selected_v_stage` / `selected_p_stage`), а у этапов маршрута такого
  /// поля нет: держим выбор здесь и отдаём сборщику очереди по ключу этапа.
  final Map<String, String> _routeSwitchableSelections = <String, String>{};

  String? _selectedSwitchableStageIdForPreview(
    String stageKey,
    Map<String, dynamic> stage,
  ) {
    final stateSelected = stageKey == kVMainSwitchStageKey
        ? _selectedVStage
        : stageKey == kPMainSwitchStageKey
            ? _selectedPStage
            : _routeSwitchableSelections[stageKey];
    final selected =
        (stateSelected ?? _selectedSwitchableIdFromPreviewStage(stage))
            ?.trim();
    final options = _switchableOptionsForStageKey(stageKey)
        .map((option) => option.stageId)
        .toSet();
    if (selected != null && options.contains(selected)) return selected;
    return options.isEmpty ? null : options.first;
  }

  bool _isBobbinPreviewStage(Map<String, dynamic> stage) {
    final id = _selectedSwitchableIdFromPreviewStage(stage)?.toLowerCase();
    if (id == kBobbinStageId || kLegacyBobbinStageAliases.contains(id)) {
      return true;
    }
    final name = _resolveStageName(stage).toLowerCase();
    return name.contains('бобин') ||
        name.contains('бабин') ||
        name.contains('bobbin');
  }

  bool _isFlexPrintingPreviewStage(Map<String, dynamic> stage) {
    final id = _selectedSwitchableIdFromPreviewStage(stage)?.toLowerCase();
    if (id == kFlexPrintingStageId ||
        kLegacyFlexPrintingStageAliases.contains(id)) {
      return true;
    }
    final name = _resolveStageName(stage).toLowerCase();
    return name.contains('флекс') || name.contains('flexo');
  }

  bool _canSwapBobbinFlexStage(int index) {
    if (index < 0 || index >= _stagePreviewStages.length) return false;
    final stage = _stagePreviewStages[index];
    if (!_isBobbinPreviewStage(stage) && !_isFlexPrintingPreviewStage(stage)) {
      return false;
    }
    return _stagePreviewStages.any(_isBobbinPreviewStage) &&
        _stagePreviewStages.any(_isFlexPrintingPreviewStage);
  }

  void _swapBobbinFlexStages() {
    final bobbinIndex = _stagePreviewStages.indexWhere(_isBobbinPreviewStage);
    final flexIndex =
        _stagePreviewStages.indexWhere(_isFlexPrintingPreviewStage);
    if (bobbinIndex < 0 || flexIndex < 0 || bobbinIndex == flexIndex) return;

    setState(() {
      final updated = _stagePreviewStages
          .map((stage) => Map<String, dynamic>.from(stage))
          .toList(growable: true);
      final tmp = updated[bobbinIndex];
      updated[bobbinIndex] = updated[flexIndex];
      updated[flexIndex] = tmp;
      for (var i = 0; i < updated.length; i++) {
        updated[i]['sortOrder'] = i + 1;
        updated[i]['order'] = i + 1;
      }
      _stagePreviewStages = updated;
      _stageOrderManuallyChanged = true;
      if (_queueBuildStatus == QueueBuildStatus.built) {
        _queueSignature = _currentQueueSignature();
        _isStageQueueBuilt = true;
      }
    });
  }

  void _selectSwitchablePreviewStage(String stageKey, String selectedStageId) {
    final current = stageKey == kVMainSwitchStageKey
        ? _selectedVStage
        : stageKey == kPMainSwitchStageKey
            ? _selectedPStage
            : _routeSwitchableSelections[stageKey];
    final effectiveCurrent = current ??
        (_switchableOptionsForStageKey(stageKey).isNotEmpty
            ? _switchableOptionsForStageKey(stageKey).first.stageId
            : null);
    if (effectiveCurrent == selectedStageId) return;

    final wasBuilt = _queueBuildStatus == QueueBuildStatus.built;
    setState(() {
      if (stageKey == kVMainSwitchStageKey) {
        _selectedVStage = selectedStageId;
      } else if (stageKey == kPMainSwitchStageKey) {
        _selectedPStage = selectedStageId;
      } else {
        // Этап из редактора: раньше здесь стоял return, и выбор молча
        // терялся — переключатель «не работал».
        _routeSwitchableSelections[stageKey] = selectedStageId;
      }

      final currentStages = _stagePreviewStages
          .map((stage) => Map<String, dynamic>.from(stage))
          .toList(growable: false);
      final queue = _buildStageQueueFromCurrentDraft(
        existingStages: currentStages,
        templateStages: _selectedTemplateStageMaps(),
      );
      _stagePreviewStages = queue;
      _syncSwitchableStageSelectionFields(queue);
      if (wasBuilt) {
        // Переключение альтернативного рабочего места уже перестраивает
        // фактическую очередь здесь. Поэтому запущенный/собранный заказ можно
        // сохранить сразу: сервис синхронизации ниже обновит только ожидающий
        // этап и заблокирует сохранение, если выбранный автомат уже начат.
        _queueBuildStatus = QueueBuildStatus.built;
        _queueSignature = _currentQueueSignature();
        _isStageQueueBuilt = true;
      } else {
        _queueBuildStatus = QueueBuildStatus.outdated;
        _isStageQueueBuilt = false;
      }
    });
  }

  void _cycleSwitchablePreviewStage(
    String stageKey,
    Map<String, dynamic> stage,
  ) {
    final options = _switchableOptionsForStageKey(stageKey);
    if (options.length < 2) return;
    final selected = _selectedSwitchableStageIdForPreview(stageKey, stage);
    final currentIndex =
        options.indexWhere((option) => option.stageId == selected);
    final nextIndex =
        currentIndex < 0 ? 0 : (currentIndex + 1) % options.length;
    _selectSwitchablePreviewStage(stageKey, options[nextIndex].stageId);
  }

  String? _persistedSelectedVStage(String queueBuildStatus) =>
      queueBuildStatus == QueueBuildStatus.built
          ? _selectedVStage
          : widget.order?.selectedVStage;

  String? _persistedSelectedPStage(String queueBuildStatus) =>
      queueBuildStatus == QueueBuildStatus.built
          ? _selectedPStage
          : widget.order?.selectedPStage;

  List<Map<String, dynamic>> _buildStageQueueFromCurrentDraft({
    List<Map<String, dynamic>> existingStages = const <Map<String, dynamic>>[],
    List<Map<String, dynamic>> templateStages = const <Map<String, dynamic>>[],
  }) {
    final draft = _currentStageQueueDraft();
    final switchableSelectionSource = existingStages.isNotEmpty
        ? existingStages
        : _stagePreviewStages;
    final selectedSwitchableStageIdsByStageKey = <String, String>{
      ...collectSwitchableStageSelectionsByStageKey(switchableSelectionSource),
      // Выбор по этапам маршрута читаем из уже собранной очереди: у них нет
      // своего поля в заказе, а зашитый сборщик такие ключи отбрасывает.
      ...collectRouteSwitchableSelections(
        ProductTypeSettings.instance.routeFor(_product.type),
        switchableSelectionSource,
      ),
      if ((_selectedVStage ?? '').trim().isNotEmpty)
        kVMainSwitchStageKey: _selectedVStage!.trim(),
      if ((_selectedPStage ?? '').trim().isNotEmpty)
        kPMainSwitchStageKey: _selectedPStage!.trim(),
      // Явный выбор пользователя перекрывает прочитанное из очереди.
      ..._routeSwitchableSelections,
    };
    return _orderQueueService.buildPreviewQueue(
      draft.copyWithSwitchableSelections(selectedSwitchableStageIdsByStageKey),
      existingStages: existingStages,
      templateStages: templateStages,
    );
  }

  void _buildStageQueue() {
    final currentStages = _stagePreviewStages
        .map((s) => Map<String, dynamic>.from(s))
        .toList(growable: false);
    final queue = _buildStageQueueFromCurrentDraft(
      existingStages: currentStages,
      templateStages: _selectedTemplateStageMaps(),
    );
    setState(() {
      _stagePreviewStages = queue;
      _syncSwitchableStageSelectionFields(queue);
      _queueSignature = _currentQueueSignature();
      _queueBuildStatus = QueueBuildStatus.built;
      _isStageQueueBuilt = true;
    });
  }

  void _onStageTemplateTextChanged() {
    if (_updatingStageTemplateText) return;
    final text = _stageTemplateController.text;
    if (text == _stageTemplateSearchText) return;
    setState(() {
      _stageTemplateSearchText = text;
      if (_stageTemplateId != null &&
          _selectedStageTemplateName != null &&
          _selectedStageTemplateName!.trim() != text.trim()) {
        _stageTemplateId = null;
        _selectedStageTemplateName = null;
        _markQueueOutdatedIfBuilt();
        _stagePreviewStages = <Map<String, dynamic>>[];
        _stagePreviewError = null;
        _stagePreviewLoading = false;
        _stagePreviewInitialized = false;
        _stagePreviewScheduled = false;
      }
    });
  }

  bool _hasAnyPaints() {
    for (final paint in _paints) {
      final hasTmc = paint.tmc != null;
      final hasName = paint.displayName.trim().isNotEmpty;
      final hasQty = paint.qtyGrams != null;
      if (hasTmc || hasName || hasQty) {
        return true;
      }
    }
    return false;
  }

  void _handlePaintsChanged() {
    final formResult = applyOrderFormRules(
      draft: _buildCurrentOrderDraft(),
      hasPaints: _hasAnyPaints(),
      userManuallySelectedFormType: _userManuallySelectedFormType,
    );
    _hasForm = formResult.hasForm;
    _isOldForm = formResult.isOldForm;
    _orderFormNo = formResult.newFormNo;
    _orderFormSeries = formResult.formSeries;
    _orderFormCode = formResult.formCode;

    final filled = _hasAnyPaints();
    if (_lastPreviewPaintsFilled != filled) {
      _lastPreviewPaintsFilled = filled;
      _scheduleStagePreviewUpdate();
    } else if (filled) {
      _scheduleStagePreviewUpdate();
    }
  }

  OrderModel _buildCurrentOrderDraft() {
    final source = widget.order ?? widget.initialOrder;
    final base = source ??
        OrderModel(
          id: '',
          manager: '',
          customer: '',
          orderDate: DateTime.now(),
          dueDate: null,
          product: _product,
        );
    return base.copyWith(
      hasForm: _hasForm,
      isOldForm: _isOldForm,
      newFormNo: _orderFormNo,
      formSeries: _orderFormSeries,
      formCode: _orderFormCode,
      formId: _orderFormId,
    );
  }

  void _validatePaintNames() {
    final warehouse = Provider.of<WarehouseProvider>(context, listen: false);
    final paints = warehouse.getTmcByType('Краска');
    setState(() {
      for (final row in _paints) {
        final input = row.displayName.trim();
        if (input.isEmpty) {
          row.nameNotFound = false;
          row.tmc = null;
          row.exceeded = false;
          continue;
        }

        TmcModel? match;
        for (final paint in paints) {
          if (paint.description.trim().toLowerCase() == input.toLowerCase()) {
            match = paint;
            break;
          }
        }
        row.tmc = match;
        row.nameNotFound = match == null;
        if (match != null && row.qtyGrams != null) {
          row.exceeded =
              _gramsToStockUnit(row.qtyGrams!, match) > _paintAvailableQty(match);
        } else if (match == null) {
          row.exceeded = false;
        }
      }
    });
  }

  String _deriveSharedPaintInfo(List<_PaintEntry> paints) {
    for (final paint in paints) {
      final memo = paint.memo.trim();
      if (memo.isNotEmpty) {
        return memo;
      }
    }
    return '';
  }

  String? _formatGramsForInput(double? grams) {
    if (grams == null) return null;
    if (grams == 0) return '0';
    final fixed = grams.toStringAsFixed(grams % 1 == 0 ? 0 : 2);
    return _trimTrailingFractionZeros(fixed);
  }

  /// Доступный остаток краски для этой формы: общий минус чужие резервы.
  ///
  /// `tmc.availableQty` уже вычтен резерв ВСЕХ активных заказов, включая
  /// редактируемый. Свой резерв возвращаем обратно — иначе при открытии
  /// существующего заказа его собственные 400 г выглядели бы занятыми и
  /// поле подсвечивалось бы как «Недостаточно».
  /// Свободный остаток краски: склад − чужая бронь − неприкасаемый запас.
  ///
  /// Своя бронь возвращается обратно, иначе заказ не проходит проверку по
  /// собственным же граммам. Запас снимается ОДИН раз (см.
  /// [kUntouchablePaintGrams]) и переводится в единицы этой карточки склада:
  /// краски заводят и в граммах, и в килограммах.
  double _paintAvailableQty(TmcModel tmc) {
    final own = _ownPaintReservations[tmc.id] ?? 0;
    final untouchable = _gramsToStockUnit(kUntouchablePaintGrams, tmc);
    final free = tmc.availableQty + own - untouchable;
    return free > 0 ? free : 0;
  }

  /// Резерв текущего заказа по краскам: paint_id → количество в единицах
  /// склада. Для нового заказа карта пустая.
  final Map<String, double> _ownPaintReservations = <String, double>{};

  Future<void> _loadOwnPaintReservations() async {
    final orderId = (widget.order?.id ?? '').trim();
    if (orderId.isEmpty) return;
    try {
      final rows = await Supabase.instance.client
          .from('order_paint_reservations')
          .select('paint_id, reserved_qty')
          .eq('order_id', orderId);
      final next = <String, double>{};
      for (final raw in rows.whereType<Map>()) {
        final row = Map<String, dynamic>.from(raw);
        final id = (row['paint_id'] ?? '').toString().trim();
        if (id.isEmpty) continue;
        final value = row['reserved_qty'];
        final qty = value is num
            ? value.toDouble()
            : double.tryParse('${value ?? ''}') ?? 0;
        if (qty > 0) next[id] = (next[id] ?? 0) + qty;
      }
      if (!mounted || next.isEmpty) return;
      setState(() {
        _ownPaintReservations
          ..clear()
          ..addAll(next);
      });
      // Пересчитываем подсветку: до этого момента собственная бронь заказа
      // считалась чужой, и поля показывали «Недостаточно материала» на своих
      // же граммах. Обратный случай тоже важен — краску мог забрать сосед,
      // пока заказ лежал, и увидеть это надо сразу при открытии, а не после
      // правки поля.
      _validatePaintNames();
    } catch (_) {
      // Не критично: без своих резервов остаток будет чуть занижен.
    }
  }

  /// Остаток склада без хвоста нулей: 4600, 4600.5.
  String _formatStockQty(double value) {
    final precision = value % 1 == 0 ? 0 : 2;
    return _trimTrailingFractionZeros(value.toStringAsFixed(precision));
  }

  double _gramsToStockUnit(double grams, TmcModel tmc) {
    final unit = tmc.unit.toLowerCase();
    if (unit.contains('кг') || unit.contains('kg')) {
      return grams / 1000;
    }
    if (unit.contains('г') || unit.contains('g')) {
      return grams;
    }
    return grams;
  }

  String _formatGrams(double grams) {
    final precision = grams % 1 == 0 ? 0 : 2;
    final fixed = grams.toStringAsFixed(precision);
    final trimmed = _trimTrailingFractionZeros(fixed);
    return '$trimmed г';
  }

  double? _parseGrams(String value) {
    final normalized = value.replaceAll(',', '.').trim();
    if (normalized.isEmpty) return null;
    return double.tryParse(normalized);
  }

  bool _hasAssignedForm() {
    if (!_hasForm) return false;
    final hasNumber = _orderFormNo != null;
    final hasCode = _orderFormCode != null && _orderFormCode!.trim().isNotEmpty;
    return hasNumber || hasCode;
  }

  double? _parseLeadingNumber(String? source) {
    if (source == null) return null;
    final match = RegExp(r'[0-9]+(?:[.,][0-9]+)?')
        .firstMatch(source.replaceAll(',', '.'));
    if (match == null) return null;
    return double.tryParse(match.group(0)!);
  }

  double? _paperFormatWidth(MaterialModel paper, {required bool isMain}) {
    final width = parseMaterialWidth(paper);
    if (width != null) return width;
    if (isMain &&
        (paper.id ?? '').trim().isEmpty &&
        (_matSelectedFormat ?? '').trim().isNotEmpty) {
      return _parseLeadingNumber(_matSelectedFormat);
    }
    return null;
  }

  String? _validatePaperWidthB({
    required double? widthB,
    required MaterialModel paper,
    required bool isMain,
  }) {
    if (widthB == null || widthB <= 0) return null;
    final formatWidth = _paperFormatWidth(paper, isMain: isMain);
    if (formatWidth == null) return null;
    if (widthB > formatWidth) {
      return 'Ширина b не может быть больше формата ($formatWidth)';
    }
    return null;
  }

  void _scheduleStagePreviewUpdate({bool immediate = false}) {
    if (!mounted) return;
    if (_queueBuildStatus == QueueBuildStatus.built &&
        !_sameQueueSignature(_queueSignature, _currentQueueSignature())) {
      _queueBuildStatus = QueueBuildStatus.outdated;
    }
    if (immediate) {
      _stagePreviewScheduled = false;
      _rebuildStagePreview();
      return;
    }
    if (_stagePreviewScheduled) return;
    _stagePreviewScheduled = true;
    Future.microtask(() {
      if (!mounted) return;
      _stagePreviewScheduled = false;
      _rebuildStagePreview();
    });
  }

  List<Map<String, dynamic>> _templateStageMaps(TemplateModel template) {
    return template.stages
        .map((s) => {
              'stageId': s.allStageIds.isNotEmpty ? s.allStageIds.first : s.stageId,
              'workplaceId':
                  s.allStageIds.isNotEmpty ? s.allStageIds.first : s.stageId,
              'workplaceIds': List<String>.from(s.allStageIds),
              'stageName': s.stageName,
              'workplaceName': s.stageName,
              if (s.alternativeStageIds.isNotEmpty)
                'alternativeStageIds': List<String>.from(s.alternativeStageIds),
              if (s.alternativeStageNames.isNotEmpty)
                'alternativeStageNames':
                    List<String>.from(s.alternativeStageNames),
            })
        .toList();
  }

  List<Map<String, dynamic>> _selectedTemplateStageMaps() {
    final templateId = _stageTemplateId;
    if (templateId == null || templateId.isEmpty) {
      return const <Map<String, dynamic>>[];
    }
    final provider = context.read<TemplateProvider>();
    final template = _findTemplateById(provider.templates, templateId);
    return template == null
        ? const <Map<String, dynamic>>[]
        : _templateStageMaps(template);
  }

  List<Map<String, dynamic>> _normalizeSavedPreviewStages(
    List<Map<String, dynamic>> rows,
  ) {
    return rows.map((source) {
      final row = Map<String, dynamic>.from(source);
      final stageName = (row['stageName'] ??
              row['stage_name'] ??
              row['workplaceName'] ??
              row['workplace_name'] ??
              row['name'] ??
              row['title'] ??
              '')
          .toString()
          .trim();
      if (stageName.isNotEmpty) {
        row['stageName'] ??= stageName;
        row['workplaceName'] ??= stageName;
      }
      final stageId = (row['stageId'] ??
              row['stage_id'] ??
              row['stageid'] ??
              row['workplaceId'] ??
              row['workplace_id'] ??
              row['id'] ??
              '')
          .toString()
          .trim();
      if (stageId.isNotEmpty) {
        row['stageId'] ??= stageId;
        row['workplaceId'] ??= stageId;
        row['id'] ??= stageId;
      }
      return row;
    }).toList(growable: false);
  }

  bool _shouldKeepSavedStagePreview(SavedOrderQueue saved) {
    if (widget.order == null || saved.rows.isEmpty) return false;
    if (_stageOrderManuallyChanged) return false;
    if (QueueBuildStatus.normalize(_queueBuildStatus) !=
        QueueBuildStatus.built) {
      return false;
    }
    return isQueueActual(
          currentSignature: _currentQueueSignature(),
          storedSignature: _queueSignature,
          queueBuildStatus: _queueBuildStatus,
          stages: _stagePreviewStages,
        ) ||
        widget.order!.assignmentCreated;
  }

  List<Map<String, dynamic>> _currentBuiltStageMapsForSave() {
    if (_stagePreviewStages.isNotEmpty) {
      return _stagePreviewStages
          .map((stage) => Map<String, dynamic>.from(stage))
          .toList(growable: false);
    }
    return _buildStageQueueFromCurrentDraft(
      existingStages: _stagePreviewStages,
      templateStages: _selectedTemplateStageMaps(),
    );
  }

  Future<void> _rebuildStagePreview() async {
    final templateStages = _selectedTemplateStageMaps();

    // Для редактирования сначала берём уже сохранённую очередь заказа
    // через общий сервис, чтобы UI не выбирал источник плана напрямую.
    List<Map<String, dynamic>> existingStages = <Map<String, dynamic>>[];
    if (widget.order != null) {
      try {
        final saved = await _orderQueueService.loadSavedQueue(widget.order!.id);
        existingStages = _normalizeSavedPreviewStages(saved.rows);
        if (_shouldKeepSavedStagePreview(saved)) {
          if (!mounted) return;
          setState(() {
            _stagePreviewStages = existingStages;
            _stagePreviewLoading = false;
            _stagePreviewError = null;
            _stagePreviewInitialized = true;
            _isStageQueueBuilt = true;
          });
          return;
        }
      } catch (_) {
        existingStages = <Map<String, dynamic>>[];
      }
    }

    if (mounted) {
      setState(() {
        _stagePreviewLoading = true;
        _stagePreviewError = null;
      });
    }

    try {
      final queue = _buildStageQueueFromCurrentDraft(
        existingStages: existingStages,
        templateStages: templateStages,
      );
      if (!mounted) return;
      setState(() {
        _stagePreviewStages = queue;
        _stagePreviewLoading = false;
        _stagePreviewError = null;
        _stagePreviewInitialized = true;
        _stageOrderManuallyChanged = false;
        _isStageQueueBuilt = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _stagePreviewStages = <Map<String, dynamic>>[];
        _stagePreviewLoading = false;
        _stagePreviewError = e.toString();
        _stagePreviewInitialized = true;
      });
    }
  }

  @override
  void didChangeDependencies() {
    if (widget.order != null && !_fetchedOrderForm) {
      _fetchedOrderForm = true;
      _loadOrderFormDisplay();
    }

    super.didChangeDependencies();
    // Загружаем список менеджеров и нумерации форм только один раз
    if (!_dataLoaded) {
      final personnel = context.read<PersonnelProvider>();
      final managerPos = personnel.findManagerPosition();
      final names = <String>[];
      if (managerPos != null) {
        for (final emp in personnel.employees) {
          if (emp.positionIds.contains(managerPos.id)) {
            final fullName =
                ('${emp.lastName} ${emp.firstName} ${emp.patronymic}').trim();
            names.add(fullName);
          }
        }
      }
      _managerNames = names;
      if (_selectedManager != null && _selectedManager!.trim().isNotEmpty) {
        if (!_managerNames.contains(_selectedManager)) {
          _managerNames = List<String>.from(_managerNames)
            ..add(_selectedManager!);
        }
      }
      _managerNames.sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
      _updateManagerDisplayController();
      final warehouse = context.read<WarehouseProvider>();
      // Восстановим краски из параметров заказа, если есть
      _restorePaints(warehouse);

      // Загружаем номера форм напрямую из склада forms (а не из TMC)
      Future.microtask(() async {
        try {
          final next = await warehouse.getGlobalNextFormNumber();
          if (mounted) {
            setState(() {
              _availableForms = [];
              _defaultFormNumber = next;
              _dataLoaded = true;
            });
          }
        } catch (_) {
          if (mounted) {
            setState(() {
              _availableForms = [];
              _defaultFormNumber = 1;
              _dataLoaded = true;
            });
          }
        }
      });
    }
    // Если редактируем существующий заказ - подтянем зафиксированный номер формы для отображения
    if (widget.order != null) {
      Future.microtask(() async {
        try {
          final row = await _sb
              .from('orders')
              .select('has_form, is_old_form, new_form_no, form_code')
              .eq('id', widget.order!.id)
              .maybeSingle();
          if (mounted) {
            setState(() {
              _hasForm = (row?['has_form'] as bool?) ??
                  ((row?['is_old_form'] as bool?) != null ||
                      ((row?['new_form_no'] as num?)?.toInt()) != null ||
                      (row?['form_code'] ?? '').toString().isNotEmpty);
              _orderFormIsOld = (row?['is_old_form'] as bool?);
              _orderFormNo = ((row?['new_form_no'] as num?)?.toInt());
              _orderFormDisplay =
                  _orderFormNo != null ? _orderFormNo.toString() : '-';
            });
          }
        } catch (_) {}
      });
    }

    // Если редактируем существующий заказ - подтянем зафиксированный номер формы и код
    if (widget.order != null) {
      Future.microtask(() async {
        try {
          final row = await _sb
              .from('orders')
              .select('has_form, is_old_form, new_form_no, form_series, form_code')
              .eq('id', widget.order!.id)
              .maybeSingle();
          if (mounted) {
            final bool hasForm = (row?['has_form'] as bool?) ??
                ((row?['is_old_form'] as bool?) != null ||
                    ((row?['new_form_no'] as num?)?.toInt()) != null ||
                    (row?['form_code'] ?? '').toString().isNotEmpty);
            final bool? isOld = (row?['is_old_form'] as bool?);
            final int? no = ((row?['new_form_no'] as num?)?.toInt());
            final String series = (row?['form_series'] ?? '').toString();
            final String code = (row?['form_code'] ?? '').toString();
            String display = '-';
            if (code.isNotEmpty) {
              display = code;
            } else if (series.isNotEmpty && no != null) {
              display = series + no.toString().padLeft(4, '0');
            } else if (no != null) {
              display = no.toString();
            }
            setState(() {
              _hasForm = hasForm;
              _orderFormIsOld = isOld;
              _orderFormNo = no;
              _orderFormSeries = series.isNotEmpty ? series : null;
              _orderFormCode = code.isNotEmpty ? code : null;
              _orderFormDisplay = display;
            });
          }
        } catch (_) {}
      });
    }
  }

  @override
  void dispose() {
    _createdLease?.dispose();
    _customerController.dispose();
    _formExtraInfoController.dispose();
    _commentsController.dispose();
    _packagingController.dispose();
    _lengthController.dispose();
    _widthController.dispose();
    _depthController.dispose();
    _paintInfoController.dispose();
    _formScrollController.dispose();
    _paperSearchController.dispose();
    _paintSearchController.dispose();
    _categorySearchController.dispose();
    _paperListController.dispose();
    _paintListController.dispose();
    _categoryListController.dispose();

    _formSearchDebounce?.cancel();
    _formSearchFocusNode.dispose();
    _formSearchCtl.dispose();
    _stockExtraSearchDebounce?.cancel();
    _stockExtraFocusNode.dispose();
    _stockExtraSearchController.dispose();
    _stockExtraQtyController.dispose();
    _managerDisplayController.dispose();

    _stageTemplateController.removeListener(_onStageTemplateTextChanged);
    _stageTemplateController.dispose();
    _stageTemplateFocusNode.dispose();

    _matNameCtl.dispose();
    _matFormatCtl.dispose();
    _matGramCtl.dispose();
    super.dispose();
  }

  void _updateStockExtraQtyController() {
    final double? value = _stockExtraSelectedQty;
    final String text = (value != null && value > 0)
        ? _formatDecimal(value, fractionDigits: 2)
        : '';
    _stockExtraQtyController.value = TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: text.length),
    );
  }

  Future<void> _updateStockExtra(
      {String? query, bool includeAllResults = false}) async {
    final typeTitle = _product.type.trim();
    final search = query ?? _stockExtraSearchController.text.trim();
    if (typeTitle.isEmpty) {
      if (mounted) {
        setState(() {
          _stockExtra = null;
          _stockExtraItem = null;
          _stockExtraResults = includeAllResults ? _stockExtraResults : [];
          _selectedStockExtraRow = null;
          _loadingStockExtra = false;
          _stockExtraSelectedQty = null;
          _stockExtraQtyTouched = false;
          _product.leftover = null;
          _writeOffStockExtra = false;
        });
        _updateStockExtraQtyController();
      }
      return;
    }

    if (mounted) {
      setState(() {
        _loadingStockExtra = true;
      });
    }

    try {
      final sanitizedTitle = typeTitle.replaceAll("'", "''");
      final cat = await _sb
          .from('warehouse_categories')
          .select('id, title, code, has_subtables')
          .or('title.eq.$sanitizedTitle,code.eq.$sanitizedTitle')
          .maybeSingle();
      if (cat == null) {
        if (mounted) {
          setState(() {
            _stockExtra = null;
            _stockExtraItem = null;
            _stockExtraResults = includeAllResults ? _stockExtraResults : [];
            _selectedStockExtraRow = null;
            _loadingStockExtra = false;
            _stockExtraSelectedQty = null;
            _stockExtraQtyTouched = false;
            _product.leftover = null;
          });
          _updateStockExtraQtyController();
        }
        return;
      }

      final bool hasSubtables = (cat['has_subtables'] ?? false) == true;
      var builder = _sb
          .from('warehouse_category_items')
          .select('id, description, quantity, table_key, size')
          .eq('category_id', cat['id']);
      if (hasSubtables) {
        builder = builder.eq('table_key', typeTitle);
      }
      if (search.isNotEmpty) {
        final sanitized = search.replaceAll("'", "''");
        builder = builder
            .or('description.ilike.%$sanitized%,size.ilike.%$sanitized%');
      }
      final rows = await builder.order('description').limit(100);
      final List<Map<String, dynamic>> results = [];
      for (final r in (rows as List)) {
        final map = Map<String, dynamic>.from(r as Map);
        final qv = map['quantity'];
        final q =
            (qv is num) ? qv.toDouble() : double.tryParse('${qv ?? ''}') ?? 0.0;
        results.add(map);
      }

      Map<String, dynamic>? selectedRow;
      if (_selectedStockExtraRow != null) {
        final selectedId = _selectedStockExtraRow!['id']?.toString();
        if (selectedId != null) {
          final candidate = results.firstWhere(
              (row) => row['id']?.toString() == selectedId,
              orElse: () => <String, dynamic>{});
          if (candidate.isNotEmpty) {
            selectedRow = candidate;
          }
        }
      }

      double? displayQty;
      if (selectedRow != null) {
        final qv = selectedRow['quantity'];
        displayQty =
            (qv is num) ? qv.toDouble() : double.tryParse('${qv ?? ''}') ?? 0.0;
      } else {
        displayQty = null;
      }

      double? nextSelectedQty;
      if (_stockExtraQtyTouched) {
        final double? current = _stockExtraSelectedQty;
        if (current != null) {
          final double maxAvailable =
              displayQty != null && displayQty > 0 ? displayQty : current;
          nextSelectedQty = math.max(0, math.min(current, maxAvailable));
        }
      } else {
        final double? templateLeftover = _product.leftover;
        if (templateLeftover != null && templateLeftover > 0) {
          final double maxAvailable = displayQty != null && displayQty > 0
              ? displayQty
              : templateLeftover;
          nextSelectedQty =
              math.max(0, math.min(templateLeftover, maxAvailable));
        } else if (displayQty != null && displayQty > 0) {
          nextSelectedQty = displayQty;
        } else {
          nextSelectedQty = null;
        }
      }

      if (mounted) {
        setState(() {
          _stockExtra = displayQty;
          _stockExtraItem = null;
          _selectedStockExtraRow = selectedRow;
          _stockExtraResults = (includeAllResults || search.isNotEmpty)
              ? results
              : <Map<String, dynamic>>[];
          _loadingStockExtra = false;
          _stockExtraSelectedQty = nextSelectedQty;
          _product.leftover = nextSelectedQty != null && nextSelectedQty > 0
              ? nextSelectedQty
              : null;
          if (_writeOffStockExtra && (_stockExtraSelectedQty ?? 0) <= 0) {
            _writeOffStockExtra = false;
          }
        });
        _updateStockExtraQtyController();
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          _stockExtra = null;
          _stockExtraItem = null;
          _stockExtraResults = includeAllResults ? _stockExtraResults : [];
          _selectedStockExtraRow = null;
          _loadingStockExtra = false;
          _stockExtraSelectedQty = null;
          _stockExtraQtyTouched = false;
          _product.leftover = null;
          _writeOffStockExtra = false;
        });
        _updateStockExtraQtyController();
      }
    }
  }

  void _selectMaterial(TmcModel tmc) {
    _selectedMaterialTmc = tmc;
    _selectedMaterial = MaterialModel(
      id: tmc.id,
      name: tmc.description,
      format: tmc.format ?? '',
      grammage: tmc.grammage ?? '',
      weight: tmc.weight,
    );
    setState(() {});
    _scheduleStagePreviewUpdate();
  }

  double _stockQtyToGrams(TmcModel tmc) {
    final unit = tmc.unit.toLowerCase();
    if (unit.contains('кг') || unit.contains('kg')) {
      return tmc.quantity * 1000;
    }
    if (unit.contains('г') || unit.contains('g')) {
      return tmc.quantity;
    }
    return tmc.quantity;
  }

  void _applyPaperSelection(TmcModel paper) {
    if (_activePaperSlotIndex > 0) {
      // Индекс вне диапазона — это рассинхрон состояния, а не выбор основной
      // бумаги. Прежний код в таком случае молча проваливался вниз и
      // переписывал первую бумагу: сотрудник выбирал материал для второй, а
      // менялась первая. Лучше прижать к последнему дополнительному слоту —
      // выбор останется там, куда сотрудник целился.
      final extraIndex = _activePaperSlotIndex - 1 < _extraPaperMaterials.length
          ? _activePaperSlotIndex - 1
          : _extraPaperMaterials.length - 1;
      if (extraIndex >= 0 && extraIndex < _extraPaperMaterials.length) {
        final currentExtra = _extraPaperMaterials[extraIndex];
        setState(() {
          _markQueueOutdatedIfBuilt();
          _extraPaperMaterials[extraIndex] = currentExtra.copyWith(
            id: paper.id,
            name: paper.description,
            format: paper.format ?? '',
            grammage: paper.grammage ?? '',
            quantity: currentExtra.quantity > 0
                ? currentExtra.quantity
                : (_product.length ?? 0).toDouble(),
            unit: 'м',
          );
        });
        _scheduleStagePreviewUpdate();
        return;
      }
    }
    final name = paper.description.trim();
    final format = (paper.format ?? '').trim();
    final grammage = (paper.grammage ?? '').trim();
    setState(() {
      _matNameCtl
        ..text = name
        ..selection = TextSelection.collapsed(offset: name.length);
      _matFormatCtl
        ..text = format
        ..selection = TextSelection.collapsed(offset: format.length);
      _matGramCtl
        ..text = grammage
        ..selection = TextSelection.collapsed(offset: grammage.length);
      _matSelectedName = name.isEmpty ? null : name;
      _matSelectedFormat = format.isEmpty ? null : format;
      _matSelectedGrammage = grammage.isEmpty ? null : grammage;
      _matNameError = null;
      _matFormatError = null;
      _matGramError = null;
    });
    _selectMaterial(paper);
  }

  List<MaterialModel> _collectSelectedPapers() {
    final List<MaterialModel> selected = <MaterialModel>[];
    final double fallbackQty =
        (_product.length ?? _selectedMaterial?.quantity ?? 0).toDouble();
    // «Длина L» основной бумаги. Именно это поле правит менеджер, и оно
    // обязано побеждать количество, сохранённое в материале раньше: иначе
    // первое записанное значение застывает навсегда — правка поля меняла
    // только product.length, а потребность считалась по material.quantity,
    // и заказ продолжал требовать старый метраж.
    final double mainPaperLength = (_product.length ?? 0).toDouble();
    TmcModel? resolvePaperByMaterial(MaterialModel paper) {
      final paperId = (paper.id ?? '').trim();
      if (paperId.isNotEmpty) {
        for (final t in _paperItems()) {
          if (t.id == paperId) return t;
        }
      }
      final name = paper.name.trim().toLowerCase();
      final format = (paper.format ?? '').trim().toLowerCase();
      final grammage = (paper.grammage ?? '').trim().toLowerCase();
      if (name.isEmpty || format.isEmpty || grammage.isEmpty) return null;
      for (final t in _paperItems()) {
        if (t.description.trim().toLowerCase() == name &&
            (t.format ?? '').trim().toLowerCase() == format &&
            (t.grammage ?? '').trim().toLowerCase() == grammage) {
          return t;
        }
      }
      return null;
    }
    if (_selectedMaterial != null) {
      final resolved = resolvePaperByMaterial(_selectedMaterial!);
      selected.add(
        _selectedMaterial!.copyWith(
          id: resolved?.id ?? _selectedMaterial!.id,
          quantity: persistedPaperQuantity(
            editedLength: mainPaperLength,
            storedQuantity: _selectedMaterial!.quantity,
          ),
          unit: 'м',
        ),
      );
    }
    // Дополнительные типы бумаги сохраняем отдельными позициями.
    for (final paper in _extraPaperMaterials) {
      final resolved = resolvePaperByMaterial(paper);
      final id = (resolved?.id ?? paper.id ?? '').trim();
      if (id.isEmpty) continue;
      // Та же приоритетность, что и у основной бумаги: отредактированное
      // поле «Длина L» важнее ранее сохранённого количества.
      final extraLength = _paperExtraDouble(paper, 'lengthL');
      final resolvedQty = persistedPaperQuantity(
        editedLength: extraLength ?? 0,
        storedQuantity: paper.quantity,
        fallback: fallbackQty,
      );
      selected.add(
        paper.copyWith(
          id: id,
          quantity: resolvedQty,
          unit: 'м',
        ),
      );
    }
    return selected;
  }

  void _addExtraPaperSlot() {
    setState(() {
      _extraPaperMaterials.add(
        MaterialModel(
          id: '',
          name: '',
          quantity: (_product.length ?? 0).toDouble(),
          unit: 'м',
          extra: <String, dynamic>{
            if (_product.widthB != null) 'widthB': _product.widthB,
            if ((_product.blQuantity ?? '').trim().isNotEmpty)
              'blQuantity': _product.blQuantity!.trim(),
            if (_product.length != null) 'lengthL': _product.length,
          },
        ),
      );
      _activePaperSlotIndex = _extraPaperMaterials.length;
    });
    // Очередь здесь не пересобираем: слот пока пустой, в черновик он не
    // попадает (`_collectSelectedPapers` отбрасывает записи без id), а
    // пересборка показывала «этапы по умолчанию» на заказе, где тип продукта
    // ещё не выбран. Маршрут обновят обработчики полей самого слота, когда
    // сотрудник выберет материал.
  }

  double? _paperExtraDouble(MaterialModel paper, String key) {
    final value = paper.extra?[key];
    if (value is num) return value.toDouble();
    if (value is String) {
      final normalized = value.trim().replaceAll(',', '.');
      if (normalized.isEmpty) return null;
      return double.tryParse(normalized);
    }
    return null;
  }

  String? _paperExtraString(MaterialModel paper, String key) {
    final value = paper.extra?[key];
    final text = value?.toString().trim() ?? '';
    return text.isEmpty ? null : text;
  }

  void _addPaintFromTmc(TmcModel paint) {
    final qtyGrams = _stockQtyToGrams(paint);
    setState(() {
      _paints.add(
        _PaintEntry(
          tmc: paint,
          name: paint.description,
          qtyGrams: qtyGrams > 0 ? qtyGrams : null,
          memo: _paintInfo,
          exceeded: false,
          nameNotFound: false,
        ),
      );
    });
    _validatePaintNames();
    _handlePaintsChanged();
  }

  void _restorePaintsFromParams(WarehouseProvider warehouse) {
    if (_paintsRestored) return;
    final template = widget.order ?? widget.initialOrder;
    final params = template?.product.parameters ?? '';
    if (params.isEmpty) {
      _paintsRestored = true;
      return;
    }
    final infoMatch = RegExp(
      r'Информация для красок:\s*([^;]+)',
      caseSensitive: false,
    ).firstMatch(params);
    final infoFromParams = (infoMatch?.group(1) ?? '').trim();
    final paintTmcList = warehouse.getTmcByType('Краска');
    final reg = RegExp(
        r'Краска:\s*(.+?)\s+([0-9]+(?:[.,][0-9]+)?)\s*(кг|г)(?:\s*\(([^)]+)\))?',
        multiLine: false,
        caseSensitive: false);
    final matches = reg.allMatches(params).toList();
    if (matches.isEmpty) {
      if (infoFromParams.isNotEmpty) {
        setState(() {
          _paintInfo = infoFromParams;
          _paintInfoController.value = TextEditingValue(
            text: infoFromParams,
            selection: TextSelection.collapsed(offset: infoFromParams.length),
          );
          _paintsRestored = true;
        });
      } else {
        _paintsRestored = true;
      }
      return;
    }
    final restored = <_PaintEntry>[];
    for (final m in matches) {
      final name = (m.group(1) ?? '').trim();
      final qtyStr = (m.group(2) ?? '').replaceAll(',', '.');
      final unit = (m.group(3) ?? '').toLowerCase();
      final memo = (m.group(4) ?? '').trim();
      final qty = double.tryParse(qtyStr);
      if (name.isEmpty || qty == null) continue;
      // Важно: "кг" тоже содержит букву "г", поэтому проверяем килограммы первыми.
      final grams = (unit.contains('кг') || unit.contains('kg')) ? qty * 1000 : qty;
      TmcModel? found;
      for (final t in paintTmcList) {
        if (t.description.trim() == name) {
          found = t;
          break;
        }
      }
      if (found != null) {
        restored.add(_PaintEntry(
            tmc: found, name: found.description, qtyGrams: grams, memo: memo));
      } else {
        restored.add(_PaintEntry(name: name, qtyGrams: grams, memo: memo));
      }
    }
    if (restored.isNotEmpty) {
      final sharedInfo = infoFromParams.isNotEmpty
          ? infoFromParams
          : _deriveSharedPaintInfo(restored);
      setState(() {
        _paints
          ..clear()
          ..addAll(restored);
        _paintInfo = sharedInfo;
        for (final paint in _paints) {
          paint.memo = sharedInfo;
        }
        _paintInfoController.value = TextEditingValue(
          text: sharedInfo,
          selection: TextSelection.collapsed(offset: sharedInfo.length),
        );
        _paintsRestored = true;
      });
      _handlePaintsChanged();
      _validatePaintNames();
    } else {
      _paintsRestored = true;
    }
  }

  /// Сохраняет список красок в таблицу order_paints и синхронизирует product.parameters.
  Future<void> _persistPaints(String orderId) async {
    // 1) Всегда чистим строки "Краска: ..." в product.parameters
    final cleanRe = RegExp(
      r'(?:^|;\s*)(?:Краска:\s*.+?(?=(?:;\s*Краска:|;\s*Информация для красок:|$))|'
      r'Информация для красок:\s*.+?(?=(?:;\s*Краска:|;\s*Информация для красок:|$)))',
      caseSensitive: false,
    );
    var clean = _product.parameters.replaceAll(cleanRe, '').trim();
    if (clean.endsWith(';')) {
      clean = clean.substring(0, clean.length - 1).trim();
    }

    // 2) Строим список строк и записей для order_paints
    final rows = <Map<String, dynamic>>[];
    final infos = <String>[];
    final sharedInfo = _paintInfo.trim();
    for (final row in _paints) {
      final name = (row.tmc?.description ?? row.name)?.trim();
      final qtyGrams = row.qtyGrams ?? 0;
      if (name == null || name.isEmpty) continue;
      rows.add({
        'order_id': orderId,
        'name': name,
        'info': sharedInfo.isNotEmpty ? sharedInfo : null,
        'qty_kg': row.qtyKg, // может быть null
      });
      if (qtyGrams > 0) {
        infos.add(
            'Краска: $name ${_formatGrams(qtyGrams)}${sharedInfo.isNotEmpty ? ' ($sharedInfo)' : ''}');
      }
    }

    // 3) Обновляем product.parameters
    if (infos.isNotEmpty) {
      final joined = infos.join('; ');
      _product.parameters = clean.isEmpty ? joined : '$clean; $joined';
    } else {
      _product.parameters = clean;
    }
    if (sharedInfo.isNotEmpty) {
      _product.parameters = _product.parameters.isEmpty
          ? '$_paintInfoParamLabel $sharedInfo'
          : '${_product.parameters}; $_paintInfoParamLabel $sharedInfo';
    }

    // 4) Перезаписываем таблицу order_paints
    if (orderId.trim().isEmpty) return;
    try {
      final repo = OrdersRepository();
      await repo.saveOrderPaints(orderId: orderId, paints: rows);
      try {
        await repo.syncPaintReservations(
          orderId: orderId,
          paints: rows,
          actor: AuthHelper.currentUserName ?? '',
        );
      } catch (e) {
        // Ошибки резервирования (недостаток краски, краска не найдена) не
        // блокируют сохранение заказа — только сообщаем пользователю.
        final message = _describeSaveError(e);
        debugPrint('⚠️ syncPaintReservations error: $message');
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(message)),
          );
        }
      }
      // Сохраняем актуальные product.parameters даже когда красок нет:
      // в этом случае "Информация для красок" должна оставаться в заказе.
      await _sb.from('orders').update({
        'product': _product.toMap(),
      }).eq('id', orderId);
    } catch (e) {
      final message = _describeSaveError(e);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(message)),
        );
      }
      debugPrint('❌ persist paints error: $e');
      rethrow;
    }
  }

  /// Пробует восстановить краски из order_paints; если пусто - из product.parameters (как раньше).
  Future<void> _restorePaints(WarehouseProvider warehouse) async {
    if (_paintsRestored) return;
    try {
      if (widget.order != null) {
        final orderId = widget.order!.id;
        final repo = OrdersRepository();
        final items = await repo.getPaints(orderId);
        if (items.isNotEmpty) {
          final restored = <_PaintEntry>[];
          for (final it in items) {
            final name = (it['name'] ?? '').toString().trim();
            final qtyRaw = it['qty_kg'];
            final qtyKg = (qtyRaw is num)
                ? qtyRaw.toDouble()
                : double.tryParse('$qtyRaw');
            final grams = qtyKg == null ? null : qtyKg * 1000;
            final memo = (it['info'] ?? '').toString();
            final tmc = warehouse.getPaintByName(name);
            if (tmc != null) {
              restored.add(_PaintEntry(
                  tmc: tmc,
                  name: tmc.description,
                  qtyGrams: grams,
                  memo: memo));
            } else {
              // В редком случае, если номенклатуры уже нет - просто с текстом.
              restored
                  .add(_PaintEntry(name: name, qtyGrams: grams, memo: memo));
            }
          }
          final sharedInfo = _deriveSharedPaintInfo(restored);
          setState(() {
            _paints
              ..clear()
              ..addAll(restored.isNotEmpty ? restored : _paints);
            _paintInfo = sharedInfo;
            for (final paint in _paints) {
              paint.memo = sharedInfo;
            }
            _paintInfoController.value = TextEditingValue(
              text: sharedInfo,
              selection: TextSelection.collapsed(offset: sharedInfo.length),
            );
            _paintsRestored = true;
          });
          _handlePaintsChanged();
          _validatePaintNames();
          return;
        }
      }
    } catch (e) {
      debugPrint('❌ restore paints from DB error: ' + e.toString());
    }
    // Фолбэк к старому парсеру parameters
    _restorePaintsFromParams(warehouse);
  }

  Future<void> _loadSavedOrderPdfs() async {
    // При редактировании — файлы самого заказа; в черновике возобновления —
    // файлы исходного заказа: тот же источник, из которого сохранение
    // копирует order_files на новый id (см. restartSourceId в _saveOrder).
    final String sourceOrderId = widget.order?.id ??
        (widget.initialOrder?.restartedFromOrderId?.trim() ?? '');
    if (sourceOrderId.isEmpty) return;
    setState(() => _loadingOrderPdfs = true);
    try {
      final files = await listOrderFiles(sourceOrderId);
      if (!mounted) return;
      setState(() {
        _savedOrderPdfs = files;
        _loadingOrderPdfs = false;
      });
    } catch (_) {
      if (mounted) setState(() => _loadingOrderPdfs = false);
    }
  }

  Future<void> _pickPdf() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['pdf'],
      allowMultiple: true,
      withData: true,
    );
    if (result != null && result.files.isNotEmpty) {
      setState(() {
        _pickedOrderPdfs.addAll(result.files);
      });
    }
  }

  Future<bool> _confirmDeletePdf(String fileName, {String? message}) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dCtx) => AlertDialog(
        title: const Text('Удалить файл?'),
        content: Text(message ?? 'Файл "$fileName" будет удалён безвозвратно.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dCtx, false),
            child: const Text('Отмена'),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
            onPressed: () => Navigator.pop(dCtx, true),
            child: const Text('Удалить'),
          ),
        ],
      ),
    );
    return confirmed == true;
  }

  Future<void> _openPdfBytes(Uint8List bytes, String title) async {
    if (!mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => PdfViewScreen(
          bytes: bytes,
          title: title.isEmpty ? 'PDF' : title,
        ),
      ),
    );
  }

  Future<void> _openSavedPdf(Map<String, dynamic> file) async {
    final objectPath = (file['objectPath'] ?? '').toString();
    if (objectPath.isEmpty) return;
    final fileName = (file['filename'] ?? objectPath.split('/').last).toString();
    final url = await getSignedUrl(objectPath);
    if (!mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => PdfViewScreen(url: url, title: fileName),
      ),
    );
  }

  Future<void> _removeSavedOrderPdf(Map<String, dynamic> file) async {
    final fileName =
        (file['filename'] ?? file['objectPath'] ?? 'Файл.pdf').toString();
    // Черновик (заказ ещё не создан): файлы в списке принадлежат исходному
    // архивному заказу. Удаление — только локальная пометка «не переносить»;
    // этот путь физически не ходит в Storage/order_files, чтобы закрытие
    // черновика без сохранения не могло испортить архивный заказ.
    final bool isUnsavedDraft = widget.order == null;
    final confirmed = await _confirmDeletePdf(
      fileName,
      message: isUnsavedDraft
          ? 'Файл "$fileName" не будет перенесён в новый заказ. '
              'В исходном (архивном) заказе он останется.'
          : null,
    );
    if (!confirmed) return;
    final objectPath = (file['objectPath'] ?? '').toString();
    if (isUnsavedDraft) {
      if (mounted) {
        setState(() {
          if (objectPath.trim().isNotEmpty) {
            _draftRemovedOrderPdfPaths.add(objectPath.trim());
          }
          _savedOrderPdfs.remove(file);
        });
      }
      return;
    }
    if (objectPath.isEmpty) return;
    try {
      await deleteOrderFile(objectPath);
      if (mounted) setState(() => _savedOrderPdfs.remove(file));
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Не удалось удалить файл: $e')),
        );
      }
    }
  }

  /// Удаляет файл, пришедший от печатной формы.
  ///
  /// Раньше такие файлы были в заказе только для чтения — «удалять их нужно в
  /// модуле Формы». На деле кладовщик прикладывает PDF к форме на складе, а
  /// замечает ошибку уже в заказе, и путь «закрой заказ, найди форму, удали,
  /// вернись» никто не проходил: файл оставался висеть.
  ///
  /// Поэтому удаление есть, но ПОСЛЕДСТВИЕ названо прямо в подтверждении —
  /// оно разное у двух источников:
  ///   * `source = 'form'` — файл лежит в самой форме и исчезнет во ВСЕХ
  ///     заказах, где эта форма используется;
  ///   * `source = 'order'` — это ссылка на файл другого заказа; снимется
  ///     только связь с формой, сам файл останется у своего заказа.
  Future<void> _removeFormPdf(Map<String, dynamic> file) async {
    final fileName =
        (file['filename'] ?? file['objectPath'] ?? 'Файл.pdf').toString();
    final source = (file['source'] ?? 'form').toString();
    final confirmed = await _confirmDeletePdf(
      fileName,
      message: source == 'order'
          ? 'Файл "$fileName" принадлежит другому заказу. Здесь снимется '
              'только его связь с формой — сам файл останется в своём заказе.'
          : 'Файл "$fileName" загружен в саму печатную форму. Он исчезнет '
              'во ВСЕХ заказах, где используется эта форма. Отменить нельзя.',
    );
    if (!confirmed) return;
    try {
      await deleteFormFile(file);
      if (mounted) setState(() => _oldFormSavedPdfs.remove(file));
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Не удалось удалить файл формы: $e')),
        );
      }
    }
  }

  /// Построчный виджет вложения PDF: иконка, имя, необязательная метка
  /// источника, кнопка "Открыть" и кнопка удаления/снятия выбора.
  Widget _buildPdfTile({
    required String name,
    String? sourceTag,
    VoidCallback? onOpen,
    VoidCallback? onRemove,
    IconData removeIcon = Icons.close,
    String removeTooltip = 'Убрать',
    Color iconColor = Colors.red,
  }) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        children: [
          Icon(Icons.picture_as_pdf, size: 16, color: iconColor),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 13),
            ),
          ),
          if (sourceTag != null)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4),
              child: Text(
                sourceTag,
                style: const TextStyle(fontSize: 11, color: Colors.grey),
              ),
            ),
          if (onOpen != null)
            IconButton(
              tooltip: 'Открыть',
              icon: const Icon(Icons.open_in_new, size: 16),
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(),
              onPressed: onOpen,
            ),
          if (onRemove != null)
            IconButton(
              tooltip: removeTooltip,
              icon: Icon(removeIcon, size: 16, color: Colors.red),
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(),
              onPressed: onRemove,
            ),
        ],
      ),
    );
  }

  Future<void> _pickOrderDate(BuildContext context) async {
    final initial = _orderDate ?? DateTime.now();
    final picked = await showDatePicker(
      context: context,
      initialDate: initial,
      firstDate: DateTime(2000),
      lastDate: DateTime(2100),
    );
    if (picked != null) {
      setState(() {
        _orderDate = picked;
        // Если дата выполнения меньше даты заказа - корректируем
        if (_dueDate != null && _dueDate!.isBefore(picked)) {
          _dueDate = picked;
        }
      });
    }
  }

  Future<void> _pickDueDate(BuildContext context) async {
    final initial = _dueDate ?? (_orderDate ?? DateTime.now());
    final picked = await showDatePicker(
      context: context,
      initialDate: initial,
      firstDate: _orderDate ?? DateTime(2000),
      lastDate: DateTime(2100),
    );
    if (picked != null) {
      setState(() {
        _dueDate = picked;
      });
    }
  }

  // Возвращает список бумажных TMC (пытаемся разными способами, без чувствительности к регистру)
  List<TmcModel> _paperItems() {
    if (!mounted) {
      return <TmcModel>[];
    }
    final wp = Provider.of<WarehouseProvider>(context, listen: false);
    final Map<String, TmcModel> uniq = {};
    // 1) Попробуем штатный метод провайдера с разными ключами
    final keys = <String>['бумага', 'Бумага', 'paper', 'Paper'];
    for (final k in keys) {
      try {
        final list = wp.getTmcByType(k);
        for (final t in list) {
          uniq[t.id] = t;
        }
      } catch (_) {}
    }
    // 2) Если всё ещё пусто - просмотрим allTmc по типу
    if (uniq.isEmpty) {
      for (final t in wp.allTmc) {
        final ty = (t.type ?? '').toString().toLowerCase();
        if (ty.contains('бумага') || ty.contains('paper')) {
          uniq[t.id] = t;
        }
      }
    }
    return uniq.values.toList();
  }

  // Пытаемся найти бумагу по введённым в полях значениям (без обязательного выбора из списка)
  TmcModel? _resolvePaperByText() {
    final name = (_matSelectedName ?? _matNameCtl.text).trim();
    final fmt = (_matSelectedFormat ?? _matFormatCtl.text).trim();
    final gram = (_matSelectedGrammage ?? _matGramCtl.text).trim();
    if (name.isEmpty || fmt.isEmpty || gram.isEmpty) return null;
    for (final t in _paperItems()) {
      if (t.description.trim().toLowerCase() == name.toLowerCase() &&
          (t.format ?? '').trim().toLowerCase() == fmt.toLowerCase() &&
          (t.grammage ?? '').trim().toLowerCase() == gram.toLowerCase()) {
        return t;
      }
    }
    return null;
  }

  double? _currentAvailablePaperQty() {
    if (!mounted) {
      return null;
    }
    TmcModel? tmc = _selectedMaterialTmc ?? _resolvePaperByText();
    if (tmc == null) {
      // Попробуем найти по выбранному в каскаде триплету
      final name = _matSelectedName;
      final fmt = _matSelectedFormat;
      final gram = _matSelectedGrammage;
      if (name != null && fmt != null && gram != null) {
        for (final t in _paperItems()) {
          if (t.description.trim().toLowerCase() == name.trim().toLowerCase() &&
              (t.format ?? '').trim().toLowerCase() ==
                  fmt.trim().toLowerCase() &&
              (t.grammage ?? '').trim().toLowerCase() ==
                  gram.trim().toLowerCase()) {
            tmc = t;
            break;
          }
        }
      }
    }
    if (tmc == null) return null;
    return availablePaperQtyById(tmc.id, fallbackStock: tmc.quantity);
  }

  /// Доступный остаток бумаги: склад минус брони ЧУЖИХ заказов.
  ///
  /// Складскую цифру показывать нельзя — занятое соседями взять всё равно не
  /// получится, и менеджер планировал бы по метрам, которых у него нет.
  /// Собственная бронь заказа из вычета исключается: свои метры ему доступны.
  ///
  /// `null` возвращается только когда бумаги нет в справочнике; ещё не
  /// приехавший кэш броней даёт складскую цифру, а не пустоту.
  double? availablePaperQtyById(String? paperId, {double? fallbackStock}) {
    if (!mounted) return null;
    final id = (paperId ?? '').trim();
    if (id.isEmpty) return null;
    final wp = Provider.of<WarehouseProvider>(context, listen: false);

    double? stock = fallbackStock;
    for (final t in wp.allTmc) {
      if (t.id == id) {
        stock = t.quantity;
        break;
      }
    }
    if (stock == null) return null;

    final reservedByOthers = wp.cachedPaperReservedQty(
      id,
      excludeOrderId: widget.order?.id,
    );
    if (reservedByOthers == null) return stock;
    final available = stock - reservedByOthers;
    return available < 0 ? 0 : available;
  }

  /// Подпись «сколько доступно» — внутри карточки самой бумаги.
  ///
  /// Общий список под заголовком «Склад и материалы» показывал все бумаги
  /// сразу, и сопоставлять строку списка со слотом приходилось глазами. Цифра
  /// принадлежит конкретной бумаге, поэтому и живёт рядом с её полями.
  /// Не хватает ли доступного метража под введённую «Длину L».
  ///
  /// Сравнение идёт с доступным (склад минус брони ЧУЖИХ заказов), а не со
  /// складским остатком: обещанные соседям метры этому заказу не достанутся, и
  /// узнать об этом менеджер должен в поле, а не из статуса «Ожидание
  /// материалов» после сохранения. Собственную бронь заказа
  /// [availablePaperQtyById] не вычитает — иначе при открытии сохранённого
  /// заказа его же метры выглядели бы занятыми.
  bool _paperLengthExceedsAvailable(TmcModel? paper, double? length) {
    if (paper == null || length == null || length <= 0) return false;
    final available =
        availablePaperQtyById(paper.id, fallbackStock: paper.quantity) ??
            paper.quantity;
    return length > available;
  }

  /// Строка блока бумаг: подпись слева, карточка материала справа.
  ///
  /// «Доступно» живёт в левой колонке — там же, где подпись «Склад и
  /// материалы». Эта колонка и так пустует под подписью, поэтому цифра ничего
  /// не отнимает у полей материала: они и без того тесные, надписи «Ширина b»,
  /// «Количество», «Длина L» обрезаются до «Ши…», «Ко…», «Дл…». Внутри
  /// карточки цифра стояла как раз за счёт этой ширины.
  Widget _paperGutterRow({
    required double labelWidth,
    required Widget card,
    String? label,
    double? availableQty,
  }) {
    final gutter = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (label != null)
          Text(
            label,
            style: const TextStyle(
              fontSize: 12,
              color: OrderFormColors.label,
            ),
          ),
        if (availableQty != null) ...[
          if (label != null) const SizedBox(height: 2),
          Text(
            'Доступно: ${availableQty.toStringAsFixed(2)} м',
            style: const TextStyle(
              fontSize: 11,
              height: 1.15,
              color: OrderFormColors.muted,
            ),
          ),
        ],
      ],
    );

    return LayoutBuilder(
      builder: (context, constraints) {
        // На узкой раскладке колонка подписи съела бы всю ширину полей —
        // ту же защиту держит _buildLabelRow. Тогда подпись уходит над
        // карточкой, как и у остальных строк формы.
        if (constraints.maxWidth < labelWidth + 160) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Align(alignment: Alignment.centerLeft, child: gutter),
              const SizedBox(height: 4),
              card,
            ],
          );
        }
        return Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: labelWidth,
              child: Padding(
                padding: const EdgeInsets.only(right: 8, top: 6),
                child: gutter,
              ),
            ),
            Expanded(child: card),
          ],
        );
      },
    );
  }

  bool _matchesWarehouseQuery(String query, Iterable<String> fields) {
    final normalized = query.trim().toLowerCase();
    if (normalized.isEmpty) return true;
    final searchable = fields.map((field) => field.toLowerCase()).join(' ');
    final tokens = normalized
        .split(RegExp(r'[\s,;]+'))
        .where((token) => token.isNotEmpty)
        .toList();

    return tokens.every((token) => searchable.contains(token));
  }

  /// --- Helpers for idempotent write-offs ---

  /// Build a map of previous paints {name -> qty_g}
  Future<Map<String, double>> _loadPreviousPaints(String orderId) async {
    try {
      final repo = OrdersRepository();
      final rows = await repo.getPaints(orderId);
      final Map<String, double> prev = {};
      for (final r in rows) {
        final name = (r['name'] ?? '').toString().trim();
        final qv = r['qty_kg'];
        final qKg =
            (qv is num) ? qv.toDouble() : double.tryParse('${qv ?? ''}');
        if (name.isNotEmpty && qKg != null) {
          prev[name.toLowerCase()] = qKg * 1000;
        }
      }
      return prev;
    } catch (_) {
      return {};
    }
  }

  /// Update product.parameters with single line for pens so we can diff next time.
  void _upsertPensInParameters(String penName) {
    final re =
        RegExp(r'(?:^|;\s*)Ручки:\s*.+?(?=(?:;|$))', caseSensitive: false);
    var p = _product.parameters;
    p = p.replaceAll(re, '').trim();
    if (p.isNotEmpty && !p.trim().endsWith(';')) p = p + '; ';
    if (penName.trim().isNotEmpty) {
      p = p + 'Ручки: ' + penName.trim();
    }
    _product.parameters = p.trim();
  }

  String _extractPackagingFromParams(List<String> params) {
    for (final param in params) {
      final normalized = param.trim();
      if (normalized.toLowerCase().startsWith('упаковка:')) {
        return normalized.substring('Упаковка:'.length).trim();
      }
    }
    return '';
  }

  /// Resolve a real record before any order writes or closing the editor.
  /// Display text is never parsed for numbers: names can contain digits.
  Future<bool> _prepareExistingFormForSave() async {
    if (!_hasForm || !_isOldForm) return true;
    final selectedId = _selectedOldFormRow?['id']?.toString();
    final unchanged = !_editingForm ||
        _selectedOldForm == _editingFormInitialText;
    final id = await findFormIdByOrderFormRef(
      formId: selectedId ?? (unchanged ? _orderFormId : null),
      formCode: unchanged ? _orderFormCode : _selectedOldForm,
      formSeries: unchanged ? _orderFormSeries : null,
      formNo: unchanged ? _orderFormNo : null,
    );
    if (!mounted) return false;
    if (id == null) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('Выберите существующую форму из списка склада'),
      ));
      return false;
    }
    final row = await _sb.from('forms').select().eq('id', id).single();
    if (!mounted) return false;
    _selectedOldFormRow = Map<String, dynamic>.from(row);
    return true;
  }

  Future<void> _saveOrder() async {
    if (_isSavingOrder) return;
    final sourceOrder = widget.order ?? _createdDuringSave;
    setState(() => _isSavingOrder = true);
    try {
    await (widget.lease ?? _createdLease)?.ensureOwned();
    // Флаг: создаём новый заказ или редактируем
    final bool isCreating = (sourceOrder == null);
    final messenger = ScaffoldMessenger.of(context);
    if (!_formKey.currentState!.validate()) return;
    if (!await _prepareExistingFormForSave()) return;
    _selectedCardboard = _cardboardChecked ? 'есть' : 'нет';
    final params = {..._selectedParams};
    if (_trimming) {
      params.add('Подрезка');
    } else {
      params.remove('Подрезка');
    }
    params.removeWhere(
      (value) => value.trim().toLowerCase().startsWith('упаковка:'),
    );
    final packaging = _packagingController.text.trim();
    if (packaging.isNotEmpty) {
      params.add('Упаковка: $packaging');
    }
    _selectedParams = params.toList();
    if (_orderDate == null) {
      if (mounted)
        messenger.showSnackBar(
          const SnackBar(content: Text('Укажите дату заказа')),
        );
      return;
    }
    if (_dueDate == null) {
      if (mounted)
        messenger.showSnackBar(
          const SnackBar(content: Text('Укажите срок выполнения')),
        );
      return;
    }
    _validatePaintNames();
    // Краска, которой нет на складе, сохранение больше НЕ отменяет.
    //
    // Раньше форма упиралась: «Данной краски нет на складе. Уточните
    // название» — и заказ нельзя было ни сохранить, ни поставить в очередь на
    // закупку. Менеджеру приходилось либо выдумывать похожую краску, либо
    // держать заказ у себя, пока снабженец не заведёт карточку. Теперь такой
    // заказ сохраняется и уходит в «Ожидание материалов» с фиолетовой
    // карточкой, где написано, сколько краски заказать (потребность +
    // неприкасаемый запас), и есть кнопка «Завести краску».
    final unknownPaints = _paints
        .where((p) => p.nameNotFound)
        .map((p) => p.displayName.trim())
        .where((name) => name.isNotEmpty)
        .toList(growable: false);
    final managerName = sourceOrder != null
        ? sourceOrder.manager
        : (_selectedManager?.trim().isNotEmpty ?? false)
            ? _selectedManager!.trim()
            : '';
    final penName =
        _selectedHandleDescription == '-' ? '' : _selectedHandleDescription;
    _upsertPensInParameters(penName);
    final provider = Provider.of<OrdersProvider>(context, listen: false);
    final warehouse = Provider.of<WarehouseProvider>(context, listen: false);
    // Бумага хранится динамическим списком без жёсткого лимита.
    final List<MaterialModel> selectedPapers = _collectSelectedPapers();
    final currentQueueSignature = _currentQueueSignature();
    var nextQueueBuildStatus = _queueBuildStatus;
    if (isCreating &&
        nextQueueBuildStatus != QueueBuildStatus.built &&
        nextQueueBuildStatus != QueueBuildStatus.outdated) {
      nextQueueBuildStatus = QueueBuildStatus.notBuilt;
    } else if (!isCreating &&
        sourceOrder?.queueBuildStatus == QueueBuildStatus.built &&
        !_sameQueueSignature(
            sourceOrder?.queueSignature, currentQueueSignature)) {
      nextQueueBuildStatus = QueueBuildStatus.outdated;
    }

    // Заказ с уже собранной очередью: правки применяются целиком, включая
    // смену типа продукта. Очередь пересобираем сами — требовать ручного
    // нажатия «Собрать очередь» здесь нельзя, иначе заказ сохранился бы с
    // новым типом продукта, но со старым маршрутом этапов.
    //
    // Раньше авто-пересборка работала только для запущенных заказов. Из-за
    // этого правка заказа в статусе «Готов к запуску» или «Ожидание
    // материалов» роняла его в черновик: подпись очереди менялась, статус
    // становился outdated, очередь не сохранялась — и приходилось сохранять
    // второй раз, чтобы заказ вернулся на место. Признак тот же: очередь у
    // заказа уже была собрана, значит маршрут менеджер видел и подтверждал.
    final bool hadBuiltQueue =
        sourceOrder?.queueBuildStatus == QueueBuildStatus.built;
    if (!isCreating &&
        ((sourceOrder?.assignmentCreated ?? false) || hadBuiltQueue) &&
        nextQueueBuildStatus != QueueBuildStatus.built) {
      _buildStageQueue();
      nextQueueBuildStatus = QueueBuildStatus.built;
    }
    if (nextQueueBuildStatus == QueueBuildStatus.built) {
      _syncSwitchableStageSelectionFields(_stagePreviewStages);
    }
    bool hasEnoughPaperForLaunch() {
      if (selectedPapers.isEmpty) return true;
      // Склад ещё не подтянулся — не выносим приговор «нет материала» по
      // пустому списку. Сразу после сохранения OrdersProvider перепроверит
      // остаток запросом в базу и поставит верный статус.
      if (warehouse.allTmc.isEmpty) return true;
      for (final paper in selectedPapers) {
        final paperId = (paper.id ?? '').trim();
        final double need = paper.quantity > 0
            ? paper.quantity
            : (_product.length ?? 0).toDouble();
        if (paperId.isEmpty || need <= 0) {
          continue;
        }
        final current = warehouse.allTmc.where((t) => t.id == paperId).toList();
        if (current.isEmpty) return false;
        final availableQty = current.first.quantity;
        if (need > availableQty) return false;
      }
      return true;
    }

    /// Хватает ли краски — по тем же правилам, что и на сервере.
    ///
    /// Считаем прямо здесь, чтобы карточка не мигала: без этой проверки заказ
    /// с ненайденной краской сначала сохранялся «Готов к запуску», и только
    /// следующий за сохранением `applyMaterialAvailability` опускал его в
    /// «Ожидание материалов».
    bool hasEnoughPaintForLaunch() {
      if (warehouse.allTmc.isEmpty) return true;
      for (final row in _paints) {
        final name = row.displayName.trim();
        final need = row.qtyGrams ?? 0;
        if (name.isEmpty || need <= 0) continue;
        // Краски нет в справочнике — обеспечить заказ нечем.
        if (row.tmc == null) return false;
        if (_gramsToStockUnit(need, row.tmc!) > _paintAvailableQty(row.tmc!)) {
          return false;
        }
      }
      return true;
    }

    final bool wasAlreadyLaunched = sourceOrder?.assignmentCreated ?? false;
    if (wasAlreadyLaunched) {
      await _loadRuntimeEditLocks();
    }
    // Запущенный заказ больше не снимается с производства только из-за
    // редактирования очереди. OrderQueueSyncService точечно обновляет pending
    // этапы/задачи и блокирует только изменение защищённых этапов.
    // Очередь сохраняем только после явного нажатия «Собрать очередь».
    // Если очередь не собрана или устарела, заказ остаётся черновиком и не
    // может быть запущен.
    final bool willSaveBuiltStageQueue =
        nextQueueBuildStatus == QueueBuildStatus.built;
    final stageMaps = willSaveBuiltStageQueue
        ? _currentBuiltStageMapsForSave()
        : <Map<String, dynamic>>[];
    final bool hasEffectiveStageQueue =
        willSaveBuiltStageQueue && stageMaps.isNotEmpty;
    if (hasEffectiveStageQueue) {
      _syncSwitchableStageSelectionFields(stageMaps);
    }
    final bool hasQueueForStatus = hasEffectiveStageQueue;
    // Форма есть, а краска не выбрана — заказ печатать нечем. Это не нехватка
    // на складе: докупать нечего, пока менеджер не назовёт краску. Правило —
    // paintSelectionMissing, пересчёт в OrdersProvider повторяет его по
    // сохранённому составу.
    final bool paintNotSelected = paintSelectionMissing(
      hasForm: _hasForm,
      paintLineCount:
          _paints.where((p) => p.displayName.trim().isNotEmpty).length,
    );
    final bool hasEnoughMaterialsForQueue = !paintNotSelected &&
        hasEnoughPaperForLaunch() &&
        hasEnoughPaintForLaunch();

    // Бумага без «Длины L» и краска без граммовки — незаконченный заказ, а не
    // нехватка на складе: такой заказ сохраняется черновиком. Раньше пустое
    // количество читалось всеми проверками как «нехватки нет», и заказ уходил
    // в «Готов к запуску», не проверив материал ни разу. Правило и его разбор —
    // в materialsWithoutQuantity.
    final List<String> materialsMissingQuantity = materialsWithoutQuantity(
      papers: selectedPapers,
      paints: _paints.map(
        (paint) => OrderPaintLine(
          name: paint.displayName,
          qtyGrams: paint.qtyGrams,
        ),
      ),
    );
    final bool materialDataComplete = materialsMissingQuantity.isEmpty;

    final bool canLaunchProductionNow =
        hasQueueForStatus && hasEnoughMaterialsForQueue && materialDataComplete;
    final String nextOrderStatus = wasAlreadyLaunched
        ? sourceOrder!.status
        : ((!hasQueueForStatus || !materialDataComplete)
            ? OrderStatus.draft.name
            : (canLaunchProductionNow
                ? OrderStatus.ready_to_start.name
                : OrderStatus.waiting_materials.name));
    final bool nextHasMaterialShortage = wasAlreadyLaunched
        ? sourceOrder!.hasMaterialShortage
        : (hasQueueForStatus &&
            materialDataComplete &&
            !hasEnoughMaterialsForQueue);
    // Текст нехватки для ненайденной краски пишем сразу и подробно: сколько
    // и чего заказать. Общая фраза «недостаточно материала» снабженцу
    // бесполезна — по ней не понять ни краски, ни граммов.
    final String unknownPaintMessage = unknownPaints.isEmpty
        ? ''
        : unknownPaints.map((name) {
            final row = _paints.firstWhere(
              (p) => p.displayName.trim() == name,
              orElse: () => _PaintEntry(name: name),
            );
            return missingPaintShortageMessage(
              paintName: name,
              neededGrams: row.qtyGrams ?? 0,
            );
          }).join(' ');

    final String shortageMessage = wasAlreadyLaunched
        ? sourceOrder!.materialShortageMessage
        : (!hasQueueForStatus || !materialDataComplete
            ? ''
            : (hasEnoughMaterialsForQueue
                ? ''
                : (paintNotSelected
                    ? kPaintNotSelectedShortageMessage
                    : (unknownPaintMessage.isNotEmpty
                        ? unknownPaintMessage
                        : 'Недостаточно материала на складе. Пополните склад и запустите заказ вручную.'))));

    // Сообщаем до pop: экран закрывается сразу, а SnackBar живёт в корневом
    // ScaffoldMessenger и доедет до списка заказов. Молча уронить заказ в
    // черновик нельзя — менеджер не поймёт, почему он не запускается.
    if (!wasAlreadyLaunched && unknownPaints.isNotEmpty && mounted) {
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            'Заказ сохранён и ждёт материалов: '
            '${unknownPaints.length == 1 ? 'краски' : 'красок'} '
            '${unknownPaints.map((n) => '«$n»').join(', ')} нет на складе.',
          ),
          duration: const Duration(seconds: 6),
        ),
      );
    }
    if (!wasAlreadyLaunched && !materialDataComplete && mounted) {
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            'Заказ сохранён черновиком: не указано количество — '
            '${materialsMissingQuantity.join(', ')}.',
          ),
          duration: const Duration(seconds: 6),
        ),
      );
    }

    // Keep the editor and its lease alive through every save operation.
    late OrderModel createdOrUpdatedOrder;
    if (sourceOrder == null) {
      // создаём новый заказ
      final _created = await provider.createOrder(
        manager: managerName,
        customer: _customerController.text.trim(),
        orderDate: _orderDate!,
        dueDate: _dueDate,
        product: _product,
        additionalParams: _selectedParams,
        handle: _selectedHandleDescription == '-'
            ? '-'
            : _selectedHandleDescription,
        cardboard: _selectedCardboard,
        // Не `_selectedMaterial`: он приходит из панели склада без метража и
        // с единицей «шт». Первая позиция selectedPapers — та же бумага, но
        // уже с «Длиной L» и в метрах. Раньше в orders.material улетало
        // quantity = 0, и все экраны, читающие это поле, показывали ноль,
        // хотя в material_list лежало правильное количество.
        material: selectedPapers.isNotEmpty
            ? selectedPapers.first
            : _selectedMaterial,
        paperMaterials: selectedPapers,
        makeready: _makeready,
        val: _val,
        // Возобновление из архива: PDF-ссылка исходного заказа переносится
        // в новое поколение (сам файл в Storage не копируется).
        pdfUrl: widget.initialOrder?.pdfUrl,
        stageTemplateId: _stageTemplateId,
        hasForm: _hasForm,
        formId: _hasForm
            ? (_selectedOldFormRow?['id']?.toString() ??
                (!_editingForm ? _orderFormId : null))
            : null,
        isOldForm: _isOldForm,
        // Временно отключено в форме создания/редактирования заказа.
        contractSigned: false,
        paymentDone: false,
        comments: _commentsController.text.trim(),
        status: nextOrderStatus,
        queueBuildStatus: nextQueueBuildStatus,
        selectedVStage: _persistedSelectedVStage(nextQueueBuildStatus),
        selectedPStage: _persistedSelectedPStage(nextQueueBuildStatus),
        queueSignature: nextQueueBuildStatus == QueueBuildStatus.notBuilt
            ? null
            : currentQueueSignature,
        restartedFromOrderId: widget.initialOrder?.restartedFromOrderId,
        restartRootOrderId: widget.initialOrder?.restartRootOrderId,
        restartGeneration: widget.initialOrder?.restartGeneration ?? 0,
        productTypeId: _currentProductTypeId(),
        extraOptions: _extraOptionsForPersist(),
      );
      if (_created == null) {
        _showBackgroundSaveSnackBar('Не удалось создать заказ', isError: true);
        return;
      }
      createdOrUpdatedOrder = _created;
      if (widget.order == null) _createdDuringSave = createdOrUpdatedOrder;
      _createdDuringSave = _created;
      // Заказ уже вставлен в базу. Второго редактора у только что созданного
      // заказа быть не может, поэтому неудачный захват (нет серверных функций,
      // оборвалась сеть) не должен прерывать сохранение: краски, файлы, форма
      // и очередь пишутся следующими шагами, и без них заказ остался бы
      // наполовину записанным.
      final createdLease = OrderEditLease(_created.id);
      var leaseAcquired = false;
      try {
        leaseAcquired =
            await createdLease.acquire() == OrderEditLeaseStatus.acquired;
      } catch (e) {
        debugPrint('❌ order edit lease: не удалось занять новый заказ: $e');
      }
      if (leaseAcquired) {
        _createdLease = createdLease;
      } else {
        createdLease.dispose();
      }
      // Возобновление из архива: переносим метаданные PDF-файлов исходного
      // заказа на новый order id. Объекты в Storage не дублируются —
      // используются те же objectPath (компромисс: удаление файла в одном
      // поколении удаляет объект и для другого).
      final restartSourceId =
          widget.initialOrder?.restartedFromOrderId?.trim() ?? '';
      if (restartSourceId.isNotEmpty) {
        try {
          final sourceFiles = await listOrderFiles(restartSourceId);
          for (final file in sourceFiles) {
            final objectPath = (file['objectPath'] ?? '').toString().trim();
            if (objectPath.isEmpty) continue;
            // Пользователь исключил файл в черновике — не переносим на новый
            // заказ. Сам файл архивного заказа остаётся нетронутым.
            if (_draftRemovedOrderPdfPaths.contains(objectPath)) continue;
            final fileName =
                (file['filename'] ?? '').toString().trim().isNotEmpty
                    ? (file['filename'] ?? '').toString().trim()
                    : objectPath.split('/').last;
            final sizeRaw = file['sizeBytes'];
            await linkOrderPdf(
              orderId: createdOrUpdatedOrder.id,
              objectPath: objectPath,
              fileName: fileName,
              sizeBytes: sizeRaw is num ? sizeRaw.toInt() : null,
            );
          }
        } catch (e) {
          debugPrint('❌ resume: copy order files failed: $e');
        }
      }
    } else {
      final bool effectivePersistedHasForm = (_orderFormNo != null) ||
          (_orderFormCode != null && _orderFormCode!.trim().isNotEmpty) ||
          ((_orderFormIsOld != null) &&
              ((_orderFormNo != null) ||
                  (_orderFormCode != null &&
                      _orderFormCode!.trim().isNotEmpty))) ||
          sourceOrder.hasForm;
      final bool effectivePersistedIsOldForm =
          _orderFormIsOld ?? sourceOrder.isOldForm;
      final int? effectivePersistedFormNo =
          _orderFormNo ?? sourceOrder.newFormNo;
      final String? effectivePersistedFormSeries =
          _orderFormSeries ?? sourceOrder.formSeries;
      final String? effectivePersistedFormCode =
          _orderFormCode ?? sourceOrder.formCode;

      final List<MaterialModel> oldPapers =
          sourceOrder.paperMaterials.isNotEmpty
              ? sourceOrder.paperMaterials
              : <MaterialModel>[
                  if (sourceOrder.material != null) sourceOrder.material!,
                ];
      final bool paperChanged = oldPapers.length != selectedPapers.length ||
          oldPapers.asMap().entries.any((entry) {
            final idx = entry.key;
            final old = entry.value;
            final next = selectedPapers[idx];
            return old.id != next.id ||
                (old.quantity - next.quantity).abs() > 0.0001;
          });
      // обновляем существующий заказ, сохраняя assignmentId/assignmentCreated
      final updated = OrderModel(
        id: sourceOrder.id,
        manager: managerName,
        customer: _customerController.text.trim(),
        orderDate: _orderDate!,
        dueDate: _dueDate,
        product: _product,
        additionalParams: _selectedParams,
        handle: _selectedHandleDescription == '-'
            ? '-'
            : _selectedHandleDescription,
        cardboard: _selectedCardboard,
        // Не `_selectedMaterial`: он приходит из панели склада без метража и
        // с единицей «шт». Первая позиция selectedPapers — та же бумага, но
        // уже с «Длиной L» и в метрах. Раньше в orders.material улетало
        // quantity = 0, и все экраны, читающие это поле, показывали ноль,
        // хотя в material_list лежало правильное количество.
        material: selectedPapers.isNotEmpty
            ? selectedPapers.first
            : _selectedMaterial,
        paperMaterials: selectedPapers,
        makeready: _makeready,
        val: _val,
        pdfUrl: sourceOrder.pdfUrl,
        stageTemplateId: _stageTemplateId,
        // На этапе базового сохранения не перетираем уже привязанную форму.
        // Фактическая запись формы всегда выполняется позже в _processFormAssignment.
        hasForm: effectivePersistedHasForm,
        isOldForm: effectivePersistedIsOldForm,
        newFormNo: effectivePersistedFormNo,
        formSeries: effectivePersistedFormSeries,
        formCode: effectivePersistedFormCode,
        formId: _selectedOldFormRow?['id']?.toString() ??
            _orderFormId ?? sourceOrder.formId,
        // Временно отключено в форме создания/редактирования заказа.
        contractSigned: false,
        paymentDone: false,
        comments: _commentsController.text.trim(),
        status: nextOrderStatus,
        hasMaterialShortage: nextHasMaterialShortage,
        materialShortageMessage: shortageMessage,
        assignmentId: sourceOrder.assignmentId,
        assignmentCreated: sourceOrder.assignmentCreated,
        queueBuildStatus: nextQueueBuildStatus,
        selectedVStage: _persistedSelectedVStage(nextQueueBuildStatus),
        selectedPStage: _persistedSelectedPStage(nextQueueBuildStatus),
        queueSignature: nextQueueBuildStatus == QueueBuildStatus.notBuilt
            ? null
            : currentQueueSignature,
        // Связи возобновления обязаны переживать пересохранение:
        // updateOrder пишет toMap(includeNulls: true), и без этих полей
        // каждый сейв затирал бы цепочку поколений в БД.
        restartedFromOrderId: sourceOrder.restartedFromOrderId,
        restartRootOrderId: sourceOrder.restartRootOrderId,
        restartGeneration: sourceOrder.restartGeneration,
        // По той же причине сохраняем данные производства/отгрузки:
        // без них пересохранение завершённого заказа обнуляло бы
        // actual_qty/shipped_* в БД.
        actualQty: sourceOrder.actualQty,
        shippedAt: sourceOrder.shippedAt,
        shippedBy: sourceOrder.shippedBy,
        shippedQty: sourceOrder.shippedQty,
        // Если тип продукта не выбран, здесь остаётся null, и toMap не кладёт
        // ключ в payload вовсе — прежнее значение колонки не затирается.
        productTypeId: _currentProductTypeId() ?? sourceOrder.productTypeId,
        // Справочник ещё не читался — ключ не уйдёт в payload, и выбранные
        // опции заказа останутся нетронутыми (см. [_extraOptionsForPersist]).
        extraOptions: _extraOptionsForPersist() ?? sourceOrder.extraOptions,
      );
      await provider.updateOrder(updated);
      createdOrUpdatedOrder = updated;
      if (widget.order == null) _createdDuringSave = createdOrUpdatedOrder;
    }

    final String effectiveNextOrderStatus = nextOrderStatus;
    if (createdOrUpdatedOrder.status != effectiveNextOrderStatus ||
        createdOrUpdatedOrder.hasMaterialShortage != nextHasMaterialShortage ||
        createdOrUpdatedOrder.materialShortageMessage != shortageMessage) {
      final normalized = createdOrUpdatedOrder.copyWith(
        status: effectiveNextOrderStatus,
        hasMaterialShortage: nextHasMaterialShortage,
        materialShortageMessage: shortageMessage,
      );
      await provider.updateOrder(normalized);
      createdOrUpdatedOrder = normalized;
      if (widget.order == null) _createdDuringSave = createdOrUpdatedOrder;
    }

    // Присвоим читаемый номер заказа (ЗК-YYYY.MM.DD-N), если ещё не присвоен
    if ((createdOrUpdatedOrder.assignmentId == null ||
            createdOrUpdatedOrder.assignmentId!.isEmpty) &&
        _orderDate != null) {
      try {
        final humanId = await provider.generateReadableOrderId(_orderDate!);
        // copyWith вместо ручной пересборки: перечисление полей теряло
        // restart_* и поля формы, а updateOrder(includeNulls: true) затирал
        // их в БД сразу после создания заказа.
        final withReadable =
            createdOrUpdatedOrder.copyWith(assignmentId: humanId);
        await provider.updateOrder(withReadable);
        createdOrUpdatedOrder = withReadable;
      if (widget.order == null) _createdDuringSave = createdOrUpdatedOrder;
      } catch (_) { rethrow; }
    }
    // Загружаем все выбранные PDF заказа при необходимости.
    // Привязка PDF к форме выполняется НЕ здесь, а после _processFormAssignment
    // (см. _syncOrderPdfsToForm): при создании заказа реквизиты формы в этот
    // момент ещё не записаны, и линковка уходила бы «в никуда».
    final bool didUploadOrderPdfs = _pickedOrderPdfs.isNotEmpty;
    if (_pickedOrderPdfs.isNotEmpty) {
      String? lastUploaded;
      for (final f in _pickedOrderPdfs) {
        try {
          lastUploaded = await uploadPickedOrderPdf(
            orderId: createdOrUpdatedOrder.id,
            file: f,
          );
        } catch (e) {
          debugPrint('❌ upload order pdf ${f.name}: $e');
          rethrow;
        }
      }
      if (lastUploaded != null) {
        createdOrUpdatedOrder.pdfUrl = lastUploaded;
        await provider.updateOrder(createdOrUpdatedOrder);
      }
      _pickedOrderPdfs = [];
      // Экран уже мог быть закрыт (фоновое сохранение) — эта загрузка нужна
      // только для обновления списка файлов на самом экране редактирования.
      if (mounted) {
        await _loadSavedOrderPdfs();
      }
    }
    if (willSaveBuiltStageQueue) {
      // Сохраняем фактическую очередь заказа через общий сервис.
      // stageTemplateId остаётся метаданным выбора в UI, а не источником истины.
      SaveBuiltQueueResult queueSaveResult;
      try {
        if (!isCreating && wasAlreadyLaunched) {
          queueSaveResult = await _orderQueueService.saveLaunchedOrderQueue(
            createdOrUpdatedOrder.id,
            stageMaps,
            <String, String?>{
              'selected_v_stage': _selectedVStage,
              'selected_p_stage': _selectedPStage,
            },
            currentQueueSignature,
            // Правки запущенного заказа сохраняем всегда: уже начатые и
            // завершённые этапы остаются как есть, обновляются ожидающие.
            force: true,
          );
        } else {
          queueSaveResult = await _orderQueueService.saveBuiltQueue(
            createdOrUpdatedOrder.id,
            stageMaps,
            <String, String?>{
              'selected_v_stage': _selectedVStage,
              'selected_p_stage': _selectedPStage,
            },
            currentQueueSignature,
          );
        }
      } on OrderQueueSyncBlockedException catch (error) {
        if (!isCreating && sourceOrder != null) {
          final restoredQueueState = createdOrUpdatedOrder.copyWith(
            stageTemplateId: sourceOrder.stageTemplateId,
            queueBuildStatus: sourceOrder.queueBuildStatus,
            selectedVStage: sourceOrder.selectedVStage,
            selectedPStage: sourceOrder.selectedPStage,
            queueSignature: sourceOrder.queueSignature,
          );
          await provider.updateOrder(restoredQueueState);
          createdOrUpdatedOrder = restoredQueueState;
      if (widget.order == null) _createdDuringSave = createdOrUpdatedOrder;
          _queueBuildStatus = sourceOrder.queueBuildStatus;
          _queueSignature = sourceOrder.queueSignature;
        }
        _showBackgroundSaveSnackBar(error.message, isError: true);
        return;
      } catch (error) {
        final failedOrder = createdOrUpdatedOrder.copyWith(
          status: isCreating
              ? OrderStatus.draft.name
              : createdOrUpdatedOrder.status,
          hasMaterialShortage:
              isCreating ? false : createdOrUpdatedOrder.hasMaterialShortage,
          materialShortageMessage:
              isCreating ? '' : createdOrUpdatedOrder.materialShortageMessage,
          stageTemplateId: !isCreating && sourceOrder != null
              ? sourceOrder.stageTemplateId
              : createdOrUpdatedOrder.stageTemplateId,
          queueBuildStatus: isCreating
              ? QueueBuildStatus.notBuilt
              : (sourceOrder?.queueBuildStatus ??
                  createdOrUpdatedOrder.queueBuildStatus),
          selectedVStage: isCreating
              ? ''
              : (sourceOrder?.selectedVStage ??
                  createdOrUpdatedOrder.selectedVStage),
          selectedPStage: isCreating
              ? ''
              : (sourceOrder?.selectedPStage ??
                  createdOrUpdatedOrder.selectedPStage),
          queueSignature: isCreating
              ? const <String, dynamic>{}
              : (sourceOrder?.queueSignature ??
                  createdOrUpdatedOrder.queueSignature),
        );
        await provider.updateOrder(failedOrder);
        if (isCreating) {
          _queueBuildStatus = QueueBuildStatus.notBuilt;
          _queueSignature = null;
        }
        _showBackgroundSaveSnackBar(
          error is OrderQueueSaveException
              ? error.message
              : '$kCreateProductionTasksFailedMessage: $error',
          isError: true,
        );
        return;
      }
      if (!queueSaveResult.productionTasksCreated) {
        final failedOrder = createdOrUpdatedOrder.copyWith(
          status: OrderStatus.draft.name,
          hasMaterialShortage: false,
          materialShortageMessage: '',
          queueBuildStatus: QueueBuildStatus.notBuilt,
          selectedVStage: '',
          selectedPStage: '',
          queueSignature: const <String, dynamic>{},
        );
        await provider.updateOrder(failedOrder);
        _queueBuildStatus = QueueBuildStatus.notBuilt;
        _queueSignature = null;
        _showBackgroundSaveSnackBar(kCreateProductionTasksFailedMessage,
            isError: true);
        return;
      }
      createdOrUpdatedOrder = createdOrUpdatedOrder.copyWith(
        queueBuildStatus: QueueBuildStatus.built,
        selectedVStage: _selectedVStage,
        selectedPStage: _selectedPStage,
        queueSignature: currentQueueSignature,
      );
      if (widget.order == null) _createdDuringSave = createdOrUpdatedOrder;
      _queueBuildStatus = QueueBuildStatus.built;
      _queueSignature = currentQueueSignature;
    }

    // Сначала синхронизируем список красок, чтобы в просмотре заказа
    // изменения были видны сразу после сохранения.
    await _persistPaints(createdOrUpdatedOrder.id);

    // Пересчёт обеспеченности ПОСЛЕ красок — иначе нехватка краски заказ не
    // останавливает.
    //
    // Бронь краски пишется в order_paint_reservations, а записать её можно
    // только зная id заказа, поэтому _persistPaints идёт последним. Проверка
    // же (_hasEnoughPaintForLaunch) читает ровно эту таблицу, и вызывалась она
    // раньше — внутри createOrder/updateOrder. У нового заказа брони там ещё
    // не было вовсе, у правленого лежала прежняя, поэтому краски не хватало,
    // а заказ уходил в «Готов к запуску». Бумага работала правильно только
    // потому, что живёт в самом заказе и сохраняется вместе с ним.
    if (!wasAlreadyLaunched) {
      await provider.applyMaterialAvailability(createdOrUpdatedOrder.id);
    }

    // === Обработка формы ===
    // _editingForm сбрасывается внутри _processFormAssignment — запоминаем
    // заранее, менялась ли форма в этом сохранении.
    final bool wasEditingForm = _editingForm;
    final String? assignedFormId = await _processFormAssignment(
      createdOrUpdatedOrder,
      isCreating: isCreating,
    );
    // Заливаем PDF, выбранные для новой формы (стейджились в памяти, т.к.
    // id формы был неизвестен до _processFormAssignment).
    if (assignedFormId != null && _newFormPdfs.isNotEmpty) {
      for (final f in _newFormPdfs) {
        try {
          await uploadPickedFormPdf(formId: assignedFormId, file: f);
        } catch (e) {
          debugPrint('❌ upload new form pdf ${f.name}: $e');
          rethrow;
        }
      }
      if (mounted) setState(() => _newFormPdfs = []);
    }
    // Двусторонняя связь: все PDF заказа должны быть видны у привязанной
    // формы (source='order'). Линкуем строго ПОСЛЕ записи реквизитов формы,
    // иначе при создании заказа форма ещё не найдена и связь терялась.
    if (assignedFormId != null &&
        (didUploadOrderPdfs || isCreating || wasEditingForm)) {
      await _syncOrderPdfsToForm(createdOrUpdatedOrder.id, assignedFormId);
    }
    // _processFormAssignment обнуляет список PDF формы — возвращаем его,
    // иначе после сохранения документы формы исчезали из открытого экрана.
    if (assignedFormId != null && mounted && _isOldForm) {
      await _loadOldFormPdfsFor(assignedFormId);
    }
    // === Конец обработки формы ===

    // _processFormAssignment пишет в БД напрямую, минуя provider.
    // Обновляем provider, чтобы список/карточка заказа сразу показали
    // актуальные данные (экран редактирования к этому моменту уже закрыт).
    await provider.refresh();

    // Бизнес-правило: в создании/редактировании заказа списание бумаги отключено полностью.

    if (!createdOrUpdatedOrder.assignmentCreated &&
        nextQueueBuildStatus == QueueBuildStatus.outdated) {
      _showBackgroundSaveSnackBar(
        'Очередь изменилась. Нажмите «Собрать очередь» перед сохранением, '
        'иначе заказ останется черновиком',
      );
    } else if (!createdOrUpdatedOrder.assignmentCreated &&
        !hasQueueForStatus) {
      _showBackgroundSaveSnackBar(
        'Очередь этапов пока не построена автоматически: выберите тип '
        'продукта и параметры заказа',
      );
    } else if (!createdOrUpdatedOrder.assignmentCreated && paintNotSelected) {
      // «Недостаточно материала» здесь соврало бы: склад ни при чём, заказу
      // не хватает решения менеджера.
      _showBackgroundSaveSnackBar(
        'Заказ сохранён и ждёт материалов: в заказе есть форма, но не '
        'выбрана краска. Добавьте краску — заказ сам станет готов к запуску.',
      );
    } else if (!createdOrUpdatedOrder.assignmentCreated &&
        !canLaunchProductionNow) {
      _showBackgroundSaveSnackBar(
        'Заказ сохранён без запуска: недостаточно материала на складе. '
        'Запустите заказ позже кнопкой «Запустить».',
      );
    } else if (!createdOrUpdatedOrder.assignmentCreated &&
        canLaunchProductionNow) {
      _showBackgroundSaveSnackBar(
        'Заказ сохранён и готов к запуску. Нажмите «Запустить».',
      );
    } else {
      _showBackgroundSaveSnackBar('Заказ сохранён');
    }

    // Release only after every write has completed successfully.
    if (mounted) {
      setState(() => _isSavingOrder = false);
      await WidgetsBinding.instance.endOfFrame;
      if (mounted) Navigator.of(context).pop();
    }
    // Списание лишнего выполняется на этапе отгрузки.
    } catch (e) {
      // Показываем причину, а не дамп исключения: `$e` на PostgrestException
      // разворачивается в «PostgrestException(message: …, code: …, details:
      // Bad Request, hint: null)», и сотрудник читает служебные поля вместо
      // единственной значимой строки — текста, который написал сервер.
      _showBackgroundSaveSnackBar(
          'Не удалось сохранить заказ: ${_describeSaveError(e)}',
          isError: true);
    } finally {
      if (mounted) {
        setState(() => _isSavingOrder = false);
      }
    }
  }

  /// Текст ошибки сохранения для человека.
  ///
  /// У серверных запретов (`raise exception` в триггерах и RPC) вся суть — в
  /// `message`; остальные поля PostgrestException для сотрудника шум.
  static String _describeSaveError(Object error) {
    if (error is PostgrestException) {
      final message = error.message.trim();
      if (message.isNotEmpty) return message;
      final details = (error.details ?? '').toString().trim();
      if (details.isNotEmpty) return details;
    }
    return error.toString();
  }

  String _formatDecimal(double value, {int fractionDigits = 2}) {
    final formatted = value.toStringAsFixed(fractionDigits);
    return _trimTrailingFractionZeros(formatted);
  }

  String? _productSizeLabel() {
    String format(double value) {
      final String fixed = value.toStringAsFixed(2);
      final String trimmed =
          fixed.replaceAll(RegExp(r'0+$'), '').replaceAll(RegExp(r'[.]$'), '');
      return trimmed.isEmpty ? '0' : trimmed;
    }

    final List<String> parts = <String>[];
    void tryAdd(double value) {
      if (value > 0) {
        parts.add(format(value));
      }
    }

    tryAdd(_product.width);
    tryAdd(_product.height);
    tryAdd(_product.depth);

    if (parts.isEmpty) {
      return null;
    }

    return parts.join('*');
  }

  String? _composeFormColors() {
    if (_isOldForm) return null;
    final manual = _formColorsCtl.text.trim();
    final parts = <String>[];
    if (manual.isNotEmpty) {
      parts.add(manual);
    }

    final paintDescriptions = <String>[];
    for (final paint in _paints) {
      final name = paint.displayName.trim();
      if (name.isEmpty) continue;
      final qty = paint.qtyGrams;
      final memo = paint.memo.trim();
      final buffer = StringBuffer(name);
      if (qty != null && qty > 0) {
        buffer.write(' ${_formatGrams(qty)}');
      }
      if (memo.isNotEmpty) {
        buffer.write(' (${memo})');
      }
      paintDescriptions.add(buffer.toString());
    }

    if (paintDescriptions.isNotEmpty) {
      parts.add('Краски: ${paintDescriptions.join(', ')}');
    }

    if (parts.isEmpty) return null;
    final joined = parts.join('; ').trim();
    return joined.isEmpty ? null : joined;
  }

  String? _composeFormSize() {
    if (_isOldForm) return null;
    final manual = _formSizeCtl.text.trim();
    if (manual.isNotEmpty) return manual;

    String? formatDimension(double? value) {
      if (value == null) return null;
      if (value <= 0) return null;
      return _formatDecimal(value);
    }

    final dims = <String>[];
    final width = formatDimension(_product.width);
    final height = formatDimension(_product.height);
    final depth = formatDimension(_product.depth);
    if (width != null) dims.add(width);
    if (height != null) dims.add(height);
    if (depth != null) dims.add(depth);
    String result = dims.join('×');

    final extras = <String>[];
    final roll = formatDimension(_product.roll);
    if (roll != null) extras.add('Рулон $roll');
    if (extras.isNotEmpty) {
      final extraText = extras.join(', ');
      result = result.isEmpty ? extraText : '$result ($extraText)';
    }

    result = result.trim();
    return result.isEmpty ? null : result;
  }

  String? _cleanFormSizeExtras(String? size) {
    if (size == null) return null;
    final trimmed = size.trim();
    if (trimmed.isEmpty) return null;

    final matches = RegExp(r'\(([^)]*)\)').allMatches(trimmed).toList();
    final base = trimmed.replaceAll(RegExp(r'\([^)]*\)'), '').trim();
    final extras = <String>[];

    for (final match in matches) {
      final parts = (match.group(1) ?? '')
          .split(',')
          .map((p) => p.trim())
          .where((p) => p.isNotEmpty)
          .toList();

      for (final part in parts) {
        final lower = part.toLowerCase();
        if (lower.startsWith('б') ||
            lower.startsWith('кол-во') ||
            lower.startsWith('l')) {
          continue;
        }
        extras.add(part);
      }
    }

    if (extras.isEmpty) return base.isEmpty ? null : base;
    if (base.isEmpty) return extras.join(', ');
    return '$base (${extras.join(', ')})';
  }

  String? _composeFormProductType() {
    if (_isOldForm) return null;
    final manual = _formTypeCtl.text.trim();
    if (manual.isNotEmpty) return manual;
    final productType = _product.type.trim();
    return productType.isEmpty ? null : productType;
  }

  /// Записывает реквизиты привязанной формы в заказ.
  /// Возвращает id формы на складе (для последующей линковки PDF)
  /// или null, если форма не привязана / определить её не удалось.
  Future<String?> _processFormAssignment(OrderModel order,
      {required bool isCreating}) async {
    bool persistedHasForm = false;
    bool? persistedIsOldForm;
    int? persistedFormNo;
    String? persistedFormSeries;
    String? persistedFormCode;
    String? persistedFormId;
    try {
      final persisted = await _sb
          .from('orders')
          .select('has_form, is_old_form, form_id, new_form_no, form_series, form_code')
          .eq('id', order.id)
          .maybeSingle();
      final persistedHasFormFlag = persisted?['has_form'] as bool?;
      persistedIsOldForm = persisted?['is_old_form'] as bool?;
      persistedFormId = persisted?['form_id']?.toString();
      persistedFormNo = ((persisted?['new_form_no'] as num?)?.toInt());
      final persistedSeriesRaw = (persisted?['form_series'] ?? '').toString();
      final persistedCodeRaw = (persisted?['form_code'] ?? '').toString();
      persistedFormSeries =
          persistedSeriesRaw.trim().isEmpty ? null : persistedSeriesRaw.trim();
      persistedFormCode =
          persistedCodeRaw.trim().isEmpty ? null : persistedCodeRaw.trim();
      persistedHasForm = persistedHasFormFlag ??
          (persistedIsOldForm != null ||
              persistedFormNo != null ||
              persistedFormCode != null);
    } catch (_) {
      persistedHasForm = false;
    }

    final bool hadFormBefore = _hasAssignedForm() || persistedHasForm;
    if (!isCreating && !_editingForm && hadFormBefore) {
      if (mounted &&
          !_hasAssignedForm() &&
          (persistedFormNo != null || persistedFormCode != null)) {
        setState(() {
          _hasForm = true;
          _orderFormIsOld = persistedIsOldForm;
          _orderFormNo = persistedFormNo;
          _orderFormSeries = persistedFormSeries;
          _orderFormCode = persistedFormCode;
          _orderFormDisplay = _buildFormDisplayValue(
            code: persistedFormCode,
            series: persistedFormSeries,
            number: persistedFormNo,
          );
        });
      }
      // Форма не менялась, но id нужен вызывающему коду для линковки PDF.
      try {
        return await findFormIdByOrderFormRef(
          formId: persistedFormId ?? _orderFormId,
          formCode: persistedFormCode ?? _orderFormCode,
          formSeries: persistedFormSeries ?? _orderFormSeries,
          formNo: persistedFormNo ?? _orderFormNo,
        );
      } catch (e) {
        debugPrint('❌ _processFormAssignment: resolve form id failed: $e');
        rethrow;
      }
    }

    final bool shouldHandle = isCreating || _editingForm || !hadFormBefore;
    if (!shouldHandle) return null;

    try {
      // Новое бизнес-правило: наличие формы управляется отдельной галочкой.
      // Если галочка выключена — полностью сбрасываем выбранную форму.
      if (!_hasForm) {
        await _sb
            .from('orders')
            .update({
              'has_form': false,
              'form_id': null,
              'is_old_form': false,
              'new_form_no': null,
              'form_series': null,
              'form_code': null,
            })
            .eq('id', order.id);
        if (!mounted) return null;
        setState(() {
          _orderFormIsOld = null;
          _orderFormId = null;
          _orderFormNo = null;
          _orderFormSeries = null;
          _orderFormCode = null;
          _orderFormDisplay = '-';
          _orderFormSize = null;
          _orderFormProductType = null;
          _orderFormColors = null;
          _orderFormImageUrl = null;
          _editingForm = false;
          _selectedOldFormRow = null;
          _selectedOldForm = null;
          _formResults = [];
          _formSearchCtl.clear();
          _loadingForms = false;
          _selectedOldFormImageUrl = null;
          _newFormPdfs = [];
          _oldFormPdfsFormId = null;
          _oldFormSavedPdfs = [];
        });
        return null;
      }

      WarehouseProvider? wp;
      // id формы на складе, если он известен по ходу выбора/создания.
      String? resolvedFormId;
      int? selectedFormNumber;
      dynamic rawSeries;
      dynamic rawCode;
      dynamic rawSize;
      dynamic rawProductType;
      dynamic rawColors;
      dynamic rawImageUrl;
      final bool isOldFormValue = _isOldForm;

      if (_isOldForm) {
        if (_selectedOldFormRow != null) {
          final form = _selectedOldFormRow!;
          final rowId = (form['id'] ?? '').toString().trim();
          if (rowId.isNotEmpty) resolvedFormId = rowId;
          selectedFormNumber = ((form['number'] ?? 0) as num?)?.toInt();
          rawSeries = form['series'];
          rawCode = form['code'];
          rawSize = form['size'] ?? form['title'];
          rawProductType = form['product_type'];
          rawColors = form['colors'] ?? form['description'];
          rawImageUrl = form['image_url'];
        } else if (hadFormBefore && (_orderFormIsOld ?? false)) {
          resolvedFormId = persistedFormId ?? _orderFormId;
          selectedFormNumber = _orderFormNo;
          rawSeries = _orderFormSeries;
          rawCode = _orderFormCode;
          rawSize = _orderFormSize;
          rawProductType = _orderFormProductType;
          rawColors = _orderFormColors;
          rawImageUrl = _orderFormImageUrl;
        }

        final hasCode = rawCode != null && rawCode.toString().trim().isNotEmpty;
        if (selectedFormNumber == null && !hasCode) {
          throw StateError('Выберите существующую форму из списка склада');
        }
      } else {
        final formColors = _composeFormColors();
        final formSize = _composeFormSize();
        final formProductType = _composeFormProductType();
        final hasNewFormPayload = (formColors?.trim().isNotEmpty ?? false) ||
            (formSize?.trim().isNotEmpty ?? false) ||
            (formProductType?.trim().isNotEmpty ?? false) ||
            _newFormPdfs.isNotEmpty ||
            !hadFormBefore;
        // Реюз уже привязанной формы имеет приоритет над созданием новой:
        // при возобновлении заказа из архива payload (цвета/размер) почти
        // всегда непуст, и без этой проверки на складе плодились бы
        // дубликаты форм. Явное редактирование формы (_editingForm) и
        // заказ без реквизитов формы идут по прежней ветке создания.
        final bool reuseAssignedForm =
            _hasAssignedForm() && !(_orderFormIsOld ?? false) && !_editingForm;
        if (reuseAssignedForm) {
          resolvedFormId = persistedFormId ?? _orderFormId;
          selectedFormNumber = _orderFormNo;
          rawSeries = _orderFormSeries;
          rawCode = _orderFormCode;
          rawSize = _orderFormSize;
          rawProductType = _orderFormProductType;
          rawColors = _orderFormColors;
          rawImageUrl = _orderFormImageUrl;
        } else if (hasNewFormPayload) {
          final customer = _customerController.text.trim();
          final extraInfo = _formExtraInfoController.text.trim();
          String series = customer.isNotEmpty ? customer : 'F';
          if (extraInfo.isNotEmpty) {
            series = '$series ($extraInfo)';
          }
          wp ??= WarehouseProvider();
          final created = await wp.createFormAndReturn(
            series: series,
            title: formSize,
            description: formColors,
            formSize: formSize,
            formProductType: formProductType,
            formColors: formColors,
          );
          final createdId = (created['id'] ?? '').toString().trim();
          if (createdId.isNotEmpty) resolvedFormId = createdId;
          selectedFormNumber = ((created['number'] ?? 0) as num?)?.toInt();
          final createdSeries = _sanitizeText(created['series']);
          if (createdSeries != null && createdSeries.isNotEmpty) {
            series = createdSeries;
          }
          rawSeries = series;
          rawCode = created['code'];
          rawSize = created['size'] ?? created['title'];
          rawProductType = created['product_type'];
          rawColors = created['colors'] ?? created['description'];
          rawImageUrl = created['image_url'];
        } else if (hadFormBefore && !(_orderFormIsOld ?? false)) {
          selectedFormNumber = _orderFormNo;
          rawSeries = _orderFormSeries;
          rawCode = _orderFormCode;
          rawSize = _orderFormSize;
          rawProductType = _orderFormProductType;
          rawColors = _orderFormColors;
          rawImageUrl = _orderFormImageUrl;
        } else {
          return null;
        }
      }

      final String? sanitizedSeries = _sanitizeText(rawSeries);
      final String? sanitizedCode = _sanitizeText(rawCode);
      final String? sanitizedSize = _sanitizeText(rawSize);
      final String? sanitizedProductType = _sanitizeText(rawProductType);
      final String? sanitizedColors = _sanitizeText(rawColors);
      final String? sanitizedImageUrl = _sanitizeText(rawImageUrl);

      resolvedFormId ??= await findFormIdByOrderFormRef(
        formCode: sanitizedCode,
        formSeries: sanitizedSeries,
        formNo: selectedFormNumber,
      );
      if (resolvedFormId == null) {
        throw StateError('Не удалось найти форму на складе');
      }

      final response = await _sb
          .from('orders')
          .update({
            'has_form': true,
            'form_id': resolvedFormId,
            'is_old_form': isOldFormValue,
          })
          .eq('id', order.id)
          .select()
          .maybeSingle();

      if (response == null) {
        throw 'empty response';
      }

      if (!mounted) return resolvedFormId;

      setState(() {
        _orderFormId = resolvedFormId;
        _orderFormIsOld = isOldFormValue;
        _orderFormNo = selectedFormNumber;
        _orderFormSeries = sanitizedSeries;
        _orderFormCode = sanitizedCode;
        _orderFormSize = sanitizedSize;
        _orderFormProductType = sanitizedProductType;
        _orderFormColors = sanitizedColors;
        _orderFormImageUrl = sanitizedImageUrl;
        _orderFormDisplay = _buildFormDisplayValue(
          code: sanitizedCode,
          series: sanitizedSeries,
          number: selectedFormNumber,
        );
        if (!isCreating) {
          _editingForm = false;
        }
        _selectedOldFormRow = null;
        _selectedOldForm = null;
        _formResults = [];
        _formSearchCtl.clear();
        _loadingForms = false;
        _selectedOldFormImageUrl = null;
        _oldFormPdfsFormId = null;
        _oldFormSavedPdfs = [];
      });
      return resolvedFormId;
    } catch (e) {
      debugPrint('❌ _processFormAssignment error: $e');
      rethrow;
    }
  }

  /// Линкует все PDF заказа к форме [formId] (source='order', без
  /// физического копирования файлов). Уже существующие связи (по objectPath)
  /// не дублируются. Ошибка оставляет редактор открытым для повторного сохранения.
  Future<void> _syncOrderPdfsToForm(String orderId, String formId) async {
    try {
      final orderFiles = await listOrderFiles(orderId);
      if (orderFiles.isEmpty) return;
      final formFiles = await listFormFiles(formId);
      final linkedPaths = formFiles
          .map((f) => (f['objectPath'] ?? '').toString().trim())
          .where((p) => p.isNotEmpty)
          .toSet();
      for (final file in orderFiles) {
        final objectPath = (file['objectPath'] ?? '').toString().trim();
        if (objectPath.isEmpty || linkedPaths.contains(objectPath)) continue;
        final fileName = (file['filename'] ?? '').toString().trim().isNotEmpty
            ? (file['filename'] ?? '').toString().trim()
            : objectPath.split('/').last;
        final sizeRaw = file['sizeBytes'];
        await linkFormPdf(
          formId: formId,
          objectPath: objectPath,
          fileName: fileName,
          sizeBytes: sizeRaw is num ? sizeRaw.toInt() : null,
          source: 'order',
        );
        linkedPaths.add(objectPath);
      }
    } catch (e) {
      debugPrint('❌ _syncOrderPdfsToForm($orderId -> $formId): $e');
      rethrow;
    }
  }

  /// Закреплена ли выдвижная панель материалов кнопкой в шапке. По умолчанию
  /// закрыта: она нужна точечно, при подборе бумаги, а постоянная колонка
  /// сжимала форму.
  bool _materialsPanelOpen = false;

  /// Курсор у правого края экрана — панель материалов выезжает без клика.
  bool _materialsEdgeHover = false;

  /// Курсор внутри самой панели — держим её открытой, пока он не ушёл.
  bool _materialsPanelHover = false;

  static OutlineInputBorder _orderFieldBorder(Color color, [double w = 1]) =>
      OutlineInputBorder(
        borderRadius:
            BorderRadius.circular(OrderFormMetrics.fieldRadius),
        borderSide: BorderSide(color: color, width: w),
      );

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !_isSavingOrder,
    child: AbsorbPointer(absorbing: _isSavingOrder, child: _buildEditor(context)),
  );

  Widget _buildEditor(BuildContext context) {
    final isEditing = widget.order != null;
    final hasAssignedForm = _hasAssignedForm();
    final showFormSummary = isEditing && hasAssignedForm && !_editingForm;
    final showFormEditor = !isEditing || _editingForm || !hasAssignedForm;
    final baseTheme = Theme.of(context);
    // Apply a more compact theme by reducing font size, increasing density,
    // and tightening field padding. This shrinks the entire form by roughly 20%.
    final compactTextTheme = baseTheme.textTheme.apply(
      fontSizeFactor: 0.70,
      bodyColor: baseTheme.textTheme.bodyMedium?.color,
      displayColor: baseTheme.textTheme.bodyLarge?.color,
    );
    final compactTheme = baseTheme.copyWith(
      // Use the densest visual density available to minimize vertical space.
      visualDensity: const VisualDensity(horizontal: -4, vertical: -4),
      textTheme: compactTextTheme,
      // Вид полей задаём темой, а не в каждом TextFormField: их на экране
      // несколько десятков, и правка по месту разъехалась бы на первом же
      // новом поле.
      inputDecorationTheme: baseTheme.inputDecorationTheme.copyWith(
        isDense: true,
        filled: true,
        fillColor: OrderFormColors.fieldFill,
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 10,
          vertical: 8,
        ),
        hintStyle: const TextStyle(
          fontSize: 12,
          color: OrderFormColors.placeholder,
        ),
        labelStyle:
            const TextStyle(fontSize: 12, color: OrderFormColors.label),
        border: _orderFieldBorder(OrderFormColors.border),
        enabledBorder: _orderFieldBorder(OrderFormColors.border),
        focusedBorder: _orderFieldBorder(OrderFormColors.accent, 1.4),
        disabledBorder: _orderFieldBorder(OrderFormColors.border),
      ),
    );
    final formSections = [
      _buildCompactOrderSheet(
        context: context,
        showFormSummary: showFormSummary,
        showFormEditor: showFormEditor,
        isEditing: isEditing,
        hasAssignedForm: hasAssignedForm,
      ),
    ];
    return Scaffold(
      backgroundColor: OrderFormColors.background,
      appBar: AppBar(
        backgroundColor: OrderFormColors.surface,
        surfaceTintColor: OrderFormColors.surface,
        elevation: 0,
        scrolledUnderElevation: 0,
        shape: const Border(
          bottom: BorderSide(color: OrderFormColors.border),
        ),
        titleTextStyle: const TextStyle(
          fontSize: 15,
          fontWeight: FontWeight.w600,
          color: OrderFormColors.text,
        ),
        iconTheme: const IconThemeData(color: OrderFormColors.muted),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed:
              _isSavingOrder ? null : () => Navigator.of(context).pop(),
        ),
        title: Text(isEditing
            ? 'Редактирование заказа ${(widget.order!.assignmentId ?? widget.order!.id)}'
            : 'Новый заказ'),
        actions: [
          if (widget.order != null)
            IconButton(
              icon: const Icon(Icons.comment_outlined),
              tooltip: 'Комментарии',
              onPressed: () async {
                final order = widget.order!;
                await showModalBottomSheet<void>(
                  context: context,
                  isScrollControlled: true,
                  builder: (_) => SizedBox(
                    height: MediaQuery.of(context).size.height * 0.6,
                    child: OrderCommentsSection(orderId: order.id, legacyText: order.comments),
                  ),
                );
              },
            ),
          // Переключатель панели материалов: активная кнопка — сиреневая.
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 4),
            child: OutlinedButton.icon(
              onPressed: () => setState(
                  () => _materialsPanelOpen = !_materialsPanelOpen),
              icon: const Icon(Icons.view_sidebar_outlined, size: 15),
              label: const Text('Материалы'),
              style: OutlinedButton.styleFrom(
                visualDensity: VisualDensity.compact,
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                textStyle: const TextStyle(
                    fontSize: 12, fontWeight: FontWeight.w600),
                foregroundColor: _materialsPanelOpen
                    ? OrderFormColors.accent
                    : OrderFormColors.muted,
                backgroundColor: _materialsPanelOpen
                    ? OrderFormColors.accentSoft
                    : OrderFormColors.surface,
                side: BorderSide(
                  color: _materialsPanelOpen
                      ? OrderFormColors.accentBorder
                      : OrderFormColors.border,
                ),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 4),
            child: FilledButton.icon(
              style: FilledButton.styleFrom(
                visualDensity: VisualDensity.compact,
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                padding:
                    const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                backgroundColor: OrderFormColors.accent,
                foregroundColor: Colors.white,
                textStyle: const TextStyle(
                    fontSize: 12, fontWeight: FontWeight.w600),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
              onPressed: _isSavingOrder ? null : _saveOrder,
              icon: _isSavingOrder
                  ? const SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: Colors.white,
                      ),
                    )
                  : const Icon(Icons.save_outlined, size: 15),
              label: Text(_isSavingOrder ? 'Сохранение…' : 'Сохранить'),
            ),
          ),
          if (isEditing)
            IconButton(
              icon: const Icon(Icons.delete_outline),
              tooltip: 'Удалить заказ',
              onPressed: () async {
                final confirmed = await showDialog<bool>(
                      context: context,
                      builder: (ctx) => AlertDialog(
                        title: const Text('Удалить заказ?'),
                        content: const Text(
                            'Вы действительно хотите удалить этот заказ? Это действие невозможно отменить.'),
                        actions: [
                          TextButton(
                            onPressed: () => Navigator.pop(ctx, false),
                            child: const Text('Отмена'),
                          ),
                          ElevatedButton(
                            onPressed: () => Navigator.pop(ctx, true),
                            child: const Text('Удалить'),
                          ),
                        ],
                      ),
                    ) ??
                    false;
                if (confirmed && mounted) {
                  final provider =
                      Provider.of<OrdersProvider>(context, listen: false);
                  final messenger = ScaffoldMessenger.of(context);
                  final error = await provider.deleteOrder(widget.order!.id);
                  if (!mounted) return;
                  if (error != null) {
                    // Молчаливый откат раньше выглядел как «заказ исчез и
                    // сразу вернулся»: причину не видел никто.
                    messenger.showSnackBar(SnackBar(content: Text(error)));
                    return;
                  }
                  Navigator.of(context).pop();
                }
              },
            ),
        ],
      ),
      body: Theme(
        data: compactTheme,
        child: EnterKeyBehavior(
          child: Form(
            key: _formKey,
            child: LayoutBuilder(
            builder: (context, constraints) {
              final formList = LayoutBuilder(
                builder: (context, innerConstraints) {
                  final availableWidth = innerConstraints.maxWidth;
                  // Keep the form wide enough for multi-column rows on desktop.
                  const spacing = 12.0;
                  final maxWrapWidth = availableWidth;
                  final desiredColumns = maxWrapWidth >= 980
                  
                      ? 3
                      : maxWrapWidth >= 720
                          ? 2
                          : 1;
                  final columns =
                      math.min(desiredColumns, math.max(1, formSections.length));
                  final sectionWidth = columns == 1
                      ? maxWrapWidth
                      : (maxWrapWidth - spacing * (columns - 1)) / columns;
                  return Scrollbar(
                    controller: _formScrollController,
                    thumbVisibility: true,
                    child: SingleChildScrollView(
                      controller: _formScrollController,
                      padding: const EdgeInsets.symmetric(
                        horizontal: 4,
                        vertical: 4,
                      ),
                      child: SizedBox(
                        width: maxWrapWidth,
                        child: Wrap(
                          spacing: spacing,
                          runSpacing: spacing,
                          children: formSections
                              .map(
                                (section) => SizedBox(
                                  width: sectionWidth,
                                  child: section,
                                ),
                              )
                              .toList(),
                        ),
                      ),
                    ),
                  );
                },
              );

              if (constraints.maxWidth < 1200) {
                return formList;
              }

              // Панель материалов больше не отнимает колонку постоянно: она
              // выезжает поверх формы по кнопке «Материалы» в шапке или при
              // наведении курсора на правый край. Форме остаётся вся ширина —
              // четыре колонки перестают тесниться.
              const panelWidth = 300.0;
              final bool materialsVisible = _materialsPanelOpen ||
                  _materialsEdgeHover ||
                  _materialsPanelHover;
              return Stack(
                children: [
                  SizedBox(
                    height: constraints.maxHeight,
                    width: constraints.maxWidth,
                    child: formList,
                  ),
                  // Полоса-триггер у правого края: курсор доходит до края —
                  // панель выезжает. Когда она открыта, полоса накрыта самой
                  // панелью, поэтому закрытие считает уже её MouseRegion.
                  Positioned(
                    top: 0,
                    bottom: 0,
                    right: 0,
                    width: 12,
                    child: MouseRegion(
                      onEnter: (_) =>
                          setState(() => _materialsEdgeHover = true),
                      onExit: (_) =>
                          setState(() => _materialsEdgeHover = false),
                      child: const SizedBox.expand(),
                    ),
                  ),
                  AnimatedPositioned(
                    duration: const Duration(milliseconds: 250),
                    curve: Curves.easeOutCubic,
                    top: 0,
                    bottom: 0,
                    right: materialsVisible ? 0 : -(panelWidth + 24),
                    width: panelWidth,
                    child: MouseRegion(
                      onEnter: (_) =>
                          setState(() => _materialsPanelHover = true),
                      onExit: (_) =>
                          setState(() => _materialsPanelHover = false),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(vertical: 4),
                        child: _buildWarehousePreviewPanel(),
                      ),
                    ),
                  ),
                ],
              );
            },
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildCompactOrderSheet({
    required BuildContext context,
    required bool showFormSummary,
    required bool showFormEditor,
    required bool isEditing,
    required bool hasAssignedForm,
  }) {
    const labelWidth = 128.0;
    return LayoutBuilder(
      builder: (context, constraints) {
        const spacing = 16.0;

        final sheet = Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: _buildOrderSectionCard(
                title: 'Основная информация',
                icon: Icons.description_outlined,
                backgroundColor: const Color(0xFFE7FBF3),
                accentColor: const Color(0xFF21B37B),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    _buildLabelRow(
                      label: 'Дата',
                      labelWidth: labelWidth,
                      child: Row(
                        children: [
                          Expanded(
                            child: _buildDatePickerField(
                              label: 'Дата заказа',
                              value: _orderDate,
                              onTap: _pickOrderDate,
                              emptyError: 'Укажите дату заказа',
                            ),
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: _buildDatePickerField(
                              label: 'Срок выполнения',
                              value: _dueDate,
                              onTap: _pickDueDate,
                              emptyError: 'Укажите срок',
                            ),
                          ),
                        ],
                      ),
                    ),
                    _buildLabelRow(
                      label: 'Заказчик',
                      labelWidth: labelWidth,
                      child: _buildCustomerField(),
                    ),
                    _buildLabelRow(
                      label: 'Тип',
                      labelWidth: labelWidth,
                      child: _buildProductTypeField(),
                    ),
                    _buildLabelRow(
                      label: 'Тираж',
                      labelWidth: labelWidth,
                      child: _buildQuantityField(),
                    ),
                    _buildLabelRow(
                      label: 'Размеры',
                      labelWidth: labelWidth,
                      child: _buildDimensionsField(),
                    ),
                    if (_isBlockVisible(kOrderFormBlockHandle) ||
                        _isBlockVisible(kOrderFormBlockCardboard) ||
                        _isBlockVisible(kOrderFormBlockTrimming))
                      _buildLabelRow(
                        label: 'Ручки и картон',
                        labelWidth: labelWidth,
                        child:
                            _buildHandlesSection(context, wrapWithCard: false),
                      ),
                    // Менеджер — в конце этой колонки, а не в «Бобинорезке»:
                    // он относится к самому заказу, а не к материалу.
                    _buildLabelRow(
                      label: 'Менеджер',
                      labelWidth: labelWidth,
                      child: _buildManagerField(),
                    ),
                  ],
                ),
              ),
            ),
            // Карточки «Печать» нет вовсе, когда техлид выключил все три её
            // блока: пустая карточка занимала бы колонку и сбивала с толку.
            if (_isBlockVisible(kOrderFormBlockPaints) ||
                _isBlockVisible(kOrderFormBlockForm) ||
                _isBlockVisible(kOrderFormBlockPdf)) ...[
              const SizedBox(width: spacing),
              Expanded(
                child: _buildOrderSectionCard(
                  title: 'Печать',
                  icon: Icons.print_outlined,
                  backgroundColor: const Color(0xFFFFF4DE),
                  accentColor: const Color(0xFFF4A12F),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      if (_isBlockVisible(kOrderFormBlockPaints))
                        _buildLabelRow(
                          label: 'Краски',
                          labelWidth: labelWidth,
                          child: _buildPaintsSection(wrapWithCard: false),
                        ),
                      if (_isBlockVisible(kOrderFormBlockForm))
                        _buildLabelRow(
                          label: 'Форма',
                          labelWidth: labelWidth,
                          child: _buildFormSection(
                            context: context,
                            showFormSummary: showFormSummary,
                            showFormEditor: showFormEditor,
                            isEditing: isEditing,
                            hasAssignedForm: hasAssignedForm,
                            wrapWithCard: false,
                          ),
                        ),
                      if (_isBlockVisible(kOrderFormBlockPdf))
                        _buildLabelRow(
                          label: 'PDF',
                          labelWidth: labelWidth,
                          child: _buildPdfAttachmentRow(),
                        ),
                    ],
                  ),
                ),
              ),
            ],
            const SizedBox(width: spacing),
            // Колонка, а не одна карточка: «Дополнительные опции» заказчик
            // просил разместить сразу под «Бобинорезкой».
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _buildOrderSectionCard(
                    title: 'Бобинорезка',
                    icon: Icons.content_cut,
                    backgroundColor: const Color(0xFFEFEAFF),
                    accentColor: const Color(0xFF7A4CF0),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        // Блок бумаг строит подпись сам: у каждой бумаги своя
                        // строка «Доступно» в левой колонке, напротив её карточки.
                        // Общий _buildLabelRow дал бы одну подпись на весь блок.
                        Container(
                          padding: const EdgeInsets.symmetric(vertical: 5),
                          decoration: const BoxDecoration(
                            border: Border(
                              bottom: BorderSide(color: OrderFormColors.divider),
                            ),
                          ),
                          child: _buildProductMaterialAndExtras(
                            _product,
                            labelWidth: labelWidth,
                          ),
                        ),
                        if (_isBlockVisible(kOrderFormBlockMakeready))
                          _buildLabelRow(
                            label: 'Приладка',
                            labelWidth: labelWidth,
                            child: _buildMakereadyFields(),
                          ),
                        _buildLabelRow(
                          label: 'Комментарий',
                          labelWidth: labelWidth,
                          child: _buildCommentsSection(context, wrapWithCard: false),
                        ),
                        _buildLabelRow(
                          label: 'Лишнее на складе',
                          labelWidth: labelWidth,
                          child: _buildStockExtraSection(),
                        ),
                      ],
                    ),
                  ),
                  // Карточки нет, пока показывать нечего: у типа продукта не
                  // заведено опций и в заказе ничего не выбрано. Пустая
                  // карточка занимала бы место в самой плотной части формы.
                  if (_extraOptionRows.isNotEmpty) ...[
                    const SizedBox(height: spacing),
                    _buildExtraOptionsCard(labelWidth: labelWidth),
                  ],
                ],
              ),
            ),
            const SizedBox(width: spacing),
            // Очередь — своя, четвёртая колонка: сборка маршрута не про
            // бобинорезку, а внутри чужой карточки её было не найти.
            Expanded(
              child: _buildOrderSectionCard(
                title: 'Очередь',
                icon: Icons.format_list_numbered,
                backgroundColor: OrderFormColors.blueBg,
                accentColor: OrderFormColors.blueText,
                child: _buildProductionSection(
                  context,
                  wrapWithCard: false,
                  includeMakeready: false,
                ),
              ),
            ),
          ],
        );

        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [_buildRequiredBlocksBanner(), sheet],
        );
      },
    );
  }

  // ===== Обязательные блоки =====

  /// Черновик заказа для проверки обязательных блоков.
  ///
  /// Собирается из текущего состояния формы, а не из `widget.order`: подсказка
  /// обязана гаснуть в тот момент, когда поле заполнили, а не после
  /// сохранения. Правило «что считать заполненным» при этом одно на форму и на
  /// пересчёт статусов — [filledOrderBlocks], иначе форма и сервер разошлись бы
  /// в том, готов заказ или нет.
  OrderModel _draftForRequiredBlocks() {
    final papers = _collectSelectedPapers();
    return OrderModel(
      id: widget.order?.id ?? '',
      manager: '',
      customer: _customerController.text,
      orderDate: _orderDate ?? DateTime.now(),
      dueDate: _dueDate,
      product: _product,
      paperMaterials: papers,
      material: papers.isNotEmpty ? papers.first : _selectedMaterial,
      handle: _selectedHandleDescription,
      cardboard: _selectedCardboard,
      makeready: _makeready,
      additionalParams: _selectedParams,
      hasForm: _hasForm,
      newFormNo: _orderFormNo,
      formCode: _orderFormCode,
      formId: _orderFormId,
      pdfUrl: widget.order?.pdfUrl,
    );
  }

  /// Незаполненные обязательные блоки текущего типа продукта.
  List<String> _missingRequiredBlockCodes() {
    final settings = ProductTypeSettings.instance;
    if (!settings.isLoaded) return const <String>[];
    final required = settings.requiredBlockCodes(_product.type);
    if (required.isEmpty) return const <String>[];

    final draft = _draftForRequiredBlocks();
    return missingRequiredBlocksForOrder(
      requiredCodes: required,
      filledCodes: filledOrderBlocks(
        order: draft,
        paintLineCount: _paints
            .where((row) => row.displayName.trim().isNotEmpty)
            .length,
        hasPdf: _pickedOrderPdfs.isNotEmpty || _savedOrderPdfs.isNotEmpty,
      ),
      conditionsFor: (code) => settings.blockConditions(_product.type, code),
      handleTypeName: orderHandleTypeName(draft),
      order: settings.formBlockCodes,
    );
  }

  /// Полоса «чего не хватает для готовности».
  ///
  /// Живёт в форме, а не на карточке заказа в списке: карточка показывает
  /// причину только у заказа в «Ожидании материалов», а такой заказ уходит в
  /// черновик. Читать объяснение сотрудник должен там, где он его исправляет.
  Widget _buildRequiredBlocksBanner() {
    final missing = _missingRequiredBlockCodes();
    if (missing.isEmpty) return const SizedBox.shrink();

    final titles = ProductTypeSettings.instance.formBlockTitles;
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: OrderFormColors.orangeBg,
        borderRadius: BorderRadius.circular(OrderFormMetrics.cardRadius),
        border: Border.all(color: OrderFormColors.orangeText.withValues(alpha: 0.35)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(Icons.error_outline,
              size: 18, color: OrderFormColors.orangeText),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              'Заказ останется черновиком, пока не заполнено: '
              '${missing.map((code) => titles[code] ?? code).join(', ')}.',
              style: const TextStyle(
                fontSize: 12.5,
                height: 1.35,
                color: OrderFormColors.orangeText,
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// Карточка «Дополнительные опции» — сразу под «Бобинорезкой».
  ///
  /// Состав задаёт техлид в редакторе опций, здесь не зашито ничего: строки
  /// приходят из справочника типа продукта поверх снимка заказа.
  Widget _buildExtraOptionsCard({required double labelWidth}) {
    return _buildOrderSectionCard(
      title: 'Дополнительные опции',
      icon: Icons.tune,
      backgroundColor: OrderFormColors.orangeBg,
      accentColor: OrderFormColors.orangeText,
      child: OrderExtraOptionsBlock(
        rows: _extraOptionRows,
        labelWidth: labelWidth,
        onChanged: (rows) => setState(() => _extraOptionRows = rows),
      ),
    );
  }

  /// Базовые поля продукта (наименование, тираж, габариты)
  Widget _buildProductBasics(ProductModel product) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _buildFieldGrid([
          _buildProductTypeField(),
          _buildQuantityField(),
        ], breakpoint: 680, minItemWidth: 220),
        const SizedBox(height: 4),
        _buildDimensionsField(),
      ],
    );
  }

  Widget _buildExtraPaperSelectors({required double labelWidth}) {
    // Блок выключен техлидом — в форме его нет вовсе. Уже выбранные бумаги при
    // этом остаются в заказе: скрытие настраивает форму, а не правит данные.
    if (!_isBlockVisible(kOrderFormBlockExtraPapers)) {
      return const SizedBox.shrink();
    }
    if (_extraPaperMaterials.isEmpty) return const SizedBox.shrink();

    final papers = _paperItems();
    final nameSet = <String>{};
    for (final t in papers) {
      final n = t.description.trim();
      if (n.isNotEmpty) nameSet.add(n);
    }
    final allNames = nameSet.toList()
      ..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));

    List<String> formatsFor(String name) {
      final formats = <String>{};
      for (final t in papers) {
        if (t.description.trim().toLowerCase() == name.trim().toLowerCase()) {
          final format = (t.format ?? '').trim();
          if (format.isNotEmpty) formats.add(format);
        }
      }
      final sorted = formats.toList()
        ..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
      return sorted;
    }

    List<String> gramsFor(String name, String format) {
      final grammages = <String>{};
      for (final t in papers) {
        if (t.description.trim().toLowerCase() == name.trim().toLowerCase() &&
            (t.format ?? '').trim().toLowerCase() ==
                format.trim().toLowerCase()) {
          final grammage = (t.grammage ?? '').trim();
          if (grammage.isNotEmpty) grammages.add(grammage);
        }
      }
      final sorted = grammages.toList()
        ..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
      return sorted;
    }

    TmcModel? resolveExtraPaper(MaterialModel paper) {
      final name = paper.name.trim().toLowerCase();
      final format = (paper.format ?? '').trim().toLowerCase();
      final grammage = (paper.grammage ?? '').trim().toLowerCase();
      if (name.isEmpty || format.isEmpty || grammage.isEmpty) {
        return null;
      }
      for (final t in papers) {
        if (t.description.trim().toLowerCase() == name &&
            (t.format ?? '').trim().toLowerCase() == format &&
            (t.grammage ?? '').trim().toLowerCase() == grammage) {
          return t;
        }
      }
      return null;
    }

    bool extraLengthExceeded(MaterialModel paper) {
      final length = _paperExtraDouble(paper, 'lengthL');
      if (length == null || length <= 0) return false;
      final resolved = resolveExtraPaper(paper);
      if (resolved == null) return false;
      // Сверяем с ДОСТУПНЫМ, а не со складским: метры, обещанные другим
      // заказам, этому заказу не достанутся. Раньше проверка брала складской
      // остаток, поле оставалось белым — и заказ уходил в «Ожидание
      // материалов» уже после сохранения, хотя нехватку было видно сразу.
      final available = availablePaperQtyById(
            resolved.id,
            fallbackStock: resolved.quantity,
          ) ??
          resolved.quantity;
      return length > available;
    }

    Iterable<String> filter(Iterable<String> source, String query) {
      final q = query.trim().toLowerCase();
      if (q.isEmpty) return source;
      return source.where((item) => item.toLowerCase().contains(q));
    }

    InputDecoration paperDecoration(String label, bool active) {
      return InputDecoration(
        labelText: label,
        border: const OutlineInputBorder(),
        enabledBorder: OutlineInputBorder(
          borderSide: BorderSide(
            color: active
                ? Theme.of(context).colorScheme.primary
                : Theme.of(context).dividerColor,
          ),
        ),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SizedBox(height: 6),
        for (var i = 0; i < _extraPaperMaterials.length; i++) ...[
          _paperGutterRow(
            labelWidth: labelWidth,
            availableQty: availablePaperQtyById(_extraPaperMaterials[i].id),
            card: InkWell(
              onTap: () => setState(() => _activePaperSlotIndex = i + 1),
              borderRadius: BorderRadius.circular(8),
              child: Container(
                margin: const EdgeInsets.only(bottom: 8),
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(
                    color: _activePaperSlotIndex == i + 1
                        ? Theme.of(context).colorScheme.primary
                        : Theme.of(context).dividerColor.withOpacity(0.8),
                    width: _activePaperSlotIndex == i + 1 ? 1.4 : 1,
                  ),
                ),
                child: Column(
                  children: [
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(
                          child: Autocomplete<String>(
                            optionsBuilder: (text) => filter(allNames, text.text),
                            displayStringForOption: (value) => value,
                            fieldViewBuilder:
                                (ctx, controller, focusNode, onFieldSubmitted) {
                              final currentName = _extraPaperMaterials[i].name;
                              if (controller.text != currentName) {
                                controller.value = TextEditingValue(
                                  text: currentName,
                                  selection: TextSelection.collapsed(
                                    offset: currentName.length,
                                  ),
                                );
                              }
                              return TextField(
                                controller: controller,
                                focusNode: focusNode,
                                decoration: paperDecoration(
                                  'Материал (бумага №${i + 2})',
                                  _activePaperSlotIndex == i + 1,
                                ),
                                onChanged: (value) {
                                  setState(() {
                                    _activePaperSlotIndex = i + 1;
                                    _extraPaperMaterials[i] =
                                        _extraPaperMaterials[i].copyWith(
                                      name: value,
                                      format: null,
                                      grammage: null,
                                    );
                                  });
                                  _scheduleStagePreviewUpdate();
                                },
                                onSubmitted: (_) => onFieldSubmitted(),
                              );
                            },
                            onSelected: (value) {
                              setState(() {
                                _activePaperSlotIndex = i + 1;
                                _extraPaperMaterials[i] =
                                    _extraPaperMaterials[i].copyWith(
                                  name: value,
                                  format: null,
                                  grammage: null,
                                );
                              });
                              _scheduleStagePreviewUpdate();
                            },
                          ),
                        ),
                        const SizedBox(width: 4),
                        IconButton(
                          tooltip: 'Удалить бумагу',
                          visualDensity: VisualDensity.compact,
                          onPressed: () {
                            setState(() {
                              _extraPaperMaterials.removeAt(i);
                              if (_activePaperSlotIndex >
                                  _extraPaperMaterials.length) {
                                _activePaperSlotIndex =
                                    _extraPaperMaterials.isEmpty
                                        ? 0
                                        : _extraPaperMaterials.length;
                              }
                            });
                            _scheduleStagePreviewUpdate();
                          },
                          icon: const Icon(Icons.delete_outline),
                        ),
                      ],
                    ),
                    const SizedBox(height: 4),
                    Autocomplete<String>(
                      optionsBuilder: (text) {
                        final name = _extraPaperMaterials[i].name.trim();
                        if (name.isEmpty) return const Iterable<String>.empty();
                        return filter(formatsFor(name), text.text);
                      },
                      displayStringForOption: (value) => value,
                      fieldViewBuilder:
                          (ctx, controller, focusNode, onFieldSubmitted) {
                        final currentFormat = _extraPaperMaterials[i].format ?? '';
                        if (controller.text != currentFormat) {
                          controller.value = TextEditingValue(
                            text: currentFormat,
                            selection: TextSelection.collapsed(
                              offset: currentFormat.length,
                            ),
                          );
                        }
                        return TextField(
                          controller: controller,
                          focusNode: focusNode,
                          enabled: _extraPaperMaterials[i].name.trim().isNotEmpty,
                          decoration: paperDecoration(
                            'Формат',
                            _activePaperSlotIndex == i + 1,
                          ).copyWith(
                            helperText: _extraPaperMaterials[i].name.trim().isNotEmpty
                                ? null
                                : 'Сначала выберите материал',
                          ),
                          onChanged: (value) {
                            setState(() {
                              _activePaperSlotIndex = i + 1;
                              _extraPaperMaterials[i] = _extraPaperMaterials[i].copyWith(
                                format: value,
                                grammage: null,
                              );
                            });
                            _scheduleStagePreviewUpdate();
                          },
                          onSubmitted: (_) => onFieldSubmitted(),
                        );
                      },
                      onSelected: (value) {
                        setState(() {
                          _activePaperSlotIndex = i + 1;
                          _extraPaperMaterials[i] =
                              _extraPaperMaterials[i].copyWith(
                            format: value,
                            grammage: null,
                          );
                        });
                        _scheduleStagePreviewUpdate();
                      },
                    ),
                    const SizedBox(height: 4),
                    Autocomplete<String>(
                      optionsBuilder: (text) {
                        final name = _extraPaperMaterials[i].name.trim();
                        final format = (_extraPaperMaterials[i].format ?? '').trim();
                        if (name.isEmpty || format.isEmpty) {
                          return const Iterable<String>.empty();
                        }
                        return filter(gramsFor(name, format), text.text);
                      },
                      displayStringForOption: (value) => value,
                      fieldViewBuilder:
                          (ctx, controller, focusNode, onFieldSubmitted) {
                        final currentGrammage = _extraPaperMaterials[i].grammage ?? '';
                        if (controller.text != currentGrammage) {
                          controller.value = TextEditingValue(
                            text: currentGrammage,
                            selection: TextSelection.collapsed(
                              offset: currentGrammage.length,
                            ),
                          );
                        }
                        return TextField(
                          controller: controller,
                          focusNode: focusNode,
                          enabled: _extraPaperMaterials[i].name.trim().isNotEmpty &&
                              (_extraPaperMaterials[i].format ?? '')
                                  .trim()
                                  .isNotEmpty,
                          decoration: paperDecoration(
                            'Грамаж',
                            _activePaperSlotIndex == i + 1,
                          ).copyWith(
                            helperText: _extraPaperMaterials[i].name.trim().isNotEmpty &&
                                    (_extraPaperMaterials[i].format ?? '')
                                        .trim()
                                        .isNotEmpty
                                ? null
                                : 'Сначала выберите формат',
                          ),
                          onChanged: (value) {
                            setState(() {
                              _activePaperSlotIndex = i + 1;
                              _extraPaperMaterials[i] =
                                  _extraPaperMaterials[i].copyWith(
                                grammage: value,
                              );
                            });
                            _scheduleStagePreviewUpdate();
                          },
                          onSubmitted: (_) => onFieldSubmitted(),
                        );
                      },
                      onSelected: (value) {
                        setState(() {
                          _activePaperSlotIndex = i + 1;
                          _extraPaperMaterials[i] =
                              _extraPaperMaterials[i].copyWith(
                            grammage: value,
                          );
                        });
                        _scheduleStagePreviewUpdate();
                      },
                    ),
                    const SizedBox(height: 4),
                    Row(
                      children: [
                        Expanded(
                          child: TextFormField(
                            initialValue: _paperExtraDouble(
                                      _extraPaperMaterials[i],
                                      'widthB',
                                    ) !=
                                    null
                                ? _formatDecimal(_paperExtraDouble(
                                    _extraPaperMaterials[i], 'widthB')!)
                                : '',
                            autovalidateMode:
                                AutovalidateMode.onUserInteraction,
                            decoration: const InputDecoration(
                              labelText: 'Ширина b',
                              border: OutlineInputBorder(),
                            ),
                            keyboardType: const TextInputType.numberWithOptions(
                                decimal: true),
                            validator: (value) {
                              final parsed =
                                  double.tryParse((value ?? '').replaceAll(',', '.'));
                              return _validatePaperWidthB(
                                widthB: parsed,
                                paper: _extraPaperMaterials[i],
                                isMain: false,
                              );
                            },
                            onChanged: (value) {
                              final parsed =
                                  double.tryParse(value.replaceAll(',', '.'));
                              setState(() {
                                final nextExtra = Map<String, dynamic>.from(
                                  _extraPaperMaterials[i].extra ?? const {},
                                );
                                if (parsed == null) {
                                  nextExtra.remove('widthB');
                                } else {
                                  nextExtra['widthB'] = parsed;
                                }
                                _extraPaperMaterials[i] =
                                    _extraPaperMaterials[i].copyWith(
                                  extra: nextExtra.isEmpty ? null : nextExtra,
                                );
                              });
                              _scheduleStagePreviewUpdate();
                            },
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: TextFormField(
                            initialValue:
                                _paperExtraString(_extraPaperMaterials[i], 'blQuantity') ??
                                    '',
                            decoration: const InputDecoration(
                              labelText: 'Количество',
                              border: OutlineInputBorder(),
                            ),
                            onChanged: (value) {
                              final trimmed = value.trim();
                              setState(() {
                                final nextExtra = Map<String, dynamic>.from(
                                  _extraPaperMaterials[i].extra ?? const {},
                                );
                                if (trimmed.isEmpty) {
                                  nextExtra.remove('blQuantity');
                                } else {
                                  nextExtra['blQuantity'] = trimmed;
                                }
                                _extraPaperMaterials[i] =
                                    _extraPaperMaterials[i].copyWith(
                                  extra: nextExtra.isEmpty ? null : nextExtra,
                                );
                              });
                              _scheduleStagePreviewUpdate();
                            },
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: TextFormField(
                            initialValue: _paperExtraDouble(
                                      _extraPaperMaterials[i],
                                      'lengthL',
                                    ) !=
                                    null
                                ? _formatDecimal(_paperExtraDouble(
                                    _extraPaperMaterials[i], 'lengthL')!)
                                : '',
                            decoration: const InputDecoration(
                              labelText: 'Длина L',
                              border: OutlineInputBorder(),
                            ).copyWith(
                              errorMaxLines: 2,
                              errorText: extraLengthExceeded(_extraPaperMaterials[i])
                                  ? kNotEnoughMaterialError
                                  : null,
                            ),
                            keyboardType: const TextInputType.numberWithOptions(
                                decimal: true),
                            onChanged: (value) {
                              final parsed =
                                  double.tryParse(value.replaceAll(',', '.'));
                              setState(() {
                                final nextExtra = Map<String, dynamic>.from(
                                  _extraPaperMaterials[i].extra ?? const {},
                                );
                                if (parsed == null) {
                                  nextExtra.remove('lengthL');
                                } else {
                                  nextExtra['lengthL'] = parsed;
                                }
                                _extraPaperMaterials[i] =
                                    _extraPaperMaterials[i].copyWith(
                                  quantity: parsed != null && parsed > 0
                                      ? parsed
                                      : _extraPaperMaterials[i].quantity,
                                  extra: nextExtra.isEmpty ? null : nextExtra,
                                );
                              });
                              _scheduleStagePreviewUpdate();
                            },
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ],
    );
  }

  /// Списание лишнего со склада: поиск позиции, остаток и количество.
  ///
  /// Живёт отдельным методом, потому что в карточке «Бобинорезка» стоит не
  /// рядом с материалами, а последней строкой — после комментария.
  Widget _buildStockExtraSection() {
    return _buildStockExtraLayout(
      Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(
            controller: _stockExtraSearchController,
            focusNode: _stockExtraFocusNode,
            onTap: () {
              if (_stockExtraAutoloaded) return;
              setState(() => _stockExtraAutoloaded = true);
              _updateStockExtra(includeAllResults: true);
            },
            decoration: InputDecoration(
              labelText: 'Лишнее на складе',
              border: const OutlineInputBorder(),
              suffixIcon: _loadingStockExtra
                  ? const Padding(
                      padding: EdgeInsets.all(12),
                      child: SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                    )
                  : (_stockExtraSearchController.text.isEmpty
                      ? null
                      : IconButton(
                          icon: const Icon(Icons.clear),
                          onPressed: () {
                            _stockExtraSearchController.clear();
                            _onStockExtraSearchChanged('');
                          },
                        )),
            ),
            onChanged: _onStockExtraSearchChanged,
          ),
          const SizedBox(height: 3),
          Text(
            _stockExtra != null
                ? 'Доступно: ${_stockExtra!.toStringAsFixed(2)}'
                : 'Доступно: —',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const SizedBox(height: 4),
          TextField(
            controller: _stockExtraQtyController,
            decoration: InputDecoration(
              labelText: 'Количество для списания',
              border: const OutlineInputBorder(),
              helperText: _selectedStockExtraRow != null
                  ? null
                  : 'Сначала выберите позицию из списка',
            ),
            enabled: _selectedStockExtraRow != null,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            onChanged: (value) {
              final normalized = value.replaceAll(',', '.');
              final parsed = double.tryParse(normalized);
              double? nextValue = parsed != null && parsed >= 0 ? parsed : null;
              if (nextValue != null && _stockExtra != null) {
                final double available = _stockExtra!;
                if (available >= 0 && nextValue > available) {
                  nextValue = available;
                  final text = _formatDecimal(available);
                  _stockExtraQtyController.value = TextEditingValue(
                    text: text,
                    selection: TextSelection.collapsed(offset: text.length),
                  );
                }
              }
              setState(() {
                _stockExtraQtyTouched = true;
                _stockExtraSelectedQty = nextValue;
                _product.leftover =
                    _stockExtraSelectedQty != null && _stockExtraSelectedQty! > 0
                        ? _stockExtraSelectedQty
                        : null;
                if (_writeOffStockExtra &&
                    (_stockExtraSelectedQty == null ||
                        _stockExtraSelectedQty! <= 0)) {
                  _writeOffStockExtra = false;
                }
              });
            },
          ),
          const SizedBox(height: 4),
          if (_stockExtraAutoloaded &&
              (_stockExtraFocusNode.hasFocus ||
                  _stockExtraSearchController.text.trim().isNotEmpty))
            _buildStockExtraResults(),
        ],
      ),
      const SizedBox.shrink(),
    );
  }

  /// Дополнительные параметры продукта: материал и вложения.
  Widget _buildProductMaterialAndExtras(
    ProductModel product, {
    required double labelWidth,
  }) {
    // Подписка на склад обязательна: резерв бумаги приезжает отдельным
    // запросом уже после открытия формы, и до его прихода доступное равно
    // складскому. Без подписки «Доступно» и красное «Недостаточно материала»
    // так и остались бы посчитанными по неполным данным — форма не
    // перерисовывалась бы, потому что читает провайдер с listen: false.
    final section = Consumer<WarehouseProvider>(
      builder: (context, warehouse, child) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _paperGutterRow(
            labelWidth: labelWidth,
            label: 'Склад и материалы',
            availableQty: _currentAvailablePaperQty(),
            card: Builder(
              builder: (context) {
                final papers = _paperItems();
                final nameSet = <String>{};
                for (final t in papers) {
                  final n = (t.description).trim();
                  if (n.isNotEmpty) nameSet.add(n);
                }
                final allNames = nameSet.toList()
                  ..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));

                List<String> formatsFor(String name) {
                  final s = <String>{};
                  for (final t in papers) {
                    if (t.description.trim().toLowerCase() ==
                        name.trim().toLowerCase()) {
                      final f = (t.format ?? '').trim();
                      if (f.isNotEmpty) s.add(f);
                    }
                  }
                  final list = s.toList()
                    ..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
                  return list;
                }

                List<String> gramsFor(String name, String fmt) {
                  final s = <String>{};
                  for (final t in papers) {
                    if (t.description.trim().toLowerCase() ==
                            name.trim().toLowerCase() &&
                        (t.format ?? '').trim().toLowerCase() ==
                            fmt.trim().toLowerCase()) {
                      final g = (t.grammage ?? '').trim();
                      if (g.isNotEmpty) s.add(g);
                    }
                  }
                  final list = s.toList()
                    ..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
                  return list;
                }

                TmcModel? findExact(String name, String fmt, String gram) {
                  for (final t in papers) {
                    if (t.description.trim().toLowerCase() ==
                            name.trim().toLowerCase() &&
                        (t.format ?? '').trim().toLowerCase() ==
                            fmt.trim().toLowerCase() &&
                        (t.grammage ?? '').trim().toLowerCase() ==
                            gram.trim().toLowerCase()) {
                      return t;
                    }
                  }
                  return null;
                }

                Iterable<String> filter(Iterable<String> source, String q) {
                  final query = q.trim().toLowerCase();
                  if (query.isEmpty) return source;
                  return source.where((o) => o.toLowerCase().contains(query));
                }

                final formatOptions = _matSelectedName != null
                    ? formatsFor(_matSelectedName!)
                    : const <String>[];
                final gramOptions =
                    (_matSelectedName != null && _matSelectedFormat != null)
                        ? gramsFor(_matSelectedName!, _matSelectedFormat!)
                        : const <String>[];

                InputDecoration mainPaperDecoration(String label) {
                  final bool active = _activePaperSlotIndex == 0;
                  return InputDecoration(
                    labelText: label,
                    border: const OutlineInputBorder(),
                    enabledBorder: OutlineInputBorder(
                      borderSide: BorderSide(
                        color: active
                            ? Theme.of(context).colorScheme.primary
                            : Theme.of(context).dividerColor,
                      ),
                    ),
                  );
                }

                return Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    InkWell(
                      onTap: () => setState(() => _activePaperSlotIndex = 0),
                      borderRadius: BorderRadius.circular(8),
                      child: Container(
                        padding: const EdgeInsets.all(8),
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(
                            color: _activePaperSlotIndex == 0
                                ? Theme.of(context).colorScheme.primary
                                : Theme.of(context).dividerColor.withOpacity(0.8),
                            width: _activePaperSlotIndex == 0 ? 1.4 : 1,
                          ),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            Autocomplete<String>(
                              optionsBuilder: (text) => filter(allNames, text.text),
                              displayStringForOption: (s) => s,
                              fieldViewBuilder:
                                  (ctx, controller, focusNode, onFieldSubmitted) {
                                // Синхронизация значения — только когда оно
                                // разошлось. Безусловное присваивание на каждой
                                // перестройке сбивало курсор в конец строки.
                                if (controller.text != _matNameCtl.text) {
                                  controller.value = _matNameCtl.value;
                                }
                                return TextField(
                                  controller: controller,
                                  focusNode: focusNode,
                                  decoration:
                                      mainPaperDecoration('Материал').copyWith(
                                    errorText: _matNameError,
                                  ),
                                  // Правка основной бумаги ловится через onChanged,
                                  // а не через controller.addListener в билдере.
                                  //
                                  // fieldViewBuilder вызывается на КАЖДОЙ
                                  // перестройке формы, и слушатель добавлялся
                                  // заново — их накапливались десятки, и все они
                                  // срабатывали на программную запись в
                                  // контроллер, а не только на ввод сотрудника.
                                  // Каждый ставил _activePaperSlotIndex = 0, то
                                  // есть «активна первая бумага». Из-за этого
                                  // выбор материала со склада для второй бумаги
                                  // уезжал в первую: слот подсвечен второй, а
                                  // индекс к моменту клика уже сброшен.
                                  // onChanged срабатывает только на ввод.
                                  onChanged: (value) {
                                    setState(() {
                                      _activePaperSlotIndex = 0;
                                      _matNameCtl.text = value;
                                      _matNameCtl.selection = controller.selection;
                                      _matSelectedName = null;
                                      _matSelectedFormat = null;
                                      _matSelectedGrammage = null;
                                      _matFormatCtl.text = '';
                                      _matGramCtl.text = '';
                                      _matNameError = (value.trim().isEmpty ||
                                              allNames
                                                  .map((e) => e.toLowerCase())
                                                  .contains(
                                                      value.trim().toLowerCase()))
                                          ? null
                                          : 'Выберите материал из списка';
                                      _matFormatError = null;
                                      _matGramError = null;
                                      final lowerNames =
                                          allNames.map((e) => e.toLowerCase()).toList();
                                      final typed = value.trim().toLowerCase();
                                      if (lowerNames.contains(typed)) {
                                        _matSelectedName =
                                            allNames[lowerNames.indexOf(typed)];
                                      }
                                    });
                                    _scheduleStagePreviewUpdate();
                                  },
                                  onSubmitted: (_) => onFieldSubmitted(),
                                );
                              },
                              onSelected: (value) {
                                setState(() {
                                  _activePaperSlotIndex = 0;
                                  _matNameCtl.text = value;
                                  _matSelectedName = value;
                                  _matSelectedFormat = null;
                                  _matSelectedGrammage = null;
                                  _matFormatCtl.text = '';
                                  _matGramCtl.text = '';
                                  _matNameError = null;
                                  _matFormatError = null;
                                  _matGramError = null;
                                  _selectedMaterialTmc = null;
                                  _selectedMaterial = null;
                                });
                                _scheduleStagePreviewUpdate();
                              },
                            ),
                            const SizedBox(height: 4),
                            Autocomplete<String>(
                              optionsBuilder: (text) => filter(formatOptions, text.text),
                              displayStringForOption: (s) => s,
                              fieldViewBuilder:
                                  (ctx, controller, focusNode, onFieldSubmitted) {
                                if (controller.text != _matFormatCtl.text) {
                                  controller.value = _matFormatCtl.value;
                                }
                                return TextField(
                                  controller: controller,
                                  focusNode: focusNode,
                                  enabled: _matSelectedName != null,
                                  decoration:
                                      mainPaperDecoration('Формат').copyWith(
                                    helperText: _matSelectedName != null
                                        ? null
                                        : 'Сначала выберите материал',
                                    errorText:
                                        _matSelectedName != null ? _matFormatError : null,
                                  ),
                                  onChanged: (value) {
                                    setState(() {
                                      _activePaperSlotIndex = 0;
                                      _matFormatCtl.text = value;
                                      _matFormatCtl.selection = controller.selection;
                                      _matSelectedFormat = null;
                                      _matSelectedGrammage = null;
                                      _matGramCtl.text = '';
                                      _matFormatError = (value.trim().isEmpty ||
                                              formatOptions
                                                  .map((e) => e.toLowerCase())
                                                  .contains(
                                                      value.trim().toLowerCase()))
                                          ? null
                                          : 'Выберите формат из списка';
                                      final lowerF = formatOptions
                                          .map((e) => e.toLowerCase())
                                          .toList();
                                      final typed = value.trim().toLowerCase();
                                      if (lowerF.contains(typed)) {
                                        _matSelectedFormat =
                                            formatOptions[lowerF.indexOf(typed)];
                                      }
                                    });
                                    _scheduleStagePreviewUpdate();
                                  },
                                  onSubmitted: (_) => onFieldSubmitted(),
                                );
                              },
                              onSelected: (value) {
                                setState(() {
                                  _activePaperSlotIndex = 0;
                                  _matFormatCtl.text = value;
                                  _matSelectedFormat = value;
                                  _matSelectedGrammage = null;
                                  _matGramCtl.text = '';
                                  _matFormatError = null;
                                  _matGramError = null;
                                });
                                _scheduleStagePreviewUpdate();
                              },
                            ),
                            const SizedBox(height: 4),
                            Autocomplete<String>(
                              optionsBuilder: (text) => filter(gramOptions, text.text),
                              displayStringForOption: (s) => s,
                              fieldViewBuilder:
                                  (ctx, controller, focusNode, onFieldSubmitted) {
                                if (controller.text != _matGramCtl.text) {
                                  controller.value = _matGramCtl.value;
                                }
                                return TextField(
                                  controller: controller,
                                  focusNode: focusNode,
                                  enabled: _matSelectedName != null &&
                                      _matSelectedFormat != null,
                                  decoration:
                                      mainPaperDecoration('Грамаж').copyWith(
                                    helperText: (_matSelectedName != null &&
                                            _matSelectedFormat != null)
                                        ? null
                                        : 'Сначала выберите формат',
                                    errorText: (_matSelectedName != null &&
                                            _matSelectedFormat != null)
                                        ? _matGramError
                                        : null,
                                  ),
                                  onChanged: (value) {
                                    setState(() {
                                      _activePaperSlotIndex = 0;
                                      _matGramCtl.text = value;
                                      _matGramCtl.selection = controller.selection;
                                      _matSelectedGrammage = null;
                                      _matGramError = (value.trim().isEmpty ||
                                              gramOptions
                                                  .map((e) => e.toLowerCase())
                                                  .contains(
                                                      value.trim().toLowerCase()))
                                          ? null
                                          : 'Выберите грамаж из списка';
                                      final lowerG =
                                          gramOptions.map((e) => e.toLowerCase()).toList();
                                      final typed = value.trim().toLowerCase();
                                      if (lowerG.contains(typed)) {
                                        _matSelectedGrammage =
                                            gramOptions[lowerG.indexOf(typed)];
                                      }
                                    });
                                    _scheduleStagePreviewUpdate();
                                  },
                                  onSubmitted: (_) => onFieldSubmitted(),
                                );
                              },
                              onSelected: (value) {
                                setState(() {
                                  _activePaperSlotIndex = 0;
                                  _matGramCtl.text = value;
                                  _matSelectedGrammage = value;
                                  _matGramError = null;
                                  final tmc = findExact(
                                      _matSelectedName!, _matSelectedFormat!, value);
                                  if (tmc != null) {
                                    _selectMaterial(tmc);
                                  }
                                });
                              },
                            ),
                            Row(
                              children: [
                                Expanded(
                                  child: TextFormField(
                                    initialValue: product.widthB != null
                                        ? _formatDecimal(product.widthB!)
                                        : '',
                                    autovalidateMode:
                                        AutovalidateMode.onUserInteraction,
                                    decoration: mainPaperDecoration('Ширина b'),
                                    keyboardType: TextInputType.number,
                                    validator: (value) {
                                      final parsed = double.tryParse(
                                          (value ?? '').replaceAll(',', '.'));
                                      final paper =
                                          _selectedMaterial ?? const MaterialModel(name: '');
                                      return _validatePaperWidthB(
                                        widthB: parsed,
                                        paper: paper,
                                        isMain: true,
                                      );
                                    },
                                    onChanged: (val) {
                                      final normalized = val.replaceAll(',', '.');
                                      product.widthB = double.tryParse(normalized);
                                      _scheduleStagePreviewUpdate();
                                    },
                                  ),
                                ),
                                if (_isBlockVisible(
                                    kOrderFormBlockBlQuantity)) ...[
                                  const SizedBox(width: 8),
                                  Expanded(
                                    child: TextFormField(
                                      initialValue:
                                          product.blQuantity?.toString() ?? '',
                                      decoration:
                                          mainPaperDecoration('Количество'),
                                      keyboardType: TextInputType.text,
                                      onChanged: (val) {
                                        final trimmed = val.trim();
                                        product.blQuantity =
                                            trimmed.isEmpty ? null : trimmed;
                                        _scheduleStagePreviewUpdate();
                                      },
                                    ),
                                  ),
                                ],
                                const SizedBox(width: 8),
                                Expanded(
                                  child: TextFormField(
                                    initialValue:
                                        product.length != null ? _formatDecimal(product.length!) : '',
                                    decoration: mainPaperDecoration('Длина L')
                                        .copyWith(
                                      errorMaxLines: 2,
                                      // Считаем на месте, а не по флагу
                                      // состояния: резерв бумаги приезжает
                                      // после открытия формы, и заказ с уже
                                      // сохранённой «Длиной L» оставался бы
                                      // без подсветки, пока сотрудник не
                                      // тронет поле.
                                      errorText: _paperLengthExceedsAvailable(
                                        _selectedMaterialTmc ??
                                            _resolvePaperByText(),
                                        product.length,
                                      )
                                          ? kNotEnoughMaterialError
                                          : null,
                                    ),
                                    keyboardType: TextInputType.number,
                                    onChanged: (val) {
                                      final normalized = val.replaceAll(',', '.');
                                      final d = double.tryParse(normalized);
                                      setState(() {
                                        product.length = d;
                                      });
                                      _scheduleStagePreviewUpdate();
                                    },
                                  ),
                                ),
                              ],
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                );
              },
            ),
          ),
          const SizedBox(height: 3),
          _buildExtraPaperSelectors(labelWidth: labelWidth),
          _paperGutterRow(
            labelWidth: labelWidth,
            card: Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                onPressed: _addExtraPaperSlot,
                icon: const Icon(Icons.add),
                label:
                    Text('Добавить бумагу №${_extraPaperMaterials.length + 2}'),
              ),
            ),
          ),
          const SizedBox(height: 3),
        ],
      ),
    );
    if (!_paperLockedByUsage) return section;
    // Бумагу уже списали на этапе бумаги (или закрыли этап): правка здесь
    // разошлась бы со складом. Менять бумагу можно только в окне расхода
    // бумаги на самом этапе.
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Row(
            children: [
              const Icon(Icons.lock_outline, size: 16, color: Colors.black54),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  'Бумага уже списана на этапе — изменить её можно только '
                  'сотруднику этапа в окне «Расход бумаги».',
                  style: TextStyle(fontSize: 13, color: Colors.grey.shade700),
                ),
              ),
            ],
          ),
        ),
        IgnorePointer(child: Opacity(opacity: 0.6, child: section)),
      ],
    );
  }

  /// Бумага заказа уже списывалась по факту или этап бумаги закрыт.
  bool get _paperLockedByUsage {
    final usage = _paperUsage;
    if (usage == null) return false;
    return usage.closed || usage.totalWritten > 0;
  }

  Widget _buildFieldGrid(
    List<Widget> fields, {
    double breakpoint = 720,
    double spacing = 8,
    double runSpacing = 4,
    double minItemWidth = 260,
    int maxColumns = 2,
  }) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final maxWidth = constraints.maxWidth;
        int columns = maxWidth >= breakpoint ? maxColumns : 1;
        columns = columns.clamp(1, maxColumns);
        double width = columns == 1
            ? maxWidth
            : (maxWidth - spacing * (columns - 1)) / columns;
        while (columns > 1 && width < minItemWidth) {
          columns -= 1;
          width = columns == 1
              ? maxWidth
              : (maxWidth - spacing * (columns - 1)) / columns;
        }
        return Wrap(
          spacing: spacing,
          runSpacing: runSpacing,
          children: fields
              .map((child) => SizedBox(
                    width: columns == 1 ? maxWidth : width,
                    child: child,
                  ))
              .toList(),
        );
      },
    );
  }

  Widget _buildSectionCard({
    required BuildContext context,
    required String title,
    required List<Widget> children,
    bool wrapWithCard = true,
  }) {
    final content = Padding(
      padding: const EdgeInsets.all(4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            title,
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const SizedBox(height: 4),
          ...children,
        ],
      ),
    );

    if (!wrapWithCard) return content;

    return Card(
      margin: EdgeInsets.zero,
      child: content,
    );
  }

  Widget _buildOrderSectionCard({
    required String title,
    required IconData icon,
    required Color backgroundColor,
    required Color accentColor,
    required Widget child,
  }) {
    // Карточка белая с тонкой рамкой: цветом теперь отвечает только значок
    // в шапке. Заливка всей колонки цветом делала форму пёстрой, а поля в
    // ней — малоконтрастными.
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: OrderFormColors.surface,
        borderRadius: BorderRadius.circular(OrderFormMetrics.cardRadius),
        border: Border.all(color: OrderFormColors.border),
        boxShadow: const [
          BoxShadow(
            color: Color(0x0A000000),
            blurRadius: 3,
            offset: Offset(0, 1),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          OrderSectionHead(
            icon: icon,
            label: title,
            color: accentColor,
            background: backgroundColor,
          ),
          child,
        ],
      ),
    );
  }

  Widget _buildLabelRow({
    required String label,
    required Widget child,
    double labelWidth = OrderFormMetrics.labelWidth,
    String? labelNote,
  }) {
    final labelWidget = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          label,
          style: const TextStyle(fontSize: 12, color: OrderFormColors.label),
        ),
        if (labelNote != null) ...[
          const SizedBox(height: 2),
          Text(
            labelNote,
            softWrap: true,
            maxLines: 3,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(context)
                .textTheme
                .bodySmall
                ?.copyWith(fontSize: 11, height: 1.1),
          ),
        ],
      ],
    );

    return LayoutBuilder(
      builder: (context, constraints) {
        final bool stackVertically = constraints.maxWidth < labelWidth + 80;
        // Строки разделены тонкой линией, как в макете: подпись слева
        // фиксированной ширины, поле — на остатке.
        return Container(
          padding: const EdgeInsets.symmetric(vertical: 5),
          decoration: const BoxDecoration(
            border: Border(
              bottom: BorderSide(color: OrderFormColors.divider),
            ),
          ),
          child: stackVertically
              ? Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    labelWidget,
                    const SizedBox(height: 4),
                    child,
                  ],
                )
              : Row(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    SizedBox(
                      width: labelWidth,
                      child: labelWidget,
                    ),
                    const SizedBox(width: 8),
                    Expanded(child: child),
                  ],
                ),
        );
      },
    );
  }

  Widget _buildDimensionsField() {
    Widget dimField({
      required TextEditingController controller,
      required String label,
      required void Function(double value) onChanged,
    }) {
      return TextFormField(
        controller: controller,
        decoration: InputDecoration(
          labelText: label,
          border: const OutlineInputBorder(),
        ),
        textInputAction: TextInputAction.next,
        keyboardType: const TextInputType.numberWithOptions(decimal: true),
        onFieldSubmitted: (_) => FocusScope.of(context).nextFocus(),
        onChanged: (value) {
          final parsed = double.tryParse(value.replaceAll(',', '.')) ?? 0;
          // Бизнес-логика: размеры теперь вводятся раздельно (д/ш/г),
          // но сохраняются в те же поля модели для обратной совместимости.
          onChanged(parsed);
          _scheduleStagePreviewUpdate();
        },
      );
    }

    return Row(
      children: [
        Expanded(
          child: dimField(
            controller: _lengthController,
            label: 'Длина',
            onChanged: (value) => _product.width = value,
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: dimField(
            controller: _widthController,
            label: 'Ширина',
            onChanged: (value) => _product.height = value,
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: dimField(
            controller: _depthController,
            label: 'Глубина',
            onChanged: (value) => _product.depth = value,
          ),
        ),
      ],
    );
  }

  Widget _buildProductTypeField() {
    return Consumer<ProductsProvider>(
      builder: (context, provider, _) {
        final items = _categoryTitles;
        return DropdownButtonFormField<String>(
          value: items.contains(_product.type) ? _product.type : null,
          decoration: const InputDecoration(
            labelText: 'Наименование изделия',
            border: OutlineInputBorder(),
          ),
          items: items
              .map((t) => DropdownMenuItem(value: t, child: Text(t)))
              .toList(),
          onChanged: (val) {
            var shouldUpdateStagePreview = false;
            setState(() {
              _product.type = val ?? '';
              if (!_isBlockVisible(kOrderFormBlockCardboard)) {
                _cardboardChecked = false;
                _selectedCardboard = 'нет';
                shouldUpdateStagePreview = true;
              }
              _selectedStockExtraRow = null;
              _stockExtraResults = [];
              _stockExtra = null;
              _stockExtraSelectedQty = null;
              _stockExtraQtyTouched = false;
              _product.leftover = null;
            });
            _scheduleStagePreviewUpdate(
              immediate: shouldUpdateStagePreview,
            );
            // Опции заведены на тип продукта: выбранное для прежнего типа к
            // новому отношения не имеет, поэтому снимок не переносим.
            _loadExtraOptions(saved: const <OrderOptionSelection>[]);
            _stockExtraSearchDebounce?.cancel();
            _stockExtraSearchController.clear();
            _updateStockExtraQtyController();
            if (_stockExtraAutoloaded) {
              _updateStockExtra(includeAllResults: true);
            }
          },
        );
      },
    );
  }

  Widget _buildQuantityField() {
    return TextFormField(
      initialValue: _product.quantity > 0 ? _product.quantity.toString() : '',
      decoration: const InputDecoration(
        labelText: 'Тираж',
        border: OutlineInputBorder(),
      ),
      keyboardType: TextInputType.number,
      onChanged: (val) {
        final qty = int.tryParse(val) ?? 0;
        _product.quantity = qty;
        _scheduleStagePreviewUpdate();
      },
      validator: (value) {
        if (value == null || value.trim().isEmpty) {
          return 'Введите тираж';
        }
        final qty = int.tryParse(value);
        if (qty == null || qty <= 0) {
          return 'Тираж должен быть > 0';
        }
        return null;
      },
    );
  }

  Widget _buildMakereadyFields() {
    return _buildFieldGrid([
      TextFormField(
        initialValue: _makeready > 0 ? _formatDecimal(_makeready) : '',
        decoration: const InputDecoration(
          labelText: 'Приладка',
          border: OutlineInputBorder(),
        ),
        keyboardType: TextInputType.number,
        onChanged: (v) {
          final normalized = v.replaceAll(',', '.');
          _makeready = double.tryParse(normalized) ?? 0;
        },
      ),
      TextFormField(
        initialValue: _val > 0 ? _formatDecimal(_val) : '',
        decoration: const InputDecoration(
          labelText: 'ВАЛ',
          border: OutlineInputBorder(),
        ),
        keyboardType: TextInputType.number,
        onChanged: (v) {
          final normalized = v.replaceAll(',', '.');
          _val = double.tryParse(normalized) ?? 0;
        },
      ),
    ], breakpoint: 680, minItemWidth: 200);
  }

  Widget _buildContractsRow() {
    return Wrap(
      spacing: 6,
      runSpacing: 3,
      children: [
      ],
    );
  }

  Widget _buildOrderInfoSection(BuildContext context,
      {bool wrapWithCard = true}) {
    final content = [
        _buildFieldGrid([
          _buildManagerField(),
          _buildCustomerField(),
          _buildDatePickerField(
            label: 'Дата заказа',
            value: _orderDate,
            onTap: _pickOrderDate,
            emptyError: 'Укажите дату заказа',
          ),
          _buildDatePickerField(
            label: 'Срок выполнения',
            value: _dueDate,
            onTap: _pickDueDate,
            emptyError: 'Укажите срок',
          ),
        ], maxColumns: 2),
      ];

    if (!wrapWithCard) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: content,
      );
    }

    return _buildSectionCard(
      context: context,
      title: 'Информация о заказе',
      children: content,
    );
  }

  Widget _buildHandlesSection(BuildContext context,
      {bool wrapWithCard = true}) {
    final content = Consumer<WarehouseProvider>(
      builder: (context, warehouse, _) {
            final seen = <String>{};
            final List<TmcModel> handleItems = [
              ...warehouse.getTmcByType('Ручки'),
              ...warehouse.getTmcByType('ручки'),
            ].where((item) => seen.add(item.id)).toList(growable: true);
            handleItems.sort((a, b) => a.description
                .toLowerCase()
                .compareTo(b.description.toLowerCase()));

            TmcModel? _findHandleMatch() {
              if (_selectedHandleDescription == '-' ||
                  _selectedHandleDescription.trim().isEmpty) {
                return null;
              }
              final target = _selectedHandleDescription.trim().toLowerCase();
              for (final item in handleItems) {
                final desc = item.description.trim().toLowerCase();
                if (desc == target) {
                  return item;
                }
              }
              return null;
            }

            if (_selectedHandleId == null &&
                _selectedHandleDescription != '-' &&
                _selectedHandleDescription.trim().isNotEmpty) {
              final match = _findHandleMatch();
              if (match != null) {
                WidgetsBinding.instance.addPostFrameCallback((_) {
                  if (!mounted) return;
                  setState(() {
                    _selectedHandleId = match.id;
                    _selectedHandleDescription = match.description;
                  });
                });
              }
            }

            final bool hasSelectedHandle = _selectedHandleId != null &&
                handleItems.any((item) => item.id == _selectedHandleId);

            final dropdownItems = <DropdownMenuItem<String?>>[
              const DropdownMenuItem<String?>(
                value: null,
                child: Text('-'),
              ),
              ...handleItems.map(
                (item) => DropdownMenuItem<String?>(
                  value: item.id,
                  child: Text(
                      item.description.isEmpty ? item.id : item.description),
                ),
              ),
              if (!hasSelectedHandle &&
                  _selectedHandleId != null &&
                  _selectedHandleDescription != '-')
                DropdownMenuItem<String?>(
                  value: _selectedHandleId,
                  child: Text(_selectedHandleDescription),
                ),
            ];

            final supportsCardboard = _isBlockVisible(kOrderFormBlockCardboard);
            final extras = Wrap(
              // Reduce spacing to shrink the area used by the checkboxes.
              spacing: 6,
              runSpacing: 3,
              children: [
                // Выключенный блок не показывается вовсе, а не гаснет: серая
                // галочка выглядит как «сейчас нельзя, но вообще бывает» и
                // сотрудник ищет, чем её включить.
                if (supportsCardboard)
                  _buildCompactCheckboxTile(
                    value: _cardboardChecked,
                    onChanged: (val) => setState(() {
                      _cardboardChecked = val ?? false;
                      _selectedCardboard = _cardboardChecked ? 'есть' : 'нет';
                      _scheduleStagePreviewUpdate(immediate: true);
                    }),
                    label: 'Картон',
                    width: 100,
                  ),
                if (_isBlockVisible(kOrderFormBlockTrimming))
                  _buildCompactCheckboxTile(
                    value: _trimming,
                    onChanged: (val) => setState(() {
                      _trimming = val ?? false;
                      _scheduleStagePreviewUpdate(immediate: true);
                    }),
                    label: 'Подрезка',
                    width: 100,
                  ),
              ],
            );

            return _buildFieldGrid([
              if (_isBlockVisible(kOrderFormBlockHandle))
                DropdownButtonFormField<String?>(
                value: hasSelectedHandle
                    ? _selectedHandleId
                    : (_selectedHandleId != null &&
                            _selectedHandleDescription != '-'
                        ? _selectedHandleId
                        : null),
                decoration: const InputDecoration(
                  labelText: 'Ручки',
                  border: OutlineInputBorder(),
                ),
                items: dropdownItems,
                onChanged: (val) {
                  setState(() {
                    _selectedHandleId = val;
                    if (val == null) {
                      _selectedHandleDescription = '-';
                    } else {
                      final matches =
                          handleItems.where((item) => item.id == val).toList();
                      if (matches.isEmpty) {
                        _selectedHandleDescription =
                            _selectedHandleDescription == '-'
                                ? '-'
                                : _selectedHandleDescription;
                      } else {
                        final desc = matches.first.description.trim();
                        _selectedHandleDescription =
                            desc.isEmpty ? '-' : matches.first.description;
                      }
                    }
                    _scheduleStagePreviewUpdate(immediate: true);
                  });
                },
              ),
              TextFormField(
                controller: _packagingController,
                decoration: const InputDecoration(
                  labelText: 'Упаковка',
                  hintText: 'Например: по 50 шт ',
                  border: OutlineInputBorder(),
                ),
              ),
              extras,
            ],
                breakpoint: 620,
                maxColumns: 2,
                minItemWidth: 220,
                runSpacing: 8,
                spacing: 8);
          },
    );

    if (!wrapWithCard) return content;

    return _buildSectionCard(
      context: context,
      title: 'Дополнительные параметры',
      children: [content],
    );
  }

  Widget _buildManagerField() {
    return TextFormField(
      controller: _managerDisplayController,
      readOnly: true,
      decoration: const InputDecoration(
        labelText: 'Менеджер',
        border: OutlineInputBorder(),
        hintText: '—',
      ),
      validator: (_) {
        final resolvedName = (_selectedManager?.trim().isNotEmpty ?? false)
            ? _selectedManager!.trim()
            : (widget.order?.manager ?? '');
        if (resolvedName.isEmpty) {
          return 'Менеджер не определён';
        }
        return null;
      },
    );
  }
  // Scale factors for compact toggles (≈40% smaller).
  static const double _kCompactCheckboxScale = 0.6;
  static const double _kCompactSwitchScale = 0.6;

  Widget _buildCompactSwitchTile({
    required bool value,
    required ValueChanged<bool>? onChanged,
    required String label,
  }) {
    final theme = Theme.of(context);
    final enabled = onChanged != null;

    return InkWell(
      borderRadius: BorderRadius.circular(10),
      onTap: enabled ? () => onChanged(!value) : null,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: Row(
          children: [
            Expanded(
              child: Text(
                label,
                maxLines: 1,
                softWrap: false,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodyMedium?.copyWith(
                  fontSize: 13,
                  height: 1.1,
                  color: enabled ? null : theme.disabledColor,
                ),
              ),
            ),
            const SizedBox(width: 8),
            Transform.scale(
              scale: _kCompactSwitchScale,
              child: Switch(
                value: value,
                onChanged: onChanged,
                materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildCompactCheckboxTile({
    required bool value,
    required ValueChanged<bool?>? onChanged,
    required String label,
    bool enabled = true,
    double? width,
  }) {
    final theme = Theme.of(context);
    final effectiveOnChanged = enabled ? onChanged : null;

    final tile = InkWell(
      borderRadius: BorderRadius.circular(10),
      onTap: effectiveOnChanged == null
          ? null
          : () => effectiveOnChanged(!value),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 1),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Transform.scale(
              scale: _kCompactCheckboxScale,
              alignment: Alignment.centerLeft,
              child: Checkbox(
                value: value,
                onChanged: effectiveOnChanged,
                visualDensity: VisualDensity.compact,
                materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
            ),
            const SizedBox(width: 4),
            Expanded(
              child: Text(
                label,
                maxLines: 1,
                softWrap: false,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodyMedium?.copyWith(
                  fontSize: 13,
                  height: 1.1,
                ),
              ),
            ),
          ],
        ),
      ),
    );

    if (width == null) return tile;
    return SizedBox(width: width, child: tile);
  }

  Widget _buildCustomerField() {
    return TextFormField(
      controller: _customerController,
      decoration: const InputDecoration(
        labelText: 'Заказчик',
        border: OutlineInputBorder(),
      ),
      onChanged: (_) {
        setState(() {});
        _updateStockExtra();
      },
      validator: (value) {
        if (value == null || value.trim().isEmpty) {
          return 'Введите заказчика';
        }
        return null;
      },
    );
  }

  Widget _buildFormExtraInfoField() {
    return TextFormField(
      controller: _formExtraInfoController,
      decoration: const InputDecoration(
        labelText: 'Доп. информация формы',
        hintText: 'Необязательно',
        border: OutlineInputBorder(),
      ),
    );
  }

  Widget _buildDatePickerField({
    required String label,
    required DateTime? value,
    required Future<void> Function(BuildContext context) onTap,
    required String emptyError,
  }) {
    return GestureDetector(
      onTap: () => onTap(context),
      child: AbsorbPointer(
        child: TextFormField(
          controller: TextEditingController(
            text: value != null ? _formatDate(value) : '',
          ),
          decoration: InputDecoration(
            labelText: label,
            border: const OutlineInputBorder(),
          ),
          validator: (text) {
            if (text == null || text.trim().isEmpty) {
              return emptyError;
            }
            return null;
          },
        ),
      ),
    );
  }

  Widget _buildStockExtraLayout(
    Widget searchColumn, [
    Widget? writeOffSwitch,
  ]) {
    // Показываем остаток и подбор лишнего по категории.
    return searchColumn;
  }

  void _ensureStockExtrasLoaded() {
    if (_stockExtraAutoloaded) return;
    _stockExtraAutoloaded = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _updateStockExtra(includeAllResults: true);
    });
  }

  Widget _buildWarehousePreviewPanel() {
    _ensureStockExtrasLoaded();
    return Consumer<WarehouseProvider>(
      builder: (context, warehouse, _) {
        final papers = _paperItems()
          ..sort((a, b) => a.description.toLowerCase().compareTo(
                b.description.toLowerCase(),
              ));
        final paints = warehouse.getTmcByType('Краска').toList(growable: true)
          ..sort((a, b) => a.description.toLowerCase().compareTo(
                b.description.toLowerCase(),
              ));
        final categoryItems = _stockExtraResults;

        return Container(
          decoration: BoxDecoration(
            color: OrderFormColors.surface,
            borderRadius:
                BorderRadius.circular(OrderFormMetrics.cardRadius),
            border: Border.all(color: OrderFormColors.border),
            boxShadow: const [
              BoxShadow(
                color: Color(0x1A000000),
                blurRadius: 24,
                offset: Offset(0, 4),
              ),
            ],
          ),
          clipBehavior: Clip.antiAlias,
          child: DefaultTabController(
            length: 3,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const TabBar(
                  labelColor: OrderFormColors.accent,
                  unselectedLabelColor: OrderFormColors.label,
                  indicatorColor: OrderFormColors.accent,
                  indicatorSize: TabBarIndicatorSize.tab,
                  dividerColor: OrderFormColors.border,
                  labelStyle: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                  ),
                  unselectedLabelStyle: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                  ),
                  tabs: [
                    Tab(height: 40, text: 'Бумага'),
                    Tab(height: 40, text: 'Краски'),
                    Tab(height: 40, text: 'Категории'),
                  ],
                ),
                Expanded(
                  child: TabBarView(
                    children: [
                      _buildPaperWarehouseView(papers),
                      _buildPaintWarehouseView(paints),
                      _buildCategoryWarehouseView(categoryItems),
                    ],
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  /// Строка склада в панели материалов: название и спецификация мелким.
  Widget _warehouseTile({
    required String title,
    required String subtitle,
    required VoidCallback onTap,
  }) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(8),
        hoverColor: OrderFormColors.fieldFill,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w500,
                  color: OrderFormColors.text,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                subtitle,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                // Спецификация — формат, граммаж, остаток — это то, по чему
                // менеджер и выбирает строку, а не второстепенная подпись.
                // Серым (label) она читалась хуже названия, хотя решение
                // принимают именно по ней.
                style: const TextStyle(
                  fontSize: 10.5,
                  color: OrderFormColors.text,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildPaperWarehouseView(List<TmcModel> papers) {
    if (papers.isEmpty) {
      return const Center(child: Text('На складе нет бумаги'));
    }
    // Панель показывает ДОСТУПНОЕ, а не складское. Складская цифра включает
    // метры, забронированные чужими заказами: выбрав по ней бумагу, менеджер
    // получал заказ, который тут же вставал в «Ожидание материалов».
    double availableOf(TmcModel paper) =>
        availablePaperQtyById(paper.id, fallbackStock: paper.quantity) ??
        paper.quantity;

    final filtered = papers.where((paper) {
      return _matchesWarehouseQuery(_paperSearch, [
        paper.description,
        paper.format ?? '',
        paper.grammage ?? '',
        paper.note ?? '',
        availableOf(paper).toStringAsFixed(2),
      ]);
    }).toList();
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 12, 12, 4),
          child: TextField(
            controller: _paperSearchController,
            decoration: InputDecoration(
              labelText: 'Поиск бумаги',
              prefixIcon: const Icon(Icons.search),
              suffixIcon: _paperSearch.isEmpty
                  ? null
                  : IconButton(
                      icon: const Icon(Icons.clear),
                      onPressed: () {
                        setState(() {
                          _paperSearch = '';
                          _paperSearchController.clear();
                        });
                      },
                    ),
              border: const OutlineInputBorder(),
              isDense: true,
            ),
            onChanged: (value) => setState(() => _paperSearch = value),
          ),
        ),
        const SizedBox(height: 4),
        Expanded(
          child: filtered.isEmpty
              ? const Center(child: Text('Нет бумаги по текущему запросу'))
              : Scrollbar(
                  controller: _paperListController,
                  thumbVisibility: true,
                  child: ListView.separated(
                    controller: _paperListController,
                    padding:
                        const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                    itemBuilder: (context, index) {
                      final paper = filtered[index];
                      // Спецификация сокращена до «Ф • Г • М»: панель узкая,
                      // и полные подписи обрезались на первом же слове.
                      final subtitle = [
                        if ((paper.format ?? '').isNotEmpty)
                          'Ф: ${paper.format}',
                        if ((paper.grammage ?? '').isNotEmpty)
                          'Г: ${paper.grammage}',
                        'М: ${availableOf(paper).toStringAsFixed(2)}',
                      ].where((part) => part.trim().isNotEmpty).join(' • ');
                      return _warehouseTile(
                        title: paper.description.isEmpty
                            ? 'Без названия'
                            : paper.description,
                        subtitle: subtitle,
                        onTap: () => _applyPaperSelection(paper),
                      );
                    },
                    separatorBuilder: (_, __) => const SizedBox(height: 2),
                    itemCount: filtered.length,
                  ),
                ),
        ),
      ],
    );
  }

  Widget _buildPaintWarehouseView(List<TmcModel> paints) {
    if (paints.isEmpty) {
      return const Center(child: Text('На складе нет красок'));
    }
    final filtered = paints.where((paint) {
      final qty = _stockQtyToGrams(paint).toStringAsFixed(2);
      return _matchesWarehouseQuery(_paintSearch, [
        paint.description,
        paint.note ?? '',
        qty,
      ]);
    }).toList();
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 12, 12, 4),
          child: TextField(
            controller: _paintSearchController,
            decoration: InputDecoration(
              labelText: 'Поиск красок',
              prefixIcon: const Icon(Icons.search),
              suffixIcon: _paintSearch.isEmpty
                  ? null
                  : IconButton(
                      icon: const Icon(Icons.clear),
                      onPressed: () {
                        setState(() {
                          _paintSearch = '';
                          _paintSearchController.clear();
                        });
                      },
                    ),
              border: const OutlineInputBorder(),
              isDense: true,
            ),
            onChanged: (value) => setState(() => _paintSearch = value),
          ),
        ),
        const SizedBox(height: 4),
        Expanded(
          child: filtered.isEmpty
              ? const Center(child: Text('Нет красок по текущему запросу'))
              : Scrollbar(
                  controller: _paintListController,
                  thumbVisibility: true,
                  child: ListView.separated(
                    controller: _paintListController,
                    padding:
                        const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                    itemBuilder: (context, index) {
                      final paint = filtered[index];
                      ImageProvider? preview;
                      if ((paint.imageBase64 ?? '').isNotEmpty) {
                        try {
                          preview =
                              MemoryImage(base64Decode(paint.imageBase64!));
                        } catch (_) {}
                      }
                      if (preview == null &&
                          (paint.imageUrl ?? '').isNotEmpty) {
                        preview = NetworkImage(paint.imageUrl!);
                      }
                      final qty = _stockQtyToGrams(paint);
                      final subtitle = [
                        'Цвет: ${paint.note ?? '—'}',
                        'Количество: ${qty.toStringAsFixed(2)} г',
                      ].join(' • ');
                      return ListTile(
                        dense: true,
                        leading: preview != null
                            ? CircleAvatar(backgroundImage: preview)
                            : const CircleAvatar(child: Icon(Icons.color_lens)),
                        title: Text(
                          paint.description.isEmpty
                              ? 'Без названия'
                              : paint.description,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        subtitle: Text(
                          subtitle,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        onTap: () => _addPaintFromTmc(paint),
                      );
                    },
                    separatorBuilder: (_, __) => const Divider(height: 1),
                    itemCount: filtered.length,
                  ),
                ),
        ),
      ],
    );
  }

  Widget _buildCategoryWarehouseView(List<Map<String, dynamic>> rows) {
    if (_loadingStockExtra) {
      return const Center(child: CircularProgressIndicator());
    }
    final filtered = rows.where((row) {
      final description = (row['description'] ?? '').toString();
      final sizeLabel = (row['size'] ?? '').toString();
      final qtyValue = row['quantity'];
      final qty = (qtyValue is num)
          ? qtyValue.toDouble()
          : double.tryParse('$qtyValue') ?? 0.0;
      return _matchesWarehouseQuery(_categorySearch, [
        description,
        sizeLabel,
        qty.toStringAsFixed(2),
        (row['code'] ?? '').toString(),
      ]);
    }).toList();

    Widget buildEmptyState() {
      if (rows.isEmpty) {
        return Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('Нет записей по текущей категории продукта.'),
              const SizedBox(height: 4),
              ElevatedButton.icon(
                onPressed: () => _updateStockExtra(includeAllResults: true),
                icon: const Icon(Icons.refresh),
                label: const Text('Обновить склад'),
              ),
            ],
          ),
        );
      }
      return const Center(child: Text('Нет результатов по текущему запросу'));
    }

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 12, 12, 4),
          child: TextField(
            controller: _categorySearchController,
            decoration: InputDecoration(
              labelText: 'Поиск по категориям',
              prefixIcon: const Icon(Icons.search),
              suffixIcon: _categorySearch.isEmpty
                  ? null
                  : IconButton(
                      icon: const Icon(Icons.clear),
                      onPressed: () {
                        setState(() {
                          _categorySearch = '';
                          _categorySearchController.clear();
                        });
                      },
                    ),
              border: const OutlineInputBorder(),
              isDense: true,
            ),
            onChanged: (value) => setState(() => _categorySearch = value),
          ),
        ),
        const SizedBox(height: 4),
        Expanded(
          child: filtered.isEmpty
              ? buildEmptyState()
              : Scrollbar(
                  controller: _categoryListController,
                  thumbVisibility: true,
                  child: ListView.separated(
                    controller: _categoryListController,
                    padding:
                        const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                    itemBuilder: (context, index) {
                      final row = filtered[index];
                      final description =
                          (row['description'] ?? '').toString().trim();
                      final sizeLabel = (row['size'] ?? '').toString().trim();
                      final qv = row['quantity'];
                      final qty = (qv is num)
                          ? qv.toDouble()
                          : double.tryParse('$qv') ?? 0.0;
                      final subtitleParts = <String>[];
                      subtitleParts
                          .add('Количество: ${qty.toStringAsFixed(2)}');
                      if (sizeLabel.isNotEmpty) {
                        subtitleParts.add('Размер: $sizeLabel');
                      }
                      return _warehouseTile(
                        title:
                            description.isEmpty ? 'Без названия' : description,
                        subtitle: subtitleParts.join(' • '),
                        onTap: () => _selectStockExtraRow(row),
                      );
                    },
                    separatorBuilder: (_, __) => const Divider(height: 1),
                    itemCount: filtered.length,
                  ),
                ),
        ),
      ],
    );
  }

  Widget _buildProductionSection(BuildContext context,
      {bool wrapWithCard = true, bool includeMakeready = true}) {
    final children = <Widget>[];
    final queueActual = isQueueActual(
      currentSignature: _currentQueueSignature(),
      storedSignature: _queueSignature,
      queueBuildStatus: _queueBuildStatus,
      stages: _stagePreviewStages,
    );
    children.add(
      Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: FilledButton.icon(
          style: FilledButton.styleFrom(
            backgroundColor: queueActual ? Colors.green : null,
          ),
          onPressed: _buildStageQueue,
          icon: const Icon(Icons.auto_fix_high),
          label: Text(queueActual ? 'Очередь собрана' : 'Собрать очередь'),
        ),
      ),
    );
    if (_queueBuildStatus == QueueBuildStatus.outdated) {
      // Заказ, у которого очередь уже была собрана, сохранение пересоберёт
      // само и в черновик не уронит — пугать этим нельзя. Требование нажать
      // кнопку остаётся только для заказов, где маршрут ещё не подтверждали.
      final bool willRebuildOnSave =
          (widget.order?.assignmentCreated ?? false) ||
              widget.order?.queueBuildStatus == QueueBuildStatus.built;
      children.add(
        Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: Text(
            willRebuildOnSave
                ? 'Очередь изменилась — при сохранении она будет пересобрана '
                    'автоматически. Нажмите «Собрать очередь», чтобы увидеть '
                    'маршрут заранее'
                : 'Очередь изменилась. Нажмите «Собрать очередь» перед '
                    'сохранением, иначе заказ останется черновиком',
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: willRebuildOnSave
                      ? Theme.of(context).colorScheme.onSurfaceVariant
                      : Theme.of(context).colorScheme.error,
                  fontWeight: FontWeight.w600,
                ),
          ),
        ),
      );
    }

    if (includeMakeready) {
      children.add(_buildMakereadyFields());
      children.add(const SizedBox(height: 16));
    }

    children.add(
      Consumer<TemplateProvider>(
        builder: (context, provider, _) {
            final templates = provider.templates;
            if (_stageTemplateId != null && _stageTemplateId!.isNotEmpty) {
              final tpl = _findTemplateById(templates, _stageTemplateId);
              if (tpl != null && _selectedStageTemplateName != tpl.name) {
                WidgetsBinding.instance.addPostFrameCallback((_) {
                  if (!mounted) return;
                  setState(() {
                    _selectedStageTemplateName = tpl.name;
                    _setStageTemplateText(tpl.name);
                    if (!_stagePreviewInitialized) {
                      _stagePreviewInitialized = true;
                    }
                  });
                  _scheduleStagePreviewUpdate(immediate: true);
                });
              }
            }

            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                RawAutocomplete<TemplateModel>(
                  textEditingController: _stageTemplateController,
                  focusNode: _stageTemplateFocusNode,
                  displayStringForOption: (tpl) => tpl.name,
                  optionsBuilder: (TextEditingValue textValue) {
                    final query = textValue.text.toLowerCase().trim();
                    if (query.isEmpty) return templates;
                    return templates
                        .where((tpl) => tpl.name.toLowerCase().contains(query));
                  },
                  fieldViewBuilder:
                      (context, controller, focusNode, onFieldSubmitted) {
                    return TextFormField(
                      controller: controller,
                      focusNode: focusNode,
                      decoration: const InputDecoration(
                        labelText: 'Выберите очередь',
                        border: OutlineInputBorder(),
                      ),
                      onFieldSubmitted: (value) {
                        try {
                          final tpl = templates.firstWhere(
                            (t) => t.name.toLowerCase() == value.toLowerCase(),
                          );
                          _onStageTemplateSelected(tpl);
                        } catch (_) {}
                      },
                    );
                  },
                  onSelected: _onStageTemplateSelected,
                  optionsViewBuilder:
                      (context, onSelected, Iterable<TemplateModel> options) {
                    return Align(
                      alignment: Alignment.topLeft,
                      child: Material(
                        elevation: 4,
                        borderRadius: BorderRadius.circular(8),
                        child: ConstrainedBox(
                          constraints: const BoxConstraints(maxHeight: 200),
                          child: ListView.builder(
                            padding: EdgeInsets.zero,
                            itemCount: options.length,
                            itemBuilder: (context, index) {
                              final option = options.elementAt(index);
                              return ListTile(
                                title: Text(option.name),
                                onTap: () => onSelected(option),
                              );
                            },
                          ),
                        ),
                      ),
                    );
                  },
                ),
                if (_selectedStageTemplateName != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 8.0),
                    child: Text(
                      'Выбрана очередь: ${_selectedStageTemplateName!}',
                      style: Theme.of(context).textTheme.bodyMedium,
                    ),
                  ),
                const SizedBox(height: 3),
                _buildStagePreviewSection(context),
              ],
            );
          },
        ),
    );


    if (wrapWithCard) {
      return _buildSectionCard(
        context: context,
        title: 'Производство',
        children: children,
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: children,
    );

  }

  Widget _buildCommentsSection(BuildContext context,
      {bool wrapWithCard = true}) {
    final content = TextFormField(
      controller: _commentsController,
      decoration: const InputDecoration(
        labelText: 'Комментарии к заказу',
        border: OutlineInputBorder(),
      ),
      minLines: 2,
      maxLines: 5,
    );

    if (!wrapWithCard) return content;

    return _buildSectionCard(
      context: context,
      title: 'Комментарии',
      children: [content],
    );
  }

  Widget _buildStagePreviewSection(BuildContext context) {
    final theme = Theme.of(context);
    if ((_stageTemplateId == null || _stageTemplateId!.isEmpty) &&
        _stagePreviewStages.isEmpty) {
      return Text(
        'Выберите тип продукта и параметры заказа, затем нажмите '
        '«Собрать очередь»',
        style: theme.textTheme.bodySmall,
      );
    }

    if (_stagePreviewLoading) {
      return Row(
        children: [
          const SizedBox(
            width: 16,
            height: 16,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
          const SizedBox(width: 12),
          Text(
            'Загружаем этапы...',
            style: theme.textTheme.bodyMedium,
          ),
        ],
      );
    }

    if (_stagePreviewError != null) {
      return Text(
        _stagePreviewError!,
        style: theme.textTheme.bodyMedium?.copyWith(
          color: theme.colorScheme.error,
        ),
      );
    }

    if (_stagePreviewStages.isEmpty) {
      return Text(
        'Для выбранных параметров заказа не найдено этапов',
        style: theme.textTheme.bodySmall,
      );
    }

    final children = <Widget>[];
    for (var i = 0; i < _stagePreviewStages.length; i++) {
      final stage = _stagePreviewStages[i];
      final title = _resolveStageName(stage);
      final description = (stage['notes'] ??
              stage['description'] ??
              stage['comment'] ??
              stage['memo'] ??
              '')
          .toString()
          .trim();
      final switchableStageKey = _switchableStageKeyFromPreviewStage(stage);
      final stageCard = Container(
        margin: EdgeInsets.only(top: i == 0 ? 0 : 8),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          border: Border.all(color: theme.dividerColor),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('${i + 1}.', style: theme.textTheme.bodyMedium),
            const SizedBox(width: 8),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(
                        child: Text(title, style: theme.textTheme.bodyMedium),
                      ),
                      if (_canSwapBobbinFlexStage(i))
                        Padding(
                          padding: const EdgeInsets.only(left: 8),
                          child: Tooltip(
                            message:
                                'Поменять местами Флексопечать и Бобинорезку',
                            child: IconButton.filledTonal(
                              visualDensity: VisualDensity.compact,
                              constraints: const BoxConstraints.tightFor(
                                width: 32,
                                height: 32,
                              ),
                              padding: EdgeInsets.zero,
                              icon: const Icon(Icons.swap_vert, size: 18),
                              onPressed: _swapBobbinFlexStages,
                            ),
                          ),
                        ),
                    ],
                  ),
                  if (description.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 4),
                      child: Text(
                        description,
                        style: theme.textTheme.bodySmall,
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
      );
      children.add(
        switchableStageKey == null
            ? stageCard
            : Material(
                color: Colors.transparent,
                child: InkWell(
                  borderRadius: BorderRadius.circular(8),
                  onTap: () => _cycleSwitchablePreviewStage(
                    switchableStageKey,
                    stage,
                  ),
                  child: stageCard,
                ),
              ),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: children,
    );
  }

  Widget _buildFormSection({
    required BuildContext context,
    required bool showFormSummary,
    required bool showFormEditor,
    required bool isEditing,
    required bool hasAssignedForm,
    bool wrapWithCard = true,
  }) {
    final content = <Widget>[];
    final controls = <Widget>[];
    if (showFormSummary) {
      controls.add(_buildFormSummary(context));
      if (isEditing && hasAssignedForm) {
        controls.addAll([
          const SizedBox(height: 4),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              onPressed: _startFormEditing,
              icon: const Icon(Icons.edit),
              label: const Text('Изменить форму'),
            ),
          ),
        ]);
      }
    }
    if (showFormEditor) {
      if (controls.isNotEmpty) {
        controls.add(const SizedBox(height: 3));
      }
      if (isEditing && hasAssignedForm) {
        controls.addAll([
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              onPressed: _cancelFormEditing,
              icon: const Icon(Icons.close),
              label: const Text('Отменить изменения формы'),
            ),
          ),
          const SizedBox(height: 4),
        ]);
      }
      controls.addAll(_buildFormEditorControls());
    }

    if (controls.isNotEmpty) {
      controls.add(const SizedBox(height: 3));
    }

    controls.add(
      InputDecorator(
        decoration: const InputDecoration(
          labelText: 'Код формы',
          border: OutlineInputBorder(),
        ),
        child: Text(_formDisplayPreview()),
      ),
    );

    if (controls.isNotEmpty) {
      content.add(Column(children: controls));
    }

    if (wrapWithCard) {
      return _buildSectionCard(
        context: context,
        title: 'Форма',
        children: content,
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: content,
    );
  }

  Widget _buildPaintsSection({bool wrapWithCard = true}) {
    final content = [
        TextFormField(
          controller: _paintInfoController,
          decoration: const InputDecoration(
            labelText: 'Информация для красок',
            hintText: 'Комментарий применяется ко всем краскам',
            border: OutlineInputBorder(),
          ),
          minLines: 1,
          maxLines: 3,
          onChanged: (value) {
            final normalized = value.trim();
            setState(() {
              _paintInfo = normalized;
              for (final paint in _paints) {
                paint.memo = normalized;
              }
            });
          },
        ),
        const SizedBox(height: 3),
        ...List.generate(_paints.length, (i) {
          final row = _paints[i];
          return Padding(
            padding: const EdgeInsets.only(bottom: 8.0),
            child: LayoutBuilder(
              builder: (context, constraints) {
                final isCompact = constraints.maxWidth < 520;
                final paintField = Autocomplete<TmcModel>(
                    optionsBuilder: (TextEditingValue text) {
                      final provider = Provider.of<WarehouseProvider>(context,
                          listen: false);
                      final list = provider.getTmcByType('Краска');
                      // Тот же разбор на слова, что и в диалоге склада:
                      // «красный 192» обязан находить «192D Красный».
                      // Подстрочный contains этого не умел, а именно так
                      // краску и ищут — по цвету и номеру в любом порядке.
                      return list.where((t) => _matchesWarehouseQuery(
                            text.text,
                            [t.description, t.note ?? ''],
                          ));
                    },
                    displayStringForOption: (tmc) => tmc.description,
                    fieldViewBuilder:
                        (context, controller, focusNode, onFieldSubmitted) {
                      // Пока сотрудник печатает, поле принадлежит ему:
                      // возвращаем текст к модели только если он ещё ничего
                      // не набирал (rawInput == null) или строку изменили
                      // извне — выбором из списка, загрузкой заказа.
                      final expected = row.rawInput ?? row.displayName;
                      if (controller.text != expected) {
                        controller
                          ..text = expected
                          ..selection = TextSelection.fromPosition(
                            TextPosition(offset: expected.length),
                          );
                      }
                      return TextFormField(
                        controller: controller,
                        focusNode: focusNode,
                        decoration: InputDecoration(
                          labelText: 'Краска (необязательно)',
                          border: const OutlineInputBorder(),
                          // Не ошибка ввода, а состояние заказа: такой
                          // заказ сохраняется и ждёт, пока краску заведут.
                          errorText: row.nameNotFound
                              ? 'Нет на складе — заказ уйдёт в ожидание '
                                  'материалов'
                              : null,
                          errorMaxLines: 2,
                          errorStyle: row.nameNotFound
                              ? const TextStyle(color: Color(0xFF7C3AED))
                              : null,
                        ),
                        onChanged: (value) {
                          final trimmed = value.trim();
                          setState(() {
                            row.rawInput = value;
                            row.name = trimmed.isEmpty ? null : trimmed;
                            if (row.tmc != null &&
                                row.tmc!.description.toLowerCase() !=
                                    trimmed.toLowerCase()) {
                              row.tmc = null;
                              row.exceeded = false;
                            }
                          });
                          _validatePaintNames();
                          _handlePaintsChanged();
                        },
                      );
                    },
                    onSelected: (tmc) {
                      setState(() {
                        row.tmc = tmc;
                        row.name = tmc.description;
                        row.rawInput = tmc.description;
                        row.nameNotFound = false;
                        if (row.qtyGrams != null) {
                          final need = _gramsToStockUnit(row.qtyGrams!, tmc);
                          row.exceeded = need > _paintAvailableQty(tmc);
                        } else {
                          row.exceeded = false;
                        }
                      });
                      _handlePaintsChanged();
                    },
                    optionsViewBuilder: (context, onSelected, options) {
                      return Align(
                        alignment: Alignment.topLeft,
                        child: Material(
                          elevation: 6,
                          borderRadius: BorderRadius.circular(10),
                          clipBehavior: Clip.antiAlias,
                          child: ConstrainedBox(
                            constraints: const BoxConstraints(
                              minWidth: 280,
                              maxWidth: 520,
                              maxHeight: 260,
                            ),
                            child: ListView.builder(
                              padding: EdgeInsets.zero,
                              itemCount: options.length,
                              itemBuilder: (context, index) {
                                final tmc = options.elementAt(index);
                                return ListTile(
                                  dense: true,
                                  title: Text(
                                    tmc.description,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                  subtitle: Text(
                                      'Доступно: '
                                      '${_formatStockQty(_paintAvailableQty(tmc))} ${tmc.unit}'
                                      '${tmc.reservedQty > 0 ? ' • в резерве ${_formatStockQty(tmc.reservedQty)}' : ''}'),
                                  onTap: () => onSelected(tmc),
                                );
                              },
                            ),
                          ),
                        ),
                      );
                    },
                  );
                final qtyField = SizedBox(
                  width: 130,
                  child: TextFormField(
                    key: ValueKey('qty_$i'),
                    decoration: InputDecoration(
                      labelText: 'Кол-во (г)',
                      border: const OutlineInputBorder(),
                      // Поле узкое (130 px), в одну строку подпись не влезает
                      // и обрезалась бы многоточием.
                      errorMaxLines: 2,
                      errorText: row.exceeded ? kNotEnoughMaterialError : null,
                    ),
                    initialValue: _formatGramsForInput(row.qtyGrams),
                    keyboardType: TextInputType.number,
                    onChanged: (val) {
                      final qty = _parseGrams(val);
                      setState(() {
                        row.qtyGrams = qty;
                        if (row.tmc != null && qty != null) {
                          final need = _gramsToStockUnit(qty, row.tmc!);
                          row.exceeded = need > _paintAvailableQty(row.tmc!);
                        } else {
                          row.exceeded = false;
                        }
                      });
                    },
                  ),
                );
                final removeButton = _paints.length > 1
                    ? IconButton(
                        tooltip: 'Удалить краску',
                        onPressed: () {
                          setState(() => _paints.removeAt(i));
                          _handlePaintsChanged();
                        },
                        icon: const Icon(Icons.remove_circle_outline),
                      )
                    : const SizedBox.shrink();

                if (isCompact) {
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      paintField,
                      const SizedBox(height: 6),
                      Row(
                        children: [
                          qtyField,
                          const SizedBox(width: 8),
                          removeButton,
                        ],
                      ),
                    ],
                  );
                }

                return Row(
                  children: [
                    Expanded(flex: 7, child: paintField),
                    const SizedBox(width: 12),
                    qtyField,
                    const SizedBox(width: 8),
                    removeButton,
                  ],
                );
              },
            ),
          );
        }),
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(
            onPressed: () {
              setState(() => _paints.add(_PaintEntry(memo: _paintInfo)));
              _handlePaintsChanged();
            },
            icon: const Icon(Icons.add),
            label: const Text('Добавить краску'),
          ),
        ),
      ];

    if (!wrapWithCard) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: content,
      );
    }

    return _buildSectionCard(
      context: context,
      title: 'Краски',
      children: content,
    );
  }

  /// PDF выбранной формы, которых ещё нет среди файлов заказа. Дедуп идёт по
  /// objectPath: связь заказ↔форма двусторонняя, и один документ иначе попал
  /// бы в список дважды.
  List<Map<String, dynamic>> _formPdfsNotOnOrder() {
    if (_oldFormSavedPdfs.isEmpty) return const [];
    final orderPaths = _savedOrderPdfs
        .map((f) => (f['objectPath'] ?? '').toString().trim())
        .where((p) => p.isNotEmpty)
        .toSet();
    return _oldFormSavedPdfs.where((f) {
      final path = (f['objectPath'] ?? '').toString().trim();
      return path.isNotEmpty && !orderPaths.contains(path);
    }).toList(growable: false);
  }

  Widget _buildPdfAttachmentRow() {
    final formPdfs = _formPdfsNotOnOrder();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (_loadingOrderPdfs || _loadingOldFormPdfs)
          const Padding(
            padding: EdgeInsets.only(bottom: 4),
            child: LinearProgressIndicator(minHeight: 2),
          ),
        for (final f in _savedOrderPdfs)
          _buildPdfTile(
            name: (f['filename'] ?? f['objectPath'] ?? 'Файл.pdf').toString(),
            onOpen: () => _openSavedPdf(f),
            onRemove: () => _removeSavedOrderPdf(f),
            removeIcon: Icons.delete_outline,
            removeTooltip: 'Удалить',
          ),
        // Файлы самой формы правятся прямо здесь — см. [_removeFormPdf].
        // Метка «форма» остаётся: по ней видно, что файл общий, а не этого
        // заказа, и подтверждение об этом предупредит.
        for (final f in formPdfs)
          _buildPdfTile(
            name: (f['filename'] ?? f['objectPath'] ?? 'Файл.pdf').toString(),
            sourceTag: 'форма',
            onOpen: () => _openSavedPdf(f),
            onRemove: () => _removeFormPdf(f),
            removeIcon: Icons.delete_outline,
            removeTooltip: 'Удалить из формы',
            iconColor: OrderFormColors.muted,
          ),
        for (final f in _pickedOrderPdfs)
          _buildPdfTile(
            name: f.name,
            onOpen: f.bytes == null ? null : () => _openPdfBytes(f.bytes!, f.name),
            onRemove: () => setState(() => _pickedOrderPdfs.remove(f)),
            removeTooltip: 'Убрать',
          ),
        if (_savedOrderPdfs.isNotEmpty ||
            _pickedOrderPdfs.isNotEmpty ||
            formPdfs.isNotEmpty)
          const SizedBox(height: 4),
        // По макету это не «тяжёлая» основная кнопка, а вторичная: рядом
        // фиолетовая «Сохранить», и две заливки спорили бы за внимание.
        Align(
          alignment: Alignment.centerLeft,
          child: OutlinedButton.icon(
            onPressed: _pickPdf,
            icon: const Icon(Icons.attach_file, size: 14),
            label: const Text('Прикрепить'),
            style: OutlinedButton.styleFrom(
              visualDensity: VisualDensity.compact,
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              padding:
                  const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              textStyle:
                  const TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
              foregroundColor: OrderFormColors.muted,
              backgroundColor: OrderFormColors.fieldFill,
              side: const BorderSide(color: OrderFormColors.border),
              shape: RoundedRectangleBorder(
                borderRadius:
                    BorderRadius.circular(OrderFormMetrics.fieldRadius),
              ),
            ),
          ),
        ),
      ],
    );
  }

  Future<void> _loadOldFormPdfsFor(String formId) async {
    setState(() {
      _oldFormPdfsFormId = formId;
      _loadingOldFormPdfs = true;
    });
    try {
      final files = await listFormFiles(formId);
      if (!mounted) return;
      setState(() {
        _oldFormSavedPdfs = files;
        _loadingOldFormPdfs = false;
      });
    } catch (_) {
      if (mounted) setState(() => _loadingOldFormPdfs = false);
    }
  }

  List<Widget> _buildFormEditorControls() {
    final widgets = <Widget>[
      _buildCompactSwitchTile(
        label: 'Есть форма',
        value: _hasForm,
        onChanged: (val) {
          setState(() {
            // Новое бизнес-правило: выбор типа формы возможен только при включенной галочке.
            _hasForm = val;
            _editingForm = true;
            if (!val) {
              _newFormPdfs = [];
              _selectedOldFormRow = null;
              _selectedOldForm = null;
              _formResults = [];
              _formSearchCtl.clear();
              _loadingForms = false;
              _selectedOldFormImageUrl = null;
              _oldFormPdfsFormId = null;
              _oldFormSavedPdfs = [];
            }
          });
        },
      ),
    ];

    if (!_hasForm) {
      widgets.addAll(const [
        SizedBox(height: 2),
        Align(
          alignment: Alignment.centerLeft,
          child: Text('Форма не используется для этого заказа.'),
        ),
      ]);
      return widgets;
    }

    widgets.addAll([
      _buildCompactSwitchTile(
        label: _isOldForm ? 'Старая форма' : 'Новая форма',
        value: _isOldForm,
        onChanged: (val) {
          _formSearchDebounce?.cancel();
          setState(() {
            _isOldForm = val;
            _userManuallySelectedFormType = true;
            if (_isOldForm) {
              _newFormPdfs = [];
              if (_formSearchCtl.text.trim().isEmpty) {
                _formResults = [];
              }
              _loadingForms = false;
              _selectedOldFormImageUrl = null;
            } else {
              _selectedOldFormRow = null;
              _selectedOldForm = null;
              _formResults = [];
              _formSearchCtl.clear();
              _loadingForms = false;
              _selectedOldFormImageUrl = null;
              _oldFormPdfsFormId = null;
              _oldFormSavedPdfs = [];
            }
          });
          if (val) {
            final query = _formSearchCtl.text.trim();
            if (query.isNotEmpty) {
              _reloadForms(search: query);
            }
          }
        },
      ),
    ]);

    if (_isOldForm) {
      widgets.add(TextField(
        controller: _formSearchCtl,
        focusNode: _formSearchFocusNode,
        decoration: const InputDecoration(
          hintText: 'Поиск формы (название, код или доп. информация)',
          prefixIcon: Icon(Icons.search),
          border: OutlineInputBorder(),
        ),
        onChanged: _onFormSearchChanged,
      ));
      widgets.add(const SizedBox(height: 4));
      if (_loadingForms) {
        widgets.add(const Padding(
          padding: EdgeInsets.only(bottom: 8),
          child: LinearProgressIndicator(minHeight: 2),
        ));
      }
      widgets.add(_buildOldFormSearchResults());
      final imageUrl = _selectedOldFormImageUrl;
      if (imageUrl != null && imageUrl.isNotEmpty) {
        widgets.add(Padding(
          padding: const EdgeInsets.only(top: 8),
          child: GestureDetector(
            onTap: () => showImagePreview(
              context,
              imageUrl: imageUrl,
              title: _formSearchCtl.text.trim().isNotEmpty
                  ? _formSearchCtl.text.trim()
                  : null,
            ),
            child: Image.network(imageUrl, height: 120),
          ),
        ));
      }
      widgets.add(const SizedBox(height: 4));
      // PDF формы здесь больше не прикрепляем: единственная точка загрузки —
      // «Прикрепить PDF» в блоке заказа (см. _buildPdfAttachmentRow).
      // Файлы, уже привязанные к форме, видны единым списком «Файлы»
      // в карточке заказа; управлять ими можно в модуле «Формы».
    } else {
      widgets.add(const SizedBox(height: 4));
      widgets.add(_buildFormExtraInfoField());
      widgets.add(const SizedBox(height: 8));
      // PDF новой формы здесь тоже не прикрепляем — единственная точка
      // загрузки живёт в блоке заказа. Прикреплённые к заказу файлы всё так
      // же линкуются к форме (_syncOrderPdfsToForm), поэтому связь
      // форма↔заказ не теряется.
    }

    return widgets;
  }

  Widget _buildFormSummary(BuildContext context) {
    if (!_hasForm) {
      return Text(
        'Форма не используется',
        style: Theme.of(context).textTheme.bodySmall,
      );
    }
    final items = <Widget>[];
    if (_orderFormIsOld != null) {
      items.add(Text(_orderFormIsOld! ? 'Старая форма' : 'Новая форма'));
    }
    if (_orderFormNo != null) {
      items.add(Text('Номер формы: ${_orderFormNo}'));
    }
    if (_orderFormImageUrl != null && _orderFormImageUrl!.isNotEmpty) {
      items.add(Padding(
        padding: const EdgeInsets.only(top: 4),
        child: GestureDetector(
          onTap: () => showImagePreview(
            context,
            imageUrl: _orderFormImageUrl!,
            title: _orderFormDisplay,
          ),
          child: Image.network(
            _orderFormImageUrl!,
            height: 120,
          ),
        ),
      ));
    }

    // Отдельного списка «Файлы формы» здесь нет: PDF заказа и PDF формы
    // сведены в один список «Файлы» карточки заказа, а прикрепляются в
    // единственном месте — блоке заказа.

    if (items.isEmpty) {
      return Text(
        'Форма не указана',
        style: Theme.of(context).textTheme.bodySmall,
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: items,
    );
  }

  void _startFormEditing() {
    _formSearchDebounce?.cancel();
    setState(() {
      _editingForm = true;
      _hasForm = _hasAssignedForm() || _hasForm;
      if (_orderFormIsOld != null) {
        _isOldForm = _orderFormIsOld!;
      }
      if (_isOldForm) {
        _selectedOldFormImageUrl = _orderFormImageUrl;
        final display = () {
          if (_orderFormCode != null && _orderFormCode!.isNotEmpty) {
            return _orderFormCode!;
          }
          if (_orderFormSeries != null && _orderFormNo != null) {
            return '${_orderFormSeries!} ${_orderFormNo!}';
          }
          if (_orderFormNo != null) {
            return _orderFormNo!.toString();
          }
          return '';
        }();
        if (display.isNotEmpty) {
          _formSearchCtl.value = TextEditingValue(
            text: display,
            selection: TextSelection.collapsed(offset: display.length),
          );
          _selectedOldForm = display;
          _editingFormInitialText = display;
        }
      }
    });
    if (_isOldForm) {
      if (mounted) {
        _formSearchFocusNode.requestFocus();
      }
      final query = _formSearchCtl.text.trim();
      if (query.isNotEmpty) {
        _reloadForms(search: query);
      }
      // Форма уже привязана к заказу — резолвим её id, чтобы показать/
      // редактировать список уже загруженных PDF немедленно.
      findFormIdByOrderFormRef(
        formId: _orderFormId,
        formCode: _orderFormCode,
        formSeries: _orderFormSeries,
        formNo: _orderFormNo,
      ).then((formId) {
        if (mounted && formId != null && _isOldForm) {
          _loadOldFormPdfsFor(formId);
        }
      }).catchError((_) {});
    }
  }

  void _cancelFormEditing() {
    _formSearchDebounce?.cancel();
    setState(() {
      _editingForm = false;
      _isOldForm = _orderFormIsOld ?? _isOldForm;
      _selectedOldFormRow = null;
      _selectedOldForm = null;
      _formResults = [];
      _formSearchCtl.clear();
      _loadingForms = false;
      _newFormPdfs = [];
      _selectedOldFormImageUrl = null;
      _oldFormPdfsFormId = null;
      _oldFormSavedPdfs = [];
    });
    if (mounted) {
      _formSearchFocusNode.unfocus();
    }
  }

  Widget _buildOldFormSearchResults() {
    if (_formResults.isEmpty) {
      if (_loadingForms || _formSearchCtl.text.trim().isEmpty) {
        return const SizedBox.shrink();
      }
      return Align(
        alignment: Alignment.centerLeft,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Text(
            'Ничего не найдено',
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ),
      );
    }

    return ConstrainedBox(
      constraints: const BoxConstraints(maxHeight: 240),
      child: Material(
        elevation: 2,
        borderRadius: BorderRadius.circular(12),
        clipBehavior: Clip.antiAlias,
        child: ListView.separated(
          shrinkWrap: true,
          itemCount: _formResults.length,
          separatorBuilder: (_, __) => const Divider(height: 1),
          itemBuilder: (context, index) {
            final form = _formResults[index];
            final series = (form['series'] ?? '').toString().trim();
            final number = ((form['number'] ?? 0) as num).toInt();
            final code = (form['code'] ?? '').toString().trim();
            final size = _cleanFormSizeExtras(
                    (form['size'] ?? form['title'] ?? '').toString())
                ?.trim();
            final productType = (form['product_type'] ?? '').toString().trim();
            final subtitle = <String>[];
            if (size != null && size.isNotEmpty) subtitle.add('Размер: $size');
            if (productType.isNotEmpty) subtitle.add('Тип: $productType');
            final primaryTitle = () {
              if (series.isNotEmpty && number > 0) {
                return '$series $number';
              }
              if (number > 0) return number.toString();
              if (code.isNotEmpty) return code;
              return series.isNotEmpty ? series : 'Форма';
            }();
            final isSelected = identical(form, _selectedOldFormRow);
            return ListTile(
              title: Text(subtitle.isEmpty
                  ? primaryTitle
                  : '$primaryTitle - ${subtitle.join(' - ')}'),
              selected: isSelected,
              trailing: isSelected ? const Icon(Icons.check) : null,
              onTap: () {
                setState(() {
                  _selectedOldFormRow = form;
                  _selectedOldForm = null;
                  final imageUrl = (form['image_url'] ?? '').toString().trim();
                  _selectedOldFormImageUrl =
                      imageUrl.isNotEmpty ? imageUrl : null;
                  _formResults = [];
                  _loadingForms = false;
                });
                final value = _oldFormInputValue(form);
                _formSearchCtl.value = TextEditingValue(
                  text: value,
                  selection: TextSelection.collapsed(offset: value.length),
                );
                FocusScope.of(context).unfocus();
                final rowId = (form['id'] ?? '').toString().trim();
                if (rowId.isNotEmpty) {
                  _loadOldFormPdfsFor(rowId);
                }
              },
            );
          },
        ),
      ),
    );
  }

  String? _sanitizeText(dynamic value) {
    if (value == null) return null;
    final text = value.toString().trim();
    return text.isEmpty ? null : text;
  }

  String _buildFormDisplayValue({String? code, String? series, int? number}) {
    final trimmedCode = code?.trim() ?? '';
    if (trimmedCode.isNotEmpty) return trimmedCode;
    final trimmedSeries = series?.trim() ?? '';
    if (trimmedSeries.isNotEmpty && number != null) {
      return trimmedSeries + number.toString().padLeft(4, '0');
    }
    if (number != null) return number.toString();
    return '-';
  }

  String _oldFormInputValue(Map<String, dynamic> form) {
    final series = (form['series'] ?? '').toString().trim();
    final number = ((form['number'] ?? 0) as num).toInt();
    final code = (form['code'] ?? '').toString().trim();
    if (series.isNotEmpty && number > 0) {
      return '$series $number';
    }
    if (number > 0) return number.toString();
    if (code.isNotEmpty) return code;
    return series;
  }

// Формируем отображаемый код формы для текущего состояния (создание/редактирование)
  String _formDisplayPreview() {
    if (!_hasForm) return '-';
    final bool isEditing = widget.order != null;
    final bool editableState =
        !isEditing || _editingForm || !_hasAssignedForm();
    if (editableState) {
      // Черновик возобновления: пока активна реюз-ветка сохранения
      // (_processFormAssignment), показываем код переносимой формы, а не
      // «заказчик + следующий свободный номер». Порядок проверок в ветках
      // зеркалит приоритеты сохранения: в старой форме ручной выбор из
      // поиска важнее реюза, в новой — реюз важнее создания.
      final String seededDisplay = (_orderFormDisplay ?? '').trim();
      final bool draftReusesForm = !isEditing &&
          !_editingForm &&
          _hasAssignedForm() &&
          seededDisplay.isNotEmpty &&
          seededDisplay != '-';
      if (_isOldForm) {
        if (_selectedOldFormRow != null) {
          return _oldFormInputValue(_selectedOldFormRow!);
        }
        if (_selectedOldForm != null && _selectedOldForm!.trim().isNotEmpty) {
          return _selectedOldForm!.trim();
        }
        if (draftReusesForm && (_orderFormIsOld ?? false)) {
          return seededDisplay;
        }
        return '-';
      } else {
        if (draftReusesForm && !(_orderFormIsOld ?? false)) {
          return seededDisplay;
        }
        final customer = _customerController.text.trim();
        final n = _defaultFormNumber;
        if (customer.isNotEmpty && n > 0) {
          return '$customer $n';
        }
        if (n > 0) return n.toString();
        return '-';
      }
    }
    return (_orderFormDisplay != null && _orderFormDisplay!.isNotEmpty)
        ? _orderFormDisplay!
        : '-';
  }

  String _formatDate(DateTime date) {
    return '${date.day.toString().padLeft(2, '0')}.${date.month.toString().padLeft(2, '0')}.${date.year}';
  }
}
