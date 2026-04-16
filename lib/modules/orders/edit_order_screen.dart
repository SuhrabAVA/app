
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
import 'package:open_filex/open_filex.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../../services/storage_service.dart';
import 'package:image_picker/image_picker.dart';
import 'dart:typed_data';
import 'orders_provider.dart';
import 'orders_repository.dart';
import 'order_model.dart';
import 'product_model.dart';
import 'material_model.dart';
import '../products/products_provider.dart';
import 'orders_screen.dart';
import '../production_planning/template_provider.dart';
import '../production_planning/template_model.dart';
import '../warehouse/warehouse_provider.dart';
import '../warehouse/stock_tables.dart';
import '../warehouse/tmc_model.dart';
import '../personnel/personnel_provider.dart';
import '../../utils/media_viewer.dart';
import '../../utils/enter_key_behavior.dart';

/// Экран редактирования или создания заказа.
/// Если [order] передан, экран открывается для редактирования существующего заказа.
class EditOrderScreen extends StatefulWidget {
  final OrderModel? order;

  /// Если [initialOrder] передан, экран заполняется данными, но создаётся
  /// новый заказ, а не редактируется существующий.
  final OrderModel? initialOrder;
  const EditOrderScreen({super.key, this.order, this.initialOrder});
  @override
  State<EditOrderScreen> createState() => _EditOrderScreenState();
}

class _PaintEntry {
  TmcModel? tmc;
  String? name;
  double? qtyGrams;
  String memo;
  bool exceeded;
  bool nameNotFound;

  _PaintEntry(
      {this.tmc,
      this.name,
      this.qtyGrams,
      this.memo = '',
      this.exceeded = false,
      this.nameNotFound = false});

  String get displayName => tmc?.description ?? name ?? '';
  bool get hasName => displayName.trim().isNotEmpty;
  double? get qtyKg => qtyGrams == null ? null : qtyGrams! / 1000;
  set qtyKg(double? value) => qtyGrams = value == null ? null : value * 1000;
}

const String _canonicalFlexoWorkplaceId =
    '0571c01c-f086-47e4-81b2-5d8b2ab91218';
const String _canonicalBobbinWorkplaceId =
    'b92a89d1-8e95-4c6d-b990-e308486e4bf1';
const Set<String> _legacyFlexoAliases = {
  'w_flexoprint',
  'w_flexo',
};
const Set<String> _legacyBobbinAliases = {
  'w_bobiner',
  'w_bobbin',
};

class _StageRuleOutcome {
  final List<Map<String, dynamic>> stages;
  final bool shouldCompleteBobbin;
  final String? bobbinId;

  const _StageRuleOutcome(
      {required this.stages, this.shouldCompleteBobbin = false, this.bobbinId});
}

class _EditOrderScreenState extends State<EditOrderScreen> {
  static const String _paintInfoParamLabel = 'Информация для красок:';

  Future<void> _goToOrdersModuleHome() async {
    if (!mounted) return;
    await Navigator.of(context).pushAndRemoveUntil(
      MaterialPageRoute(builder: (_) => const OrdersScreen()),
      (route) => route.isFirst,
    );
  }

  String _trimTrailingFractionZeros(String value) {
    if (!value.contains('.')) return value;
    return value
        .replaceFirst(RegExp(r'0+$'), '')
        .replaceFirst(RegExp(r'\.$'), '');
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
          .select('has_form, is_old_form, new_form_no, form_series, form_code')
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

      // Загрузка дополнительных деталей формы (размер, цвета, изображение)
      try {
        if (series.isNotEmpty && no != null) {
          final form = await _sb
              .from('forms')
              .select(
                  'title, description, image_url, size, product_type, colors')
              .eq('series', series)
              .eq('number', no)
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
    } catch (_) {}
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
      } else {
        final selectedValue = _selectedOldFormRow != null
            ? _oldFormInputValue(_selectedOldFormRow!)
            : null;
        if (_selectedOldFormRow != null && selectedValue != trimmed) {
          _selectedOldFormRow = null;
          _selectedOldFormImageUrl = null;
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

  // Персонал: выбранный менеджер из списка сотрудников с ролью «Менеджер»
  String? _selectedManager;
  final TextEditingController _managerDisplayController =
      TextEditingController();
  // Список доступных менеджеров (ФИО), загружается из PersonnelProvider
  List<String> _managerNames = [];
  // Клиент и комментарии
  late TextEditingController _customerController;
  late TextEditingController _commentsController;
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

  PlatformFile? _pickedPdf;
  bool _lengthExceeded = false;
  // Краски (мультисекция)
  final List<_PaintEntry> _paints = <_PaintEntry>[];
  String _paintInfo = '';
  final TextEditingController _paintInfoController = TextEditingController();
  bool _paintsRestored = false;
  bool _fetchedOrderForm = false;
  // Форма: отдельная галочка наличия + выбор старая/новая.
  bool _hasForm = false;
  bool _isOldForm = false;
  bool _editingForm = false;
  bool _formStateInitialized = false;
  // Список существующих форм (номера) из склада
  // Считанные из БД параметры формы для существующего заказа (только просмотр)
  bool? _orderFormIsOld;
  int? _orderFormNo;
  String? _orderFormSeries;
  String? _orderFormCode;
  String? _orderFormDisplay;
  // Детали формы для существующего заказа
  String? _orderFormSize;
  String? _orderFormProductType;
  String? _orderFormColors;
  String? _orderFormImageUrl;

  List<String> _availableForms = [];
  // Номер новой формы по умолчанию (max+1)
  int _defaultFormNumber = 1;
  // Фото новой формы (при создании)
  Uint8List? _newFormImageBytes;
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
  bool _isSavingOrder = false;

  Future<void> _loadCategoriesForProduct() async {
    setState(() => _catsLoading = true);
    try {
      final rows = await _sb.from('warehouse_categories').select('title, code');
      final names = <String>[];
      for (final r in (rows as List)) {
        final title = (r['title'] ?? r['code'] ?? '').toString().trim();
        if (title.isNotEmpty) names.add(title);
      }
      names.sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
      setState(() => _categoryTitles = names);
    } catch (e) {
      debugPrint('load categories error: $e');
    } finally {
      if (mounted) setState(() => _catsLoading = false);
    }
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
    _commentsController = TextEditingController(text: template?.comments ?? '');
    _orderDate = template?.orderDate;
    _dueDate = template?.dueDate;
    // Поля "договор/оплата" временно исключены из сценария создания/редактирования.
    _selectedParams = List<String>.from(template?.additionalParams ?? const []);
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
    _hasForm = template?.hasForm ?? false;

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
    _lengthController = TextEditingController(
      text: _product.width > 0 ? _formatDecimal(_product.width) : '',
    );
    _widthController = TextEditingController(
      text: _product.height > 0 ? _formatDecimal(_product.height) : '',
    );
    _depthController = TextEditingController(
      text: _product.depth > 0 ? _formatDecimal(_product.depth) : '',
    );
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
      });
    }
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

  Future<void> _loadRuntimeEditLocks() async {
    final order = widget.order;
    if (order == null || !order.assignmentCreated) return;
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
      if (tasks.isEmpty) return;
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
          final firstStage = await _sb
              .from('prod_plan_stages')
              .select('stage_id')
              .eq('plan_id', planId)
              .order('step', ascending: true)
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
              .select('id,name,title,short_name,stage_name')
              .inFilter('id', stageIds);
          if (wpRows is List) {
            for (final raw in wpRows.whereType<Map>()) {
              final map = Map<String, dynamic>.from(raw);
              final id = (map['id'] ?? '').toString().trim();
              if (id.isEmpty) continue;
              final probes = [
                map['name'],
                map['title'],
                map['short_name'],
                map['stage_name'],
                id,
              ];
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

      if (!mounted) return;
      setState(() {
        _launchedWithStartedStages = anyStageStarted;
        _launchedNoStartedStages = !anyStageStarted;
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
          stage['workplaceName'] ??
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
      altNames.addAll(rawAlt.whereType<String>().map((e) => e.trim()).where((e) => e.isNotEmpty));
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
      _stagePreviewStages = <Map<String, dynamic>>[];
      _stagePreviewError = null;
      _stagePreviewLoading = true;
      _stagePreviewInitialized = false;
      _stagePreviewScheduled = false;
      _stageOrderManuallyChanged = false;
    });

    _scheduleStagePreviewUpdate(immediate: true);
  }

  Future<_StageRuleOutcome> _applyStageRules(
      List<Map<String, dynamic>> rawStages) async {
    final List<Map<String, dynamic>> stageMaps = rawStages
        .map((stage) => Map<String, dynamic>.from(stage))
        .toList(growable: true);

    String? flexoId;
    String? flexoTitle;
    String? bobbinId;
    String? bobbinTitle;
    bool shouldCompleteBobbin = false;
    Map<String, dynamic>? removedBobbinStage;

    try {
      Map<String, dynamic>? flexo = await _sb
          .from('workplaces')
          .select('id,title')
          .ilike('title', 'Флексопечать%')
          .limit(1)
          .maybeSingle();
      flexo ??= await _sb
          .from('workplaces')
          .select('id,title,name')
          .ilike('title', 'Flexo%')
          .limit(1)
          .maybeSingle();
      flexo ??= await _sb
          .from('workplaces')
          .select('id,title,name')
          .ilike('name', 'Flexo%')
          .limit(1)
          .maybeSingle();
      flexo ??= await _sb
          .from('workplaces')
          .select('id,title,name')
          .ilike('title', 'Флексо%')
          .limit(1)
          .maybeSingle();
      if (flexo != null) {
        flexoId = (flexo['id'] as String?);
        flexoTitle = (flexo['title'] as String?) ?? (flexo['name'] as String?);
        if (flexoTitle == null || flexoTitle!.trim().isEmpty) {
          flexoTitle = 'Флексопечать';
        }
        if (flexoTitle != null &&
            RegExp(r'^[a-z0-9_\-]+$').hasMatch(flexoTitle!.toLowerCase())) {
          flexoTitle = 'Флексопечать';
        }
      }

      Map<String, dynamic>? bob = await _sb
          .from('workplaces')
          .select('id,title,name')
          .ilike('title', 'Бобинорезка%')
          .limit(1)
          .maybeSingle();
      bob ??= await _sb
          .from('workplaces')
          .select('id,title,name')
          .ilike('title', 'Бабинорезка%')
          .limit(1)
          .maybeSingle();
      bob ??= await _sb
          .from('workplaces')
          .select('id,title,name')
          .ilike('name', 'Бабинорезка%')
          .limit(1)
          .maybeSingle();
      bob ??= await _sb
          .from('workplaces')
          .select('id,title,name')
          .ilike('title', 'Bobbin%')
          .limit(1)
          .maybeSingle();
      bob ??= await _sb
          .from('workplaces')
          .select('id,title,name')
          .ilike('name', 'Bobbin%')
          .limit(1)
          .maybeSingle();
      if (bob == null) {
        bob = await _sb
            .from('workplaces')
            .select('id,title,name')
            .eq('id', _canonicalBobbinWorkplaceId)
            .maybeSingle();
      }
      if (bob == null) {
        bob = await _sb
            .from('workplaces')
            .select('id,title,name')
            .eq('id', 'w_bobiner')
            .maybeSingle();
      }
      if (bob != null) {
        bobbinId = (bob['id'] as String?) ?? bobbinId;
        bobbinTitle = (bob['title'] as String?) ??
            (bob['name'] as String?) ??
            bobbinTitle;
      }
    } catch (_) {}

    int findStageIndex(bool Function(Map<String, dynamic>) predicate) {
      for (var i = 0; i < stageMaps.length; i++) {
        if (predicate(stageMaps[i])) return i;
      }
      return -1;
    }

    Map<String, dynamic>? removeBobbinStage() {
      final idx = findStageIndex((m) {
        final sid = (m['stageId'] as String?) ??
            (m['stageid'] as String?) ??
            (m['stage_id'] as String?) ??
            (m['workplaceId'] as String?) ??
            (m['workplace_id'] as String?) ??
            (m['id'] as String?);
        final title =
            ((m['stageName'] ?? m['title']) as String?)?.toLowerCase() ?? '';
        final byId = bobbinId != null && sid == bobbinId;
        final byName = title.contains('бобинорезка') ||
            title.contains('бабинорезка') ||
            title.contains('bobbin');
        return byId || byName;
      });
      if (idx >= 0) {
        return stageMaps.removeAt(idx);
      }
      return null;
    }

    double? _parseLeadingNumber(String? source) {
      if (source == null) return null;
      final match = RegExp(r'[0-9]+(?:[.,][0-9]+)?')
          .firstMatch(source.replaceAll(',', '.'));
      if (match == null) return null;
      return double.tryParse(match.group(0)!);
    }

    double? formatWidth(MaterialModel paper, {required bool isMain}) {
      final candidates = <String?>[
        paper.format,
        if (isMain &&
            (paper.id ?? '').trim().isEmpty &&
            (_matSelectedFormat ?? '').trim().isNotEmpty)
          _matSelectedFormat,
      ];
      for (final candidate in candidates) {
        final fmtWidth = _parseLeadingNumber(candidate);
        if (fmtWidth != null) return fmtWidth;
      }
      return null;
    }

    double? bobbinWidth(MaterialModel paper, {required bool isMain}) {
      if (isMain) {
        return (_product.widthB ?? _product.width).toDouble();
      }
      final fromExtra = _paperExtraDouble(paper, 'widthB');
      return fromExtra ?? (_product.widthB ?? _product.width).toDouble();
    }

    bool paintsFilled = _hasAnyPaints();

    if (paintsFilled) {
      flexoId ??= _canonicalFlexoWorkplaceId;
      flexoTitle = (flexoTitle?.trim().isNotEmpty ?? false)
          ? flexoTitle
          : 'Флексопечать';
      final hasFlexo = findStageIndex((m) {
            final sid = (m['stageId'] as String?) ??
                (m['stageid'] as String?) ??
                (m['stage_id'] as String?) ??
                (m['workplaceId'] as String?) ??
                (m['workplace_id'] as String?) ??
                (m['id'] as String?);
            if (sid != null && flexoId != null && sid == flexoId) return true;
            final title =
                ((m['stageName'] ?? m['title']) as String?)?.toLowerCase() ??
                    '';
            return title.contains('флексопечать') || title.contains('flexo');
          }) >=
          0;
      if (!hasFlexo && flexoId != null && flexoId!.isNotEmpty) {
        int insertIndex = 0;
        final bobIndex = findStageIndex((m) {
          final sid = (m['stageId'] as String?) ??
              (m['stageid'] as String?) ??
              (m['stage_id'] as String?) ??
              (m['workplaceId'] as String?) ??
              (m['workplace_id'] as String?) ??
              (m['id'] as String?);
          final title =
              ((m['stageName'] ?? m['title']) as String?)?.toLowerCase() ?? '';
          final byId = bobbinId != null && sid == bobbinId;
          final byName = title.contains('бобинорезка') ||
              title.contains('бабинорезка') ||
              title.contains('bobbin');
          return byId || byName;
        });
        if (bobIndex >= 0) insertIndex = bobIndex + 1;
        stageMaps.insert(insertIndex, {
          'stageId': flexoId,
          'workplaceId': flexoId,
          'stageName': flexoTitle,
          'workplaceName': flexoTitle,
          'order': 0,
        });
      }
    }

    const double epsilon = 0.001;

    void removeBobbinStageIfPresent() {
      removedBobbinStage = removeBobbinStage();
      if (removedBobbinStage != null) {
        shouldCompleteBobbin = true;
        bobbinId = (removedBobbinStage!['stageId'] ??
                removedBobbinStage!['stage_id'] ??
                removedBobbinStage!['stageid'] ??
                removedBobbinStage!['workplaceId'] ??
                removedBobbinStage!['workplace_id'] ??
                removedBobbinStage!['id'])
            ?.toString();
      }
    }

    void addBobbinStageIfMissing() {
      final hasBobbin = findStageIndex((m) {
            final sid = (m['stageId'] as String?) ??
                (m['stageid'] as String?) ??
                (m['stage_id'] as String?) ??
                (m['workplaceId'] as String?) ??
                (m['workplace_id'] as String?) ??
                (m['id'] as String?);
            if (sid != null && bobbinId != null && sid == bobbinId) return true;
            final title =
                ((m['stageName'] ?? m['title']) as String?)?.toLowerCase() ??
                    '';
            return title.contains('бобинорезка') ||
                title.contains('бабинорезка') ||
                title.contains('bobbin');
          }) >=
          0;
      if (hasBobbin) return;
      final resolvedId = (bobbinId != null && bobbinId!.isNotEmpty)
          ? bobbinId
          : (removedBobbinStage != null
              ? (removedBobbinStage!['stageId'] as String?)
              : null);
      final resolvedTitle = (bobbinTitle?.trim().isNotEmpty ?? false)
          ? bobbinTitle
          : 'Бабинорезка';
      final fallbackId = resolvedId ?? _canonicalBobbinWorkplaceId;
      stageMaps.insert(0, {
        'stageId': fallbackId,
        'workplaceId': fallbackId,
        'stageName': resolvedTitle,
        'workplaceName': resolvedTitle,
        'order': 0,
      });
      bobbinId = fallbackId;
    }

    final papersForRules = _collectSelectedPapers();
    var shouldUseBobbin = false;
    for (var i = 0; i < papersForRules.length; i++) {
      final paper = papersForRules[i];
      final fmtWidth = formatWidth(paper, isMain: i == 0);
      final prodWidth = bobbinWidth(paper, isMain: i == 0);
      if (fmtWidth == null || prodWidth == null || prodWidth <= 0) {
        continue;
      }
      if ((prodWidth + epsilon) < fmtWidth) {
        shouldUseBobbin = true;
        break;
      }
    }
    if (shouldUseBobbin) {
      addBobbinStageIfMissing();
    } else {
      removeBobbinStageIfPresent();
    }

    final List<Map<String, dynamic>> normalized = <Map<String, dynamic>>[];
    final Set<String> uniqueStageKeys = <String>{};

    bool _isFlexoStage(Map<String, dynamic> map, String stageId) {
      final stageKey = stageId.toLowerCase();
      if (stageId == _canonicalFlexoWorkplaceId ||
          _legacyFlexoAliases.contains(stageKey)) {
        return true;
      }
      final name =
          ((map['stageName'] ?? map['title'] ?? '') as String).toLowerCase();
      return name.contains('флекс') || name.contains('flexo');
    }

    bool _isBobbinStage(Map<String, dynamic> map, String stageId) {
      final stageKey = stageId.toLowerCase();
      if (stageId == _canonicalBobbinWorkplaceId ||
          _legacyBobbinAliases.contains(stageKey)) {
        return true;
      }
      final name =
          ((map['stageName'] ?? map['title'] ?? '') as String).toLowerCase();
      return name.contains('бобин') || name.contains('бабин') || name.contains('bobbin');
    }

    for (final stage in stageMaps) {
      final map = Map<String, dynamic>.from(stage);
      final String? stageId = (map['stageId'] ??
              map['stage_id'] ??
              map['stageid'] ??
              map['workplaceId'] ??
              map['workplace_id'] ??
              map['id'])
          ?.toString();
      if (stageId != null && stageId.isNotEmpty) {
        final normalizedStageId = stageId == 'w_flexoprint'
            ? _canonicalFlexoWorkplaceId
            : (stageId == 'w_bobiner' || stageId == 'w_bobbin')
                ? _canonicalBobbinWorkplaceId
                : stageId;
        final dedupeKey = _isFlexoStage(map, normalizedStageId)
            ? 'position:print'
            : _isBobbinStage(map, normalizedStageId)
                ? 'position:bob_cutter'
                : 'stage:$normalizedStageId';
        if (uniqueStageKeys.contains(dedupeKey)) {
          continue;
        }
        uniqueStageKeys.add(dedupeKey);
        map['stageId'] = normalizedStageId;
        map['workplaceId'] = normalizedStageId;
      }
      map['stageName'] = _resolveStageName(map);
      normalized.add(map);
    }

    return _StageRuleOutcome(
      stages: normalized,
      shouldCompleteBobbin: shouldCompleteBobbin,
      bobbinId: bobbinId,
    );
  }

  bool _isFlexoPreviewStage(Map<String, dynamic> stage) {
    final stageId = ((stage['stageId'] ??
                stage['stage_id'] ??
                stage['stageid'] ??
                stage['workplaceId'] ??
                stage['workplace_id'] ??
                stage['id']) as String?)
            ?.trim() ??
        '';
    if (stageId == _canonicalFlexoWorkplaceId ||
        _legacyFlexoAliases.contains(stageId.toLowerCase())) {
      return true;
    }
    final title = _resolveStageName(stage).toLowerCase();
    return title.contains('флекс') || title.contains('flexo');
  }

  bool _isBobbinPreviewStage(Map<String, dynamic> stage) {
    final stageId = ((stage['stageId'] ??
                stage['stage_id'] ??
                stage['stageid'] ??
                stage['workplaceId'] ??
                stage['workplace_id'] ??
                stage['id']) as String?)
            ?.trim() ??
        '';
    if (stageId == _canonicalBobbinWorkplaceId ||
        _legacyBobbinAliases.contains(stageId.toLowerCase())) {
      return true;
    }
    final title = _resolveStageName(stage).toLowerCase();
    return title.contains('бобин') ||
        title.contains('бабин') ||
        title.contains('bobbin');
  }

  void _swapFlexoAndBobbinInPreview() {
    final flexoIndex = _stagePreviewStages.indexWhere(_isFlexoPreviewStage);
    final bobbinIndex = _stagePreviewStages.indexWhere(_isBobbinPreviewStage);
    if (flexoIndex < 0 || bobbinIndex < 0 || flexoIndex == bobbinIndex) return;

    setState(() {
      final next = _stagePreviewStages
          .map((stage) => Map<String, dynamic>.from(stage))
          .toList(growable: true);
      final flexo = next[flexoIndex];
      next[flexoIndex] = next[bobbinIndex];
      next[bobbinIndex] = flexo;
      _stagePreviewStages = next;
      // Важно: после ручного swap больше не должны возвращать auto-порядок.
      _stageOrderManuallyChanged = true;
    });
  }

  List<Map<String, dynamic>> _decodeAndSortStageMaps(dynamic stagesData) {
    final stageMaps = <Map<String, dynamic>>[];

    int orderOf(Map<String, dynamic> m, int fallback) {
      final rawOrder = m['order'] ?? m['step'] ?? m['position'] ?? m['step_no'];
      if (rawOrder is num) return rawOrder.toInt();
      if (rawOrder is String) {
        final parsed = int.tryParse(rawOrder);
        if (parsed != null) return parsed;
      }
      return fallback;
    }

    if (stagesData is List) {
      for (final item in stagesData.whereType<Map>()) {
        stageMaps.add(Map<String, dynamic>.from(item));
      }
    } else if (stagesData is Map) {
      final entries = stagesData.entries.toList()
        ..sort((a, b) {
          final ak = int.tryParse(a.key.toString());
          final bk = int.tryParse(b.key.toString());
          if (ak != null && bk != null) return ak.compareTo(bk);
          if (ak != null) return -1;
          if (bk != null) return 1;
          return a.key.toString().compareTo(b.key.toString());
        });
      for (final entry in entries) {
        if (entry.value is! Map) continue;
        final map = Map<String, dynamic>.from(entry.value as Map);
        final hasOrder = map.containsKey('order') ||
            map.containsKey('step') ||
            map.containsKey('position') ||
            map.containsKey('step_no');
        if (!hasOrder) {
          final parsed = int.tryParse(entry.key.toString());
          if (parsed != null) {
            map['order'] = parsed;
          }
        }
        stageMaps.add(map);
      }
    }

    final entries = stageMaps.asMap().entries.toList();
    entries.sort((a, b) {
      final ao = orderOf(a.value, a.key);
      final bo = orderOf(b.value, b.key);
      final cmp = ao.compareTo(bo);
      if (cmp != 0) return cmp;
      return a.key.compareTo(b.key);
    });
    return entries.map((e) => e.value).toList(growable: true);
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
    final filled = _hasAnyPaints();
    if (_lastPreviewPaintsFilled != filled) {
      _lastPreviewPaintsFilled = filled;
      _scheduleStagePreviewUpdate();
    } else if (filled) {
      _scheduleStagePreviewUpdate();
    }
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
              _gramsToStockUnit(row.qtyGrams!, match) > match.quantity;
        } else if (match == null) {
          row.exceeded = false;
        }
      }
    });
  }

  bool _hasInvalidPaintNames() {
    for (final paint in _paints) {
      if (paint.nameNotFound) return true;
    }
    return false;
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

  void _scheduleStagePreviewUpdate({bool immediate = false}) {
    if (!mounted) return;
    if (_stageTemplateId == null || _stageTemplateId!.isEmpty) return;
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

  Future<void> _rebuildStagePreview() async {
    final templateId = _stageTemplateId;
    if (templateId == null || templateId.isEmpty) {
      if (mounted) {
        setState(() {
          _stagePreviewStages = <Map<String, dynamic>>[];
          _stagePreviewLoading = false;
          _stagePreviewError = null;
        });
      }
      return;
    }
    final provider = context.read<TemplateProvider>();
    final tpl = _findTemplateById(provider.templates, templateId);
    if (tpl == null) {
      if (mounted) {
        setState(() {
          _stagePreviewStages = <Map<String, dynamic>>[];
          _stagePreviewLoading = false;
          _stagePreviewError = null;
        });
      }
      return;
    }

    // Для редактирования сначала берём уже сохранённый план заказа,
    // чтобы отобразить и редактировать именно пользовательскую очередь.
    List<Map<String, dynamic>> rawStages = <Map<String, dynamic>>[];
    if (widget.order != null) {
      try {
        final plan = await _sb
            .from('production_plans')
            .select('stages')
            .eq('order_id', widget.order!.id)
            .maybeSingle();
        rawStages = _decodeAndSortStageMaps(plan?['stages']);
      } catch (_) {
        rawStages = <Map<String, dynamic>>[];
      }
    }
    if (rawStages.isEmpty) {
      rawStages = tpl.stages
          .map((s) => {
                'stageId': s.stageId,
                'workplaceId': s.stageId,
                'stageName': s.stageName,
                'workplaceName': s.stageName,
                if (s.alternativeStageIds.isNotEmpty)
                  'alternativeStageIds':
                      List<String>.from(s.alternativeStageIds),
                if (s.alternativeStageNames.isNotEmpty)
                  'alternativeStageNames':
                      List<String>.from(s.alternativeStageNames),
              })
          .toList();
    }

    if (mounted) {
      setState(() {
        _stagePreviewLoading = true;
        _stagePreviewError = null;
      });
    }

    try {
      final outcome = await _applyStageRules(rawStages);
      if (!mounted) return;
      setState(() {
        _stagePreviewStages = outcome.stages;
        _stagePreviewLoading = false;
        _stagePreviewError = null;
        _stagePreviewInitialized = true;
        _stageOrderManuallyChanged = false;
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
    _customerController.dispose();
    _commentsController.dispose();
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
    } catch (e) {
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

  /// Открывает галерею для выбора изображения новой формы. Выбранное фото
  /// сохраняется в состояние [_newFormImageBytes] и отображается в UI.
  Future<void> _pickNewFormImage() async {
    final picker = ImagePicker();
    final XFile? file = await picker.pickImage(source: ImageSource.gallery);
    if (file != null) {
      final bytes = await file.readAsBytes();
      if (mounted) {
        setState(() {
          _newFormImageBytes = bytes;
        });
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
    if (_product.length != null) {
      _lengthExceeded = _product.length! > tmc.quantity;
    }
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
      final extraIndex = _activePaperSlotIndex - 1;
      if (extraIndex >= 0 && extraIndex < _extraPaperMaterials.length) {
        final currentExtra = _extraPaperMaterials[extraIndex];
        setState(() {
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
          quantity: _selectedMaterial!.quantity > 0
              ? _selectedMaterial!.quantity
              : fallbackQty,
          unit: 'м',
        ),
      );
    }
    // Дополнительные типы бумаги сохраняем отдельными позициями.
    for (final paper in _extraPaperMaterials) {
      final resolved = resolvePaperByMaterial(paper);
      final id = (resolved?.id ?? paper.id ?? '').trim();
      if (id.isEmpty) continue;
      final extraLength = _paperExtraDouble(paper, 'lengthL');
      final resolvedQty =
          extraLength != null && extraLength > 0 ? extraLength : fallbackQty;
      selected.add(
        paper.copyWith(
          id: id,
          quantity: paper.quantity > 0 ? paper.quantity : resolvedQty,
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
    _scheduleStagePreviewUpdate();
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
    try {
      // удаляем старые
      await _sb.from('order_paints').delete().eq('order_id', orderId);
      // вставляем новые
      if (rows.isNotEmpty) {
        await _sb.from('order_paints').insert(rows);
      }
      // Сохраняем актуальные product.parameters даже когда красок нет:
      // в этом случае "Информация для красок" должна оставаться в заказе.
      await _sb.from('orders').update({
        'product': _product.toMap(),
      }).eq('id', orderId);
    } catch (e) {
      // не блокируем сохранение заказа, просто сообщим в консоль
      debugPrint('❌ persist paints error: ' + e.toString());
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

  Future<void> _pickPdf() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['pdf'],
      withData: true,
    );
    if (result != null && result.files.isNotEmpty) {
      setState(() {
        _pickedPdf = result.files.first;
      });
    }
  }

  Future<void> _openPdf() async {
    if (_pickedPdf != null && _pickedPdf!.path != null) {
      await OpenFilex.open(_pickedPdf!.path!);
    } else if (widget.order?.pdfUrl != null) {
      final url = await getSignedUrl(widget.order!.pdfUrl!);
      await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
    }
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
    final wp = Provider.of<WarehouseProvider>(context, listen: false);
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
    // Берём самый свежий остаток из провайдера по id
    for (final t in wp.allTmc) {
      if (t.id == tmc!.id) return t.quantity;
    }
    return tmc.quantity;
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

  Future<void> _saveOrder() async {
    if (_isSavingOrder) return;
    setState(() => _isSavingOrder = true);
    try {
    // Флаг: создаём новый заказ или редактируем
    final bool isCreating = (widget.order == null);
    final messenger = ScaffoldMessenger.of(context);
    if (!_formKey.currentState!.validate()) return;
    _selectedCardboard = _cardboardChecked ? 'есть' : 'нет';
    final params = {..._selectedParams};
    if (_trimming) {
      params.add('Подрезка');
    } else {
      params.remove('Подрезка');
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
    if (_hasInvalidPaintNames()) {
      if (mounted)
        messenger.showSnackBar(
          const SnackBar(
              content: Text('Данной краски нет на складе. Уточните название.')),
        );
      return;
    }
    final managerName = widget.order != null
        ? widget.order!.manager
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
    bool hasEnoughPaperForLaunch() {
      if (selectedPapers.isEmpty) return true;
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

    final bool hasStageQueueSelected =
        _stageTemplateId != null && _stageTemplateId!.trim().isNotEmpty;
    final bool canLaunchProductionNow =
        hasStageQueueSelected && hasEnoughPaperForLaunch();
    final bool wasAlreadyLaunched = widget.order?.assignmentCreated ?? false;
    final bool stageQueueChangedForLaunchedOrder = wasAlreadyLaunched &&
        ((_stageTemplateId ?? '') != (widget.order?.stageTemplateId ?? '') ||
            _stageOrderManuallyChanged);
    if (stageQueueChangedForLaunchedOrder && _launchedWithStartedStages) {
      // Бизнес-правило: после старта этапов нельзя менять очередь.
      if (mounted) {
        messenger.showSnackBar(
          const SnackBar(
            content: Text(
              'Нельзя изменить очередь этапов: производство уже начато.',
            ),
          ),
        );
      }
      return;
    }
    final String nextOrderStatus = wasAlreadyLaunched
        ? widget.order!.status
        : (!hasStageQueueSelected
            ? OrderStatus.draft.name
            : (canLaunchProductionNow
            ? OrderStatus.ready_to_start.name
            : OrderStatus.waiting_materials.name));
    final bool nextHasMaterialShortage = wasAlreadyLaunched
        ? widget.order!.hasMaterialShortage
        : (hasStageQueueSelected ? !canLaunchProductionNow : false);
    final String shortageMessage = wasAlreadyLaunched
        ? widget.order!.materialShortageMessage
        : (!hasStageQueueSelected
            ? ''
            : (canLaunchProductionNow
            ? ''
            : 'Недостаточно материала на складе. Пополните склад и запустите заказ вручную.'));
    late OrderModel createdOrUpdatedOrder;
    bool resetForRelaunchAfterEdit = false;
    if (widget.order == null) {
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
        material: _selectedMaterial,
        paperMaterials: selectedPapers,
        makeready: _makeready,
        val: _val,
        stageTemplateId: _stageTemplateId,
        hasForm: _hasForm,
        // Временно отключено в форме создания/редактирования заказа.
        contractSigned: false,
        paymentDone: false,
        comments: _commentsController.text.trim(),
        status: nextOrderStatus,
      );
      if (_created == null) {
        if (mounted) {
          messenger.showSnackBar(
            const SnackBar(content: Text('Не удалось создать заказ')),
          );
        }
        return;
      }
      createdOrUpdatedOrder = _created;
    } else {
      final List<MaterialModel> oldPapers =
          widget.order!.paperMaterials.isNotEmpty
              ? widget.order!.paperMaterials
              : <MaterialModel>[
                  if (widget.order!.material != null) widget.order!.material!,
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
        id: widget.order!.id,
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
        material: _selectedMaterial,
        paperMaterials: selectedPapers,
        makeready: _makeready,
        val: _val,
        pdfUrl: widget.order!.pdfUrl,
        stageTemplateId: _stageTemplateId,
        hasForm: _hasForm,
        // Временно отключено в форме создания/редактирования заказа.
        contractSigned: false,
        paymentDone: false,
        comments: _commentsController.text.trim(),
        status: nextOrderStatus,
        hasMaterialShortage: nextHasMaterialShortage,
        materialShortageMessage: shortageMessage,
        assignmentId: widget.order!.assignmentId,
        assignmentCreated: widget.order!.assignmentCreated,
      );
      await provider.updateOrder(updated);
      createdOrUpdatedOrder = updated;
      if (wasAlreadyLaunched &&
          stageQueueChangedForLaunchedOrder &&
          _launchedNoStartedStages &&
          mounted) {
        // Бизнес-правило: если изменили очередь этапов у запущенного заказа,
        // а этапы ещё не начинались — снимаем заказ с производства и ждём
        // ручного повторного запуска.
        await provider.resetLaunchedOrderForRelaunch(updated.id);
        createdOrUpdatedOrder = createdOrUpdatedOrder.copyWith(
          assignmentCreated: false,
          status: OrderStatus.ready_to_start.name,
        );
        resetForRelaunchAfterEdit = true;
      }
    }

    if (createdOrUpdatedOrder.status != nextOrderStatus ||
        createdOrUpdatedOrder.hasMaterialShortage != nextHasMaterialShortage ||
        createdOrUpdatedOrder.materialShortageMessage != shortageMessage) {
      final normalized = createdOrUpdatedOrder.copyWith(
        status: nextOrderStatus,
        hasMaterialShortage: nextHasMaterialShortage,
        materialShortageMessage: shortageMessage,
      );
      await provider.updateOrder(normalized);
      createdOrUpdatedOrder = normalized;
    }

    // Присвоим читаемый номер заказа (ЗК-YYYY.MM.DD-N), если ещё не присвоен
    if ((createdOrUpdatedOrder.assignmentId == null ||
            createdOrUpdatedOrder.assignmentId!.isEmpty) &&
        _orderDate != null) {
      try {
        final humanId = await provider.generateReadableOrderId(_orderDate!);
        final withReadable = OrderModel(
          id: createdOrUpdatedOrder.id,
          manager: createdOrUpdatedOrder.manager,
          customer: createdOrUpdatedOrder.customer,
          orderDate: createdOrUpdatedOrder.orderDate,
          dueDate: createdOrUpdatedOrder.dueDate,
          product: createdOrUpdatedOrder.product,
          additionalParams: createdOrUpdatedOrder.additionalParams,
          handle: createdOrUpdatedOrder.handle,
          cardboard: createdOrUpdatedOrder.cardboard,
          material: createdOrUpdatedOrder.material,
          paperMaterials: createdOrUpdatedOrder.paperMaterials,
          makeready: createdOrUpdatedOrder.makeready,
          val: createdOrUpdatedOrder.val,
          pdfUrl: createdOrUpdatedOrder.pdfUrl,
          stageTemplateId: createdOrUpdatedOrder.stageTemplateId,
          hasForm: createdOrUpdatedOrder.hasForm,
          contractSigned: createdOrUpdatedOrder.contractSigned,
          paymentDone: createdOrUpdatedOrder.paymentDone,
          comments: createdOrUpdatedOrder.comments,
          status: createdOrUpdatedOrder.status,
          assignmentId: humanId,
          assignmentCreated: createdOrUpdatedOrder.assignmentCreated,
        );
        await provider.updateOrder(withReadable);
        createdOrUpdatedOrder = withReadable;
      } catch (_) {}
    }
    // Загружаем PDF при необходимости
    if (_pickedPdf != null) {
      final uploadedPath = await uploadPickedOrderPdf(
        orderId: createdOrUpdatedOrder.id,
        file: _pickedPdf!,
      );
      createdOrUpdatedOrder.pdfUrl = uploadedPath;
      await provider.updateOrder(createdOrUpdatedOrder);
    }
    // если выбран шаблон и задания ещё не создавались - создаём их (ОДИН РАЗ)
    if (_stageTemplateId != null && _stageTemplateId!.isNotEmpty) {
      // Fetch template stages from 'plan_templates' table
      final tplRow = await _sb
          .from('plan_templates')
          .select('stages')
          .eq('id', _stageTemplateId!)
          .maybeSingle();
      if (tplRow != null) {
        final stagesData = tplRow['stages'];
        List<Map<String, dynamic>> stageMaps = [];

        // Источник истины при сохранении — текущий preview.
        // Он уже может содержать ручную перестановку флексо/бобинорезки.
        if (_stagePreviewStages.isNotEmpty) {
          stageMaps = _stagePreviewStages
              .map((stage) => Map<String, dynamic>.from(stage))
              .toList(growable: true);
        } else {
          stageMaps = _decodeAndSortStageMaps(stagesData);
        }

        final outcome = await _applyStageRules(stageMaps);
        stageMaps = outcome.stages;
        final bool __shouldCompleteBobbin = outcome.shouldCompleteBobbin;
        final String? __bobbinId = outcome.bobbinId;
        // Save or update production plan in dedicated table 'production_plans'
        final existingPlan = await _sb
            .from('production_plans')
            .select('id')
            .eq('order_id', createdOrUpdatedOrder.id)
            .maybeSingle();
        if (existingPlan != null) {
          await _sb
              .from('production_plans')
              .update({'stages': stageMaps}).eq('id', existingPlan['id']);
        } else {
          await _sb.from('production_plans').insert(
              {'order_id': createdOrUpdatedOrder.id, 'stages': stageMaps});
        }

        bool _looksLikeBobbin(Map<String, dynamic> sm) {
          final title =
              ((sm['stageName'] ?? sm['title']) as String?)?.toLowerCase() ?? '';
          return title.contains('бобинорезка') ||
              title.contains('бабинорезка') ||
              title.contains('bobbin');
        }

        String? _resolveStageId(Map<String, dynamic> sm) {
          final sid = (sm['stageId'] as String?) ??
              (sm['stageid'] as String?) ??
              (sm['stage_id'] as String?) ??
              (sm['workplaceId'] as String?) ??
              (sm['workplace_id'] as String?) ??
              (sm['id'] as String?);
          if ((_looksLikeBobbin(sm) || sid == null || sid.isEmpty) &&
              __bobbinId != null &&
              __bobbinId!.isNotEmpty) {
            return __bobbinId;
          }
          return sid;
        }

        String _normalizeText(dynamic value) =>
            (value?.toString() ?? '').trim();

        final workplaceLookup = <String, String>{};
        Future<List<Map<String, dynamic>>> _loadWorkplaceRows() async {
          Future<List<Map<String, dynamic>>> readRows(String select) async {
            final rows = await _sb.from('workplaces').select(select);
            if (rows is! List) return const <Map<String, dynamic>>[];
            return rows
                .whereType<Map>()
                .map((row) => Map<String, dynamic>.from(row))
                .toList(growable: false);
          }

          try {
            return await readRows(
              'id, code, name, title, short_name, workplace_name, stage_name',
            );
          } catch (_) {
            try {
              return await readRows('id, name, code, title, short_name');
            } catch (_) {
              try {
                return await readRows('id, name');
              } catch (_) {
                return const <Map<String, dynamic>>[];
              }
            }
          }
        }

        final workplaceRows = await _loadWorkplaceRows();
        bool _containsBobbinWord(String value) {
          final text = value.toLowerCase();
          return text.contains('бобин') ||
              text.contains('бабин') ||
              text.contains('bobin') ||
              text.contains('bobbin');
        }

        bool _containsFlexoWord(String value) {
          final text = value.toLowerCase();
          return text.contains('флекс') || text.contains('flexo');
        }

      final legacyStageLookup = <String, String>{};
      legacyStageLookup['w_flexoprint'] = _canonicalFlexoWorkplaceId;
      legacyStageLookup['w_flexo'] = _canonicalFlexoWorkplaceId;
      legacyStageLookup['w_bobiner'] = _canonicalBobbinWorkplaceId;
      legacyStageLookup['w_bobbin'] = _canonicalBobbinWorkplaceId;
      for (final map in workplaceRows) {
          final id = _normalizeText(map['id']);
          if (id.isEmpty) continue;
          final probes = [
            map['id'],
            map['code'],
            map['name'],
            map['title'],
            map['short_name'],
            map['workplace_name'],
            map['stage_name'],
          ];
          final joined = probes.map(_normalizeText).join(' ').toLowerCase();
          if (_containsBobbinWord(joined)) {
            legacyStageLookup['w_bobiner'] = id;
            legacyStageLookup['w_bobbin'] = id;
          }
          if (_containsFlexoWord(joined)) {
            legacyStageLookup['w_flexoprint'] = id;
            legacyStageLookup['w_flexo'] = id;
          }
          for (final probe in probes) {
            final key = _normalizeText(probe).toLowerCase();
            if (key.isEmpty) continue;
            workplaceLookup.putIfAbsent(key, () => id);
          }
        }

        String? _resolveStageValue(dynamic raw) {
          final normalized = _normalizeText(raw);
          if (normalized.isEmpty) return null;
          final key = normalized.toLowerCase();
          return workplaceLookup[key] ?? legacyStageLookup[key] ?? normalized;
        }

        bool _looksLikeUuid(String value) {
          final v = value.trim();
          return RegExp(r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[1-5][0-9a-fA-F]{3}-[89abAB][0-9a-fA-F]{3}-[0-9a-fA-F]{12}$')
              .hasMatch(v);
        }

        final knownWorkplaceIds = workplaceRows
            .map((row) => _normalizeText(row['id']))
            .where((id) => id.isNotEmpty)
            .toSet();

        bool _isResolvableWorkplaceId(String stageId) {
          if (stageId.isEmpty) return false;
          if (_looksLikeUuid(stageId)) {
            // При неполном lookup (например, из-за RLS) пропускаем UUID дальше,
            // но при наличии списка рабочих мест всё равно предпочитаем реальные id.
            return knownWorkplaceIds.isEmpty || knownWorkplaceIds.contains(stageId);
          }
          return workplaceLookup.containsValue(stageId) ||
              legacyStageLookup.containsValue(stageId);
        }

        Iterable<dynamic> _collectAlternativeIds(Map<String, dynamic> sm) sync* {
          final candidates = <dynamic>[
            sm['alternativeStageIds'],
            sm['alternative_stage_ids'],
            sm['allStageIds'],
            sm['all_stage_ids'],
            sm['stageIds'],
            sm['stage_ids'],
          ];
          for (final candidate in candidates) {
            if (candidate is List) {
              for (final value in candidate) {
                yield value;
              }
              continue;
            }
            if (candidate is String) {
              for (final token in candidate.split(',')) {
                yield token;
              }
            }
          }
        }

        List<String> _resolveStageIds(Map<String, dynamic> sm) {
          final candidates = <String>[];

          void addCandidate(dynamic raw) {
            final resolved = _resolveStageValue(raw);
            if (resolved == null || resolved.isEmpty) return;
            if (!candidates.contains(resolved)) {
              candidates.add(resolved);
            }
          }

          addCandidate(_resolveStageId(sm));

          for (final probe in <dynamic>[
            sm['stageName'],
            sm['stage_name'],
            sm['workplaceName'],
            sm['workplace_name'],
            sm['title'],
            sm['name'],
          ]) {
            addCandidate(probe);
          }

          for (final raw in _collectAlternativeIds(sm)) {
            addCandidate(raw);
          }

          final resolved = <String>[];
          for (final candidate in candidates) {
            if (_isResolvableWorkplaceId(candidate) && !resolved.contains(candidate)) {
              resolved.add(candidate);
            }
          }

          if (resolved.isNotEmpty) return resolved;
          if (candidates.isEmpty) return const <String>[];
          return <String>[candidates.first];
        }

        final bool shouldLaunchNow = true;

        if (shouldLaunchNow) {
        // ---- Sync normalized tables prod_plans/prod_plan_stages (if they exist) ----
        try {
          // Ensure prod_plans row exists
          final planRow = await _sb
              .from('prod_plans')
              .select('id')
              .eq('order_id', createdOrUpdatedOrder.id)
              .maybeSingle();
          String planId;
          if (planRow == null) {
            final inserted = await _sb
                .from('prod_plans')
                .insert({
                  'order_id': createdOrUpdatedOrder.id,
                  'status': 'planned',
                })
                .select('id')
                .single();
            planId = inserted['id'] as String;
          } else {
            planId = planRow['id'] as String;
          }
          // Rebuild plan stages
          await _sb.from('prod_plan_stages').delete().eq('plan_id', planId);
          int step = 1;
          String? previousGroupKey;
          for (final sm in stageMaps) {
            final stageIds = _resolveStageIds(sm);
            if (stageIds.isEmpty) continue;

            final canonical = List<String>.from(stageIds)..sort();
            final groupKey = canonical.join('|');
            if (groupKey.isNotEmpty && groupKey == previousGroupKey) {
              continue;
            }
            previousGroupKey = groupKey;

            for (final rawStageId in stageIds) {
              final resolvedStageId = workplaceLookup[rawStageId.toLowerCase()] ??
                  legacyStageLookup[rawStageId.toLowerCase()] ??
                  rawStageId;
              await _sb.from('prod_plan_stages').insert({
                'plan_id': planId,
                'stage_id': resolvedStageId,
                'step': step,
                'status': 'waiting',
              });
            }
            step += 1;
          }
          // Mark bobbin as done here as well
          if (__shouldCompleteBobbin && __bobbinId != null) {
            await _sb.from('prod_plan_stages').update({
              'status': 'done',
              'finished_at': DateTime.now().toIso8601String(),
            }).match({'plan_id': planId, 'stage_id': __bobbinId});
          }
        } catch (_) {
          // ignore if tables don't exist
        }
        // ---- /sync normalized tables ----

        }
      }
    }
    // Сначала синхронизируем список красок, чтобы в просмотре заказа
    // изменения были видны сразу после сохранения.
    await _persistPaints(createdOrUpdatedOrder.id);

    // === Обработка формы ===
    await _processFormAssignment(
      createdOrUpdatedOrder,
      isCreating: isCreating,
    );
    // === Конец обработки формы ===

    if (!mounted) return;

    // Бизнес-правило: в создании/редактировании заказа списание бумаги отключено полностью.

    if (resetForRelaunchAfterEdit) {
      messenger.showSnackBar(
        const SnackBar(
          content: Text(
            'Заказ обновлён и снят с производства. Для продолжения запустите его повторно.',
          ),
        ),
      );
    } else if (!createdOrUpdatedOrder.assignmentCreated && !hasStageQueueSelected) {
      messenger.showSnackBar(
        const SnackBar(
          content: Text(
            'Заказ сохранён в черновиках: выберите очередь этапов для подготовки к запуску.',
          ),
        ),
      );
    } else if (!createdOrUpdatedOrder.assignmentCreated && !canLaunchProductionNow) {
      messenger.showSnackBar(
        const SnackBar(
          content: Text(
            'Заказ сохранён без запуска: недостаточно материала на складе. '
            'Запустите заказ позже кнопкой «Запустить».',
          ),
        ),
      );
    } else if (!createdOrUpdatedOrder.assignmentCreated && canLaunchProductionNow) {
      messenger.showSnackBar(
        const SnackBar(
          content: Text('Заказ сохранён и готов к запуску. Нажмите «Запустить».'),
        ),
      );
    }

    // Списание лишнего выполняется на этапе отгрузки.

    await _goToOrdersModuleHome();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Не удалось сохранить заказ: $e')),
        );
      }
    } finally {
      if (mounted) {
        setState(() => _isSavingOrder = false);
      }
    }
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

  Future<void> _processFormAssignment(OrderModel order,
      {required bool isCreating}) async {
    final bool hadFormBefore = _hasAssignedForm();
    final bool shouldHandle = isCreating || _editingForm || !hadFormBefore;
    if (!shouldHandle) return;

    try {
      // Новое бизнес-правило: наличие формы управляется отдельной галочкой.
      // Если галочка выключена — полностью сбрасываем выбранную форму.
      if (!_hasForm) {
        await _sb
            .from('orders')
            .update({
              'has_form': false,
              'is_old_form': null,
              'new_form_no': null,
              'form_series': null,
              'form_code': null,
            })
            .eq('id', order.id);
        if (!mounted) return;
        setState(() {
          _orderFormIsOld = null;
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
          _newFormImageBytes = null;
        });
        return;
      }

      WarehouseProvider? wp;
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
          selectedFormNumber = ((form['number'] ?? 0) as num?)?.toInt();
          rawSeries = form['series'];
          rawCode = form['code'];
          rawSize = form['size'] ?? form['title'];
          rawProductType = form['product_type'];
          rawColors = form['colors'] ?? form['description'];
          rawImageUrl = form['image_url'];
        } else if (_selectedOldForm != null &&
            _selectedOldForm!.trim().isNotEmpty) {
          final code = _selectedOldForm!.trim();
          final digitsMatch = RegExp(r'\d+').firstMatch(code);
          final digits = digitsMatch?.group(0);
          if (digits != null) {
            selectedFormNumber = int.tryParse(digits);
          }
          final seriesMatch = RegExp(r'^[A-Za-zА-Яа-я]+').firstMatch(code);
          rawSeries = seriesMatch?.group(0);
          rawCode = code;
        } else if (hadFormBefore && (_orderFormIsOld ?? false)) {
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
          return;
        }
      } else {
        final formColors = _composeFormColors();
        if (formColors != null && formColors.trim().isNotEmpty) {
          final customer = _customerController.text.trim();
          final formSize = _composeFormSize();
          final formProductType = _composeFormProductType();
          String series = customer.isNotEmpty ? customer : 'F';
          wp ??= WarehouseProvider();
          final created = await wp.createFormAndReturn(
            series: series,
            title: formSize,
            description: formColors,
            formSize: formSize,
            formProductType: formProductType,
            formColors: formColors,
            imageBytes: _newFormImageBytes,
          );
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
          return;
        }
      }

      final String? sanitizedSeries = _sanitizeText(rawSeries);
      final String? sanitizedCode = _sanitizeText(rawCode);
      final String? sanitizedSize = _sanitizeText(rawSize);
      final String? sanitizedProductType = _sanitizeText(rawProductType);
      final String? sanitizedColors = _sanitizeText(rawColors);
      final String? sanitizedImageUrl = _sanitizeText(rawImageUrl);

      final response = await _sb
          .from('orders')
          .update({
            'has_form': true,
            'is_old_form': isOldFormValue,
            'new_form_no': selectedFormNumber,
            'form_series': sanitizedSeries,
            'form_code': sanitizedCode,
          })
          .eq('id', order.id)
          .select()
          .maybeSingle();

      if (response == null) {
        throw 'empty response';
      }

      if (!mounted) return;

      setState(() {
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
        if (!_isOldForm) {
          _newFormImageBytes = null;
        }
        _selectedOldFormImageUrl = null;
      });
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Не удалось сохранить форму: $e')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
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
      inputDecorationTheme: baseTheme.inputDecorationTheme.copyWith(
        isDense: true,
        // Tighten content padding to reduce field height further.
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 8,
          vertical: 1,
        ),
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
      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed:
              _isSavingOrder ? null : () => Navigator.of(context).pop(),
        ),
        title: Text(isEditing
            ? 'Редактирование заказа ${(widget.order!.assignmentId ?? widget.order!.id)}'
            : 'Новый заказ'),
        actions: [
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: FilledButton.tonalIcon(
              style: FilledButton.styleFrom(
                visualDensity: VisualDensity.compact,
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              ),
              onPressed: _isSavingOrder ? null : _saveOrder,
              icon: _isSavingOrder
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.save_outlined, size: 18),
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
                  await provider.deleteOrder(widget.order!.id);
                  if (mounted) Navigator.of(context).pop();
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

              return Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    // Give more space to the form area for multi-column rows.
                    flex: 6,
                    child: SizedBox(
                      height: constraints.maxHeight,
                      child: formList,
                    ),
                  ),
                  // Slightly reduce the warehouse panel width for better balance.
                  const SizedBox(width: 8),
                  Expanded(
                    flex: 2,
                    child: SizedBox(
                      height: constraints.maxHeight,
                      child: _buildWarehousePreviewPanel(),
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

        return Row(
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
                    _buildLabelRow(
                      label: 'Ручки и картон',
                      labelWidth: labelWidth,
                      child: _buildHandlesSection(context, wrapWithCard: false),
                    ),
                  ],
                ),
              ),
            ),
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
                    _buildLabelRow(
                      label: 'Краски',
                      labelWidth: labelWidth,
                      child: _buildPaintsSection(wrapWithCard: false),
                    ),
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
                    _buildLabelRow(
                      label: 'PDF',
                      labelWidth: labelWidth,
                      child: _buildPdfAttachmentRow(),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(width: spacing),
            Expanded(
              child: _buildOrderSectionCard(
                title: 'Бобинорезка',
                icon: Icons.content_cut,
                backgroundColor: const Color(0xFFEFEAFF),
                accentColor: const Color(0xFF7A4CF0),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    _buildLabelRow(
                      label: 'Склад и материалы',
                      labelWidth: labelWidth,
                      labelNote: () {
                        final paperQty = _currentAvailablePaperQty();
                        if (paperQty == null) return null;
                        return 'Остаток бумаги по выбранному материалу: '
                            '${paperQty.toStringAsFixed(2)}';
                      }(),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          _buildProductMaterialAndExtras(_product),
                        ],
                      ),
                    ),
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
                      label: 'Очередь',
                      labelWidth: labelWidth,
                      child: _buildProductionSection(
                        context,
                        wrapWithCard: false,
                        includeMakeready: false,
                      ),
                    ),
                    _buildLabelRow(
                      label: 'Менеджер',
                      labelWidth: labelWidth,
                      child: _buildManagerField(),
                    ),
                  ],
                ),
              ),
            ),
          ],
        );
      },
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

  Widget _buildExtraPaperSelectors() {
    if (_extraPaperMaterials.isEmpty) return const SizedBox.shrink();

    final papers = _paperItems();
    final warehouse = Provider.of<WarehouseProvider>(context, listen: false);
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
      var available = resolved.quantity;
      for (final t in warehouse.allTmc) {
        if (t.id == resolved.id) {
          available = t.quantity;
          break;
        }
      }
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
          InkWell(
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
                          decoration: const InputDecoration(
                            labelText: 'Ширина b',
                            border: OutlineInputBorder(),
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
                            errorText: extraLengthExceeded(_extraPaperMaterials[i])
                                ? 'Недостаточно'
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
        ],
      ],
    );
  }

  /// Дополнительные параметры продукта: материал, складские остатки и вложения
  Widget _buildProductMaterialAndExtras(ProductModel product) {
    final stockExtraWidget = _buildStockExtraLayout(
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

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        stockExtraWidget,
        const SizedBox(height: 3),
        Builder(
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
                            controller.text = _matNameCtl.text;
                            controller.selection = _matNameCtl.selection;
                            controller.addListener(() {
                              if (controller.text != _matNameCtl.text) {
                                setState(() {
                                  _activePaperSlotIndex = 0;
                                  _matNameCtl.text = controller.text;
                                  _matNameCtl.selection = controller.selection;
                                  _matSelectedName = null;
                                  _matSelectedFormat = null;
                                  _matSelectedGrammage = null;
                                  _matFormatCtl.text = '';
                                  _matGramCtl.text = '';
                                  _matNameError = (_matNameCtl.text.trim().isEmpty ||
                                          allNames
                                              .map((e) => e.toLowerCase())
                                              .contains(_matNameCtl.text
                                                  .trim()
                                                  .toLowerCase()))
                                      ? null
                                      : 'Выберите материал из списка';
                                  _matFormatError = null;
                                  _matGramError = null;
                                  final lowerNames =
                                      allNames.map((e) => e.toLowerCase()).toList();
                                  final typed =
                                      _matNameCtl.text.trim().toLowerCase();
                                  if (lowerNames.contains(typed)) {
                                    _matSelectedName =
                                        allNames[lowerNames.indexOf(typed)];
                                  }
                                });
                                _scheduleStagePreviewUpdate();
                              }
                            });
                            return TextField(
                              controller: controller,
                              focusNode: focusNode,
                              decoration:
                                  mainPaperDecoration('Материал').copyWith(
                                errorText: _matNameError,
                              ),
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
                            controller.text = _matFormatCtl.text;
                            controller.selection = _matFormatCtl.selection;
                            controller.addListener(() {
                              if (controller.text != _matFormatCtl.text) {
                                setState(() {
                                  _activePaperSlotIndex = 0;
                                  _matFormatCtl.text = controller.text;
                                  _matFormatCtl.selection = controller.selection;
                                  _matSelectedFormat = null;
                                  _matSelectedGrammage = null;
                                  _matGramCtl.text = '';
                                  _matFormatError =
                                      (_matFormatCtl.text.trim().isEmpty ||
                                              formatOptions
                                                  .map((e) => e.toLowerCase())
                                                  .contains(_matFormatCtl.text
                                                      .trim()
                                                      .toLowerCase()))
                                          ? null
                                          : 'Выберите формат из списка';
                                  final lowerF = formatOptions
                                      .map((e) => e.toLowerCase())
                                      .toList();
                                  final typed =
                                      _matFormatCtl.text.trim().toLowerCase();
                                  if (lowerF.contains(typed)) {
                                    _matSelectedFormat =
                                        formatOptions[lowerF.indexOf(typed)];
                                  }
                                });
                                _scheduleStagePreviewUpdate();
                              }
                            });
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
                            controller.text = _matGramCtl.text;
                            controller.selection = _matGramCtl.selection;
                            controller.addListener(() {
                              if (controller.text != _matGramCtl.text) {
                                setState(() {
                                  _activePaperSlotIndex = 0;
                                  _matGramCtl.text = controller.text;
                                  _matGramCtl.selection = controller.selection;
                                  _matSelectedGrammage = null;
                                  _matGramError = (_matGramCtl.text.trim().isEmpty ||
                                          gramOptions
                                              .map((e) => e.toLowerCase())
                                              .contains(_matGramCtl.text
                                                  .trim()
                                                  .toLowerCase()))
                                      ? null
                                      : 'Выберите грамаж из списка';
                                  final lowerG =
                                      gramOptions.map((e) => e.toLowerCase()).toList();
                                  final typed =
                                      _matGramCtl.text.trim().toLowerCase();
                                  if (lowerG.contains(typed)) {
                                    _matSelectedGrammage =
                                        gramOptions[lowerG.indexOf(typed)];
                                  }
                                });
                                _scheduleStagePreviewUpdate();
                              }
                            });
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
                                decoration: mainPaperDecoration('Ширина b'),
                                keyboardType: TextInputType.number,
                                onChanged: (val) {
                                  final normalized = val.replaceAll(',', '.');
                                  product.widthB = double.tryParse(normalized);
                                  _scheduleStagePreviewUpdate();
                                },
                              ),
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: TextFormField(
                                initialValue: product.blQuantity?.toString() ?? '',
                                decoration: mainPaperDecoration('Количество'),
                                keyboardType: TextInputType.text,
                                onChanged: (val) {
                                  final trimmed = val.trim();
                                  product.blQuantity = trimmed.isEmpty ? null : trimmed;
                                  _scheduleStagePreviewUpdate();
                                },
                              ),
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: TextFormField(
                                initialValue:
                                    product.length != null ? _formatDecimal(product.length!) : '',
                                decoration: mainPaperDecoration('Длина L').copyWith(
                                  errorText: _lengthExceeded ? 'Недостаточно' : null,
                                ),
                                keyboardType: TextInputType.number,
                                onChanged: (val) {
                                  final normalized = val.replaceAll(',', '.');
                                  final d = double.tryParse(normalized);
                                  setState(() {
                                    product.length = d;
                                    final materialTmc =
                                        _selectedMaterialTmc ?? _resolvePaperByText();
                                    if (materialTmc != null && d != null) {
                                      _lengthExceeded = () {
                                        final current = Provider.of<WarehouseProvider>(
                                                context,
                                                listen: false)
                                            .allTmc
                                            .where((t) => t.id == materialTmc.id)
                                            .toList();
                                        final available = current.isNotEmpty
                                            ? current.first.quantity
                                            : materialTmc.quantity;
                                        return d > available;
                                      }();
                                    } else {
                                      _lengthExceeded = false;
                                    }
                                  });
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
        const SizedBox(height: 3),
        _buildExtraPaperSelectors(),
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(
            onPressed: _addExtraPaperSlot,
            icon: const Icon(Icons.add),
            label: Text('Добавить бумагу №${_extraPaperMaterials.length + 2}'),
          ),
        ),
        const SizedBox(height: 3),
      ],
    );
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
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: backgroundColor,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: accentColor.withOpacity(0.35)),
        boxShadow: [
          BoxShadow(
            color: accentColor.withOpacity(0.12),
            blurRadius: 12,
            offset: const Offset(0, 6),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: accentColor,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Icon(icon, color: Colors.white, size: 20),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  title,
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w700,
                    color: accentColor.withOpacity(0.95),
                  ),
                ),
              ),
            ],
          ),
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 10),
            child: Divider(height: 1),
          ),
          child,
        ],
      ),
    );
  }

  Widget _buildLabelRow({
    required String label,
    required Widget child,
    double labelWidth = 150,
    String? labelNote,
  }) {
    final labelWidget = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          '$label:',
          style: const TextStyle(fontWeight: FontWeight.w600),
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
        return Padding(
          // Reduce vertical padding to make rows even more compact.
          padding: const EdgeInsets.symmetric(vertical: 1.0),
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
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SizedBox(
                      width: labelWidth,
                      child: labelWidget,
                    ),
                    // Narrow the gap between label and field.
                    const SizedBox(width: 6),
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
            setState(() {
              _product.type = val ?? '';
              _selectedStockExtraRow = null;
              _stockExtraResults = [];
              _stockExtra = null;
              _stockExtraSelectedQty = null;
              _stockExtraQtyTouched = false;
              _product.leftover = null;
            });
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

            final extras = Wrap(
              // Reduce spacing to shrink the area used by the checkboxes.
              spacing: 6,
              runSpacing: 3,
              children: [
                _buildCompactCheckboxTile(
                  value: _cardboardChecked,
                  onChanged: (val) => setState(() {
                    _cardboardChecked = val ?? false;
                    _selectedCardboard = _cardboardChecked ? 'есть' : 'нет';
                  }),
                  label: 'Картон',
                  width: 100,
                ),
                _buildCompactCheckboxTile(
                  value: _trimming,
                  onChanged: (val) => setState(() => _trimming = val ?? false),
                  label: 'Подрезка',
                  width: 100,
                ),
              ],
            );

            return _buildFieldGrid([
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
                  });
                },
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
    required ValueChanged<bool?> onChanged,
    required String label,
    double? width,
  }) {
    final theme = Theme.of(context);

    final tile = InkWell(
      borderRadius: BorderRadius.circular(10),
      onTap: () => onChanged(!value),
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
                onChanged: onChanged,
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

        return Card(
          // Use symmetric margins reduced by 20% to keep the panel centred and compact.
          margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
          child: DefaultTabController(
            length: 3,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const TabBar(
                  tabs: [
                    Tab(text: 'Бумага'),
                    Tab(text: 'Краски'),
                    Tab(text: 'Категории'),
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

  Widget _buildPaperWarehouseView(List<TmcModel> papers) {
    if (papers.isEmpty) {
      return const Center(child: Text('На складе нет бумаги'));
    }
    final filtered = papers.where((paper) {
      return _matchesWarehouseQuery(_paperSearch, [
        paper.description,
        paper.format ?? '',
        paper.grammage ?? '',
        paper.note ?? '',
        paper.quantity.toStringAsFixed(2),
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
                      final subtitle = [
                        if ((paper.format ?? '').isNotEmpty)
                          'Формат: ${paper.format}',
                        if ((paper.grammage ?? '').isNotEmpty)
                          'Грамаж: ${paper.grammage}',
                        'Метраж: ${paper.quantity.toStringAsFixed(2)}',
                      ].where((part) => part.trim().isNotEmpty).join(' • ');
                      return ListTile(
                        dense: true,
                        title: Text(
                          paper.description.isEmpty
                              ? 'Без названия'
                              : paper.description,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        subtitle: Text(
                          subtitle,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        onTap: () => _applyPaperSelection(paper),
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
                      return ListTile(
                        dense: true,
                        title: Text(
                          description.isEmpty ? 'Без названия' : description,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        subtitle: Text(
                          subtitleParts.join(' • '),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
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
    if (_stageTemplateId == null || _stageTemplateId!.isEmpty) {
      return Text(
        'Выберите очередь, чтобы просмотреть этапы производства',
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
        'Для выбранной очереди не найдено этапов',
        style: theme.textTheme.bodySmall,
      );
    }

    final children = <Widget>[];
    final hasFlexo = _stagePreviewStages.any(_isFlexoPreviewStage);
    final hasBobbin = _stagePreviewStages.any(_isBobbinPreviewStage);
    if (hasFlexo && hasBobbin) {
      children.add(
        Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: Wrap(
            spacing: 8,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              OutlinedButton.icon(
                onPressed: _swapFlexoAndBobbinInPreview,
                icon: const Icon(Icons.swap_vert),
                label: const Text('Поменять местами бобинорезку и флексопечать'),
              ),
              if (_stageOrderManuallyChanged)
                Text(
                  'Порядок изменён вручную',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.primary,
                  ),
                ),
            ],
          ),
        ),
      );
    }
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
      children.add(Container(
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
                  Text(title, style: theme.textTheme.bodyMedium),
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
      ));
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
                      final query = text.text.toLowerCase();
                      if (query.isEmpty) return list;
                      return list.where(
                          (t) => t.description.toLowerCase().contains(query));
                    },
                    displayStringForOption: (tmc) => tmc.description,
                    fieldViewBuilder:
                        (context, controller, focusNode, onFieldSubmitted) {
                      final display = row.displayName;
                      if (controller.text != display) {
                        controller
                          ..text = display
                          ..selection = TextSelection.fromPosition(
                            TextPosition(offset: controller.text.length),
                          );
                      }
                      return TextFormField(
                        controller: controller,
                        focusNode: focusNode,
                        decoration: InputDecoration(
                          labelText: 'Краска (необязательно)',
                          border: const OutlineInputBorder(),
                          errorText: row.nameNotFound
                              ? 'Такой краски нет на складе'
                              : null,
                        ),
                        onChanged: (value) {
                          final trimmed = value.trim();
                          setState(() {
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
                        row.nameNotFound = false;
                        if (row.qtyGrams != null) {
                          final need = _gramsToStockUnit(row.qtyGrams!, tmc);
                          row.exceeded = need > tmc.quantity;
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
                                      'Кол-во: ${tmc.quantity.toString()}'),
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
                      errorText: row.exceeded ? 'Недостаточно' : null,
                    ),
                    initialValue: _formatGramsForInput(row.qtyGrams),
                    keyboardType: TextInputType.number,
                    onChanged: (val) {
                      final qty = _parseGrams(val);
                      setState(() {
                        row.qtyGrams = qty;
                        if (row.tmc != null && qty != null) {
                          final need = _gramsToStockUnit(qty, row.tmc!);
                          row.exceeded = need > row.tmc!.quantity;
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

  Widget _buildPdfAttachmentRow() {
    return Row(
      children: [
        Expanded(
          child: ElevatedButton.icon(
            onPressed: _pickPdf,
            icon: const Icon(Icons.attach_file),
            label: Text(
              _pickedPdf?.name ??
                  (widget.order?.pdfUrl != null
                      ? widget.order!.pdfUrl!.split('/').last
                      : 'Прикрепить PDF'),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ),
        if (_pickedPdf != null || widget.order?.pdfUrl != null) ...[
          const SizedBox(width: 8),
          IconButton(
            icon: const Icon(Icons.open_in_new),
            onPressed: _openPdf,
          ),
        ]
      ],
    );
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
              _newFormImageBytes = null;
              _selectedOldFormRow = null;
              _selectedOldForm = null;
              _formResults = [];
              _formSearchCtl.clear();
              _loadingForms = false;
              _selectedOldFormImageUrl = null;
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
            if (_isOldForm) {
              _newFormImageBytes = null;
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
          hintText: 'Поиск формы (название или код)',
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
    } else {
      widgets.add(const SizedBox(height: 4));
      if (_newFormImageBytes != null) {
        widgets.add(Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: GestureDetector(
            onTap: () => showImagePreview(
              context,
              bytes: _newFormImageBytes,
              title: _formSearchCtl.text.trim().isNotEmpty
                  ? _formSearchCtl.text.trim()
                  : null,
            ),
            child: Image.memory(_newFormImageBytes!, height: 100),
          ),
        ));
      }
      widgets.add(ElevatedButton.icon(
        onPressed: _pickNewFormImage,
        icon: const Icon(Icons.photo_library),
        label: const Text('Выбрать фото (не обязательно)'),
      ));
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
      _newFormImageBytes = null;
      _selectedOldFormImageUrl = null;
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
      if (_isOldForm) {
        if (_selectedOldFormRow != null) {
          return _oldFormInputValue(_selectedOldFormRow!);
        }
        if (_selectedOldForm != null && _selectedOldForm!.trim().isNotEmpty) {
          return _selectedOldForm!.trim();
        }
        return '-';
      } else {
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
