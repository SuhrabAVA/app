// lib/modules/orders/edit_order_screen.dart
import 'dart:async';
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
import '../production_planning/template_provider.dart';
import '../production_planning/template_model.dart';
import '../warehouse/warehouse_provider.dart';
import '../warehouse/stock_tables.dart';
import '../warehouse/tmc_model.dart';
import '../personnel/personnel_provider.dart';
import '../tasks/task_provider.dart';

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

  _PaintEntry(
      {this.tmc,
      this.name,
      this.qtyGrams,
      this.memo = '',
      this.exceeded = false});

  String get displayName => tmc?.description ?? name ?? '';
  bool get hasName => displayName.trim().isNotEmpty;
  double? get qtyKg => qtyGrams == null ? null : qtyGrams! / 1000;
  set qtyKg(double? value) => qtyGrams = value == null ? null : value * 1000;
}

class _StageRuleOutcome {
  final List<Map<String, dynamic>> stages;
  final bool shouldCompleteBobbin;
  final String? bobbinId;

  const _StageRuleOutcome(
      {required this.stages, this.shouldCompleteBobbin = false, this.bobbinId});
}

class _EditOrderScreenState extends State<EditOrderScreen> {
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
  Uint8List? _formImageBytes;

  Future<void> _loadOrderFormDisplay() async {
    try {
      final row = await _sb
          .from('orders')
          .select('is_old_form, new_form_no, form_series, form_code')
          .eq('id', widget.order!.id)
          .maybeSingle();
      if (!mounted) return;
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
        _orderFormIsOld = isOld;
        _orderFormNo = no;
        _orderFormSeries = series.isNotEmpty ? series : null;
        _orderFormCode = code.isNotEmpty ? code : null;
        _orderFormDisplay = display;
        if (!_formStateInitialized) {
          if (isOld != null) {
            _isOldForm = isOld;
          }
          _editingForm = !(no != null || code.isNotEmpty);
          _formStateInitialized = true;
        }
      });

      // Загрузка дополнительных деталей формы (размер, цвета, изображение)
      try {
        if (series.isNotEmpty && no != null) {
          final form = await _sb
              .from('forms')
              .select('title, description, image_url, size, product_type, colors')
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
              final bool enabled =
                  enabledRaw is bool ? enabledRaw : ((row['status'] ?? '') != 'disabled');
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
        final selectedValue =
            _selectedOldFormRow != null ? _oldFormInputValue(_selectedOldFormRow!) : null;
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
    _formSearchDebounce =
        Timer(const Duration(milliseconds: 250), () => _reloadForms(search: value));
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
    });
    _updateStockExtraQtyController();
    if (trimmed.isEmpty) {
      _updateStockExtra(query: '');
    } else {
      _stockExtraSearchDebounce = Timer(
          const Duration(milliseconds: 250), () => _updateStockExtra(query: trimmed));
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
      _stockExtraResults = [];
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

  final _formKey = GlobalKey<FormState>();
  final _uuid = const Uuid();
  final SupabaseClient _sb = Supabase.instance.client;

  // Персонал: выбранный менеджер из списка сотрудников с ролью «Менеджер»
  String? _selectedManager;
  final TextEditingController _managerDisplayController = TextEditingController();
  // Список доступных менеджеров (ФИО), загружается из PersonnelProvider
  List<String> _managerNames = [];
  // Клиент и комментарии
  late TextEditingController _customerController;
  late TextEditingController _commentsController;
  DateTime? _orderDate;
  DateTime? _dueDate;
  bool _contractSigned = false;
  bool _paymentDone = false;
  late ProductModel _product;
  List<String> _selectedParams = [];
  // Ручки (из склада)
  String? _selectedHandleId;
  String _selectedHandleDescription = '-';
  // Картон: либо «нет», либо «есть»
  String _selectedCardboard = 'нет';
  double _makeready = 0;
  double _val = 0;
  String? _stageTemplateId;
  final TextEditingController _stageTemplateController = TextEditingController();
  final FocusNode _stageTemplateFocusNode = FocusNode();
  String _stageTemplateSearchText = '';
  String? _selectedStageTemplateName;
  List<Map<String, dynamic>> _stagePreviewStages = <Map<String, dynamic>>[];
  bool _stagePreviewLoading = false;
  String? _stagePreviewError;
  bool _stagePreviewScheduled = false;
  bool _stagePreviewInitialized = false;
  bool _updatingStageTemplateText = false;
  bool _lastPreviewPaintsFilled = false;
  MaterialModel? _selectedMaterial;
  TmcModel? _selectedMaterialTmc;
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
  final TextEditingController _stockExtraSearchController = TextEditingController();
  final FocusNode _stockExtraFocusNode = FocusNode();
  Timer? _stockExtraSearchDebounce;
  bool _loadingStockExtra = false;
  List<Map<String, dynamic>> _stockExtraResults = [];
  Map<String, dynamic>? _selectedStockExtraRow;
  bool _writeOffStockExtra =
      false; // <-- добавлено: списывать ли лишнее при сохранении
  bool _stockExtraQtyTouched = false;
  final TextEditingController _stockExtraQtyController = TextEditingController();

  PlatformFile? _pickedPdf;
  bool _lengthExceeded = false;
  // Краски (мультисекция)
  final List<_PaintEntry> _paints = <_PaintEntry>[];
  bool _paintsRestored = false;
  bool _fetchedOrderForm = false;
  // Форма: использование старой формы или создание новой
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
  final Map<String, double> _paperWriteoffBaselineByItem = {};
  // Выбранный номер старой формы
  String? _selectedOldForm;
  // Фактическое количество (пока не вычисляется)
  String _actualQuantity = '';
  // ===== Категории склада для поля "Наименование изделия" =====
  List<String> _categoryTitles = [];
  bool _catsLoading = false;

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
    _contractSigned = template?.contractSigned ?? false;
    _paymentDone = template?.paymentDone ?? false;
    _selectedParams = List<String>.from(template?.additionalParams ?? const []);
    final initialHandle = template?.handle?.trim();
    if (initialHandle != null && initialHandle.isNotEmpty && initialHandle != '-') {
      _selectedHandleDescription = initialHandle;
    } else {
      _selectedHandleDescription = '-';
    }

    // Заменяем старое значение «офсет» на «есть», если встречается в переданном заказе
    final rawCardboard = template?.cardboard ?? 'нет';
    _selectedCardboard = rawCardboard == 'офсет' ? 'есть' : rawCardboard;
    _makeready = template?.makeready ?? 0;
    _val = template?.val ?? 0;
    _stageTemplateId = template?.stageTemplateId;
    _selectedMaterial = template?.material;

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
        length: null,
        leftover: null,
      );
    }
    _stockExtraSelectedQty =
        (_product.leftover != null && _product.leftover! > 0)
            ? _product.leftover
            : null;
    _stockExtraQtyTouched = _stockExtraSelectedQty != null;
    _updateStockExtraQtyController();
    // ensure at least one paint row only for new orders (not editing)
    if (_paints.isEmpty && widget.order == null) _paints.add(_PaintEntry());
    _loadCategoriesForProduct();
    WidgetsBinding.instance.addPostFrameCallback((_) => _updateStockExtra());
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final warehouse = context.read<WarehouseProvider>();
      if (warehouse.getTmcByType('pens').isEmpty) {
        warehouse.fetchTmc();
      }
    });

    final String? initialMaterialId = _selectedMaterial?.id;
    if (initialMaterialId != null && initialMaterialId.isNotEmpty) {
      _paperWriteoffBaselineByItem[initialMaterialId] =
          (_product.length ?? 0).toDouble();
    }
  }

  String _formatActualQuantity(double value) {
    if (value.isNaN || value.isInfinite) return '';
    if ((value - value.round()).abs() < 1e-6) {
      return value.round().toString();
    }
    final formatted = value.toStringAsFixed(3);
    return formatted
        .replaceFirst(RegExp(r'0+$'), '')
        .replaceFirst(RegExp(r'\.$'), '');
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
    final dynamic raw = stage['stageName'] ??
        stage['workplaceName'] ??
        stage['title'] ??
        stage['name'];
    if (raw is String && raw.trim().isNotEmpty) {
      return raw.trim();
    }
    return 'Без названия';
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
            RegExp(r'^[a-z0-9_\-]+$')
                .hasMatch(flexoTitle!.toLowerCase())) {
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
            .eq('id', 'w_bobbiner')
            .maybeSingle();
      }
      if (bob != null) {
        bobbinId = (bob['id'] as String?) ?? bobbinId;
        bobbinTitle =
            (bob['title'] as String?) ?? (bob['name'] as String?) ?? bobbinTitle;
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
      final match =
          RegExp(r'[0-9]+(?:[.,][0-9]+)?').firstMatch(source.replaceAll(',', '.'));
      if (match == null) return null;
      return double.tryParse(match.group(0)!);
    }

    bool formatMatchesWidth() {
      final candidates = <String?>[
        _selectedMaterial?.format,
        _matSelectedFormat,
        _selectedMaterialTmc?.format,
      ];
      double? fmtWidth;
      for (final candidate in candidates) {
        fmtWidth = _parseLeadingNumber(candidate);
        if (fmtWidth != null) break;
      }

      final double? productWidth = (_product.widthB ?? _product.width).toDouble();
      return fmtWidth != null &&
          productWidth != null &&
          productWidth > 0 &&
          (fmtWidth - productWidth).abs() <= 0.001;
    }

    bool paintsFilled = _hasAnyPaints();

    if (paintsFilled) {
      flexoId ??= 'w_flexoprint';
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
                ((m['stageName'] ?? m['title']) as String?)?.toLowerCase() ?? '';
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

    if (formatMatchesWidth()) {
      removedBobbinStage = removeBobbinStage();
      if (removedBobbinStage != null) {
        shouldCompleteBobbin = true;
        bobbinId = (removedBobbinStage['stageId'] ??
                removedBobbinStage['stage_id'] ??
                removedBobbinStage['stageid'] ??
                removedBobbinStage['workplaceId'] ??
                removedBobbinStage['workplace_id'] ??
                removedBobbinStage['id'])
            ?.toString();
      }
    } else {
      final hasBobbin = findStageIndex((m) {
            final sid = (m['stageId'] as String?) ??
                (m['stageid'] as String?) ??
                (m['stage_id'] as String?) ??
                (m['workplaceId'] as String?) ??
                (m['workplace_id'] as String?) ??
                (m['id'] as String?);
            if (sid != null && bobbinId != null && sid == bobbinId) return true;
            final title =
                ((m['stageName'] ?? m['title']) as String?)?.toLowerCase() ?? '';
            return title.contains('бобинорезка') ||
                title.contains('бабинорезка') ||
                title.contains('bobbin');
          }) >=
          0;
      if (!hasBobbin) {
        final resolvedId = (bobbinId != null && bobbinId!.isNotEmpty)
            ? bobbinId
            : (removedBobbinStage != null
                ? (removedBobbinStage['stageId'] as String?)
                : null);
        final resolvedTitle = (bobbinTitle?.trim().isNotEmpty ?? false)
            ? bobbinTitle
            : 'Бабинорезка';
        final fallbackId = resolvedId ?? 'w_bobbiner';
        stageMaps.insert(0, {
          'stageId': fallbackId,
          'workplaceId': fallbackId,
          'stageName': resolvedTitle,
          'workplaceName': resolvedTitle,
          'order': 0,
        });
        bobbinId = fallbackId;
      }
    }

    final List<Map<String, dynamic>> normalized = <Map<String, dynamic>>[];
    final Set<String> uniqueStageIds = <String>{};

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
        if (uniqueStageIds.contains(stageId)) {
          continue;
        }
        uniqueStageIds.add(stageId);
        map['stageId'] = stageId;
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
      final hasMemo = paint.memo.trim().isNotEmpty;
      if (hasTmc || hasName || hasQty || hasMemo) {
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

  String? _formatGramsForInput(double? grams) {
    if (grams == null) return null;
    if (grams == 0) return '0';
    final fixed = grams.toStringAsFixed(grams % 1 == 0 ? 0 : 2);
    return fixed
        .replaceFirst(RegExp(r'0+$'), '')
        .replaceFirst(RegExp(r'\.$'), '');
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
    final trimmed = fixed
        .replaceFirst(RegExp(r'0+$'), '')
        .replaceFirst(RegExp(r'\.$'), '');
    return '$trimmed г';
  }

  double? _parseGrams(String value) {
    final normalized = value.replaceAll(',', '.').trim();
    if (normalized.isEmpty) return null;
    return double.tryParse(normalized);
  }

  bool _hasAssignedForm() {
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

    final rawStages = tpl.stages
        .map((s) => {
              'stageId': s.stageId,
              'workplaceId': s.stageId,
              'stageName': s.stageName,
              'workplaceName': s.stageName,
            })
        .toList();

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
          _managerNames = List<String>.from(_managerNames)..add(_selectedManager!);
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
              .select('is_old_form, new_form_no')
              .eq('id', widget.order!.id)
              .maybeSingle();
          if (mounted) {
            setState(() {
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
              .select('is_old_form, new_form_no, form_series, form_code')
              .eq('id', widget.order!.id)
              .maybeSingle();
          if (mounted) {
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

  Future<void> _updateStockExtra({String? query}) async {
    final typeTitle = _product.type.trim();
    final search = query ?? _stockExtraSearchController.text.trim();
    if (typeTitle.isEmpty) {
      if (mounted) {
        setState(() {
          _stockExtra = null;
          _stockExtraItem = null;
          _stockExtraResults = [];
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
      final cat = await _sb
          .from('warehouse_categories')
          .select('id, title, code')
          .or('title.eq.' + typeTitle + ',code.eq.' + typeTitle)
          .maybeSingle();
      if (cat == null) {
        if (mounted) {
          setState(() {
            _stockExtra = null;
            _stockExtraItem = null;
            _stockExtraResults = [];
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

      var builder = _sb
          .from('warehouse_category_items')
          .select('id, description, quantity, table_key, size')
          .eq('category_id', cat['id']);
      if (search.isNotEmpty) {
        final sanitized = search.replaceAll("'", "''");
        builder = builder.or(
            'description.ilike.%$sanitized%,size.ilike.%$sanitized%');
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
          nextSelectedQty = math.max(0, math.min(templateLeftover, maxAvailable));
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
          _stockExtraResults =
              search.isEmpty ? <Map<String, dynamic>>[] : results;
          _loadingStockExtra = false;
          _stockExtraSelectedQty = nextSelectedQty;
          _product.leftover =
              nextSelectedQty != null && nextSelectedQty > 0 ? nextSelectedQty : null;
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
          _stockExtraResults = [];
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
    if (!_paperWriteoffBaselineByItem.containsKey(tmc.id)) {
      _paperWriteoffBaselineByItem[tmc.id] = 0.0;
    }
    if (_product.length != null) {
      _lengthExceeded = _product.length! > tmc.quantity;
    }
    setState(() {});
    _scheduleStagePreviewUpdate();
  }

  void _restorePaintsFromParams(WarehouseProvider warehouse) {
    if (_paintsRestored) return;
    final template = widget.order ?? widget.initialOrder;
    final params = template?.product.parameters ?? '';
    if (params.isEmpty || !params.contains('Краска:')) {
      _paintsRestored = true;
      return;
    }
    final paintTmcList = warehouse.getTmcByType('Краска');
    final reg = RegExp(
        r'Краска:\s*(.+?)\s+([0-9]+(?:[.,][0-9]+)?)\s*(кг|г)(?:\s*\(([^)]+)\))?',
        multiLine: false,
        caseSensitive: false);
    final matches = reg.allMatches(params).toList();
    if (matches.isEmpty) {
      _paintsRestored = true;
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
      final grams =
          (unit.contains('г')) ? qty : qty * 1000; // default to kg -> grams
      TmcModel? found;
      for (final t in paintTmcList) {
        if (t.description.trim() == name) {
          found = t;
          break;
        }
      }
      if (found != null) {
        restored.add(_PaintEntry(
            tmc: found,
            name: found.description,
            qtyGrams: grams,
            memo: memo));
      } else {
        restored.add(_PaintEntry(name: name, qtyGrams: grams, memo: memo));
      }
    }
    if (restored.isNotEmpty) {
      setState(() {
        _paints
          ..clear()
          ..addAll(restored);
        _paintsRestored = true;
      });
      _handlePaintsChanged();
    } else {
      _paintsRestored = true;
    }
  }

  /// Сохраняет список красок в таблицу order_paints и синхронизирует product.parameters.
  Future<void> _persistPaints(String orderId) async {
    // 1) Всегда чистим строки "Краска: ..." в product.parameters
    final cleanRe = RegExp(r'(?:^|;\s*)Краска:\s*.+?(?=(?:;\s*Краска:|$))');
    var clean = _product.parameters.replaceAll(cleanRe, '').trim();
    if (clean.endsWith(';')) {
      clean = clean.substring(0, clean.length - 1).trim();
    }

    // 2) Строим список строк и записей для order_paints
    final rows = <Map<String, dynamic>>[];
    final infos = <String>[];
    for (final row in _paints) {
      final name = (row.tmc?.description ?? row.name)?.trim();
      final qtyGrams = row.qtyGrams ?? 0;
      if (name == null || name.isEmpty) continue;
      rows.add({
        'order_id': orderId,
        'name': name,
        'info': row.memo.isNotEmpty ? row.memo : null,
        'qty_kg': row.qtyKg, // может быть null
      });
      if (qtyGrams > 0) {
        infos.add(
            'Краска: $name ${_formatGrams(qtyGrams)}${row.memo.isNotEmpty ? ' (${row.memo})' : ''}');
      }
    }

    // 3) Обновляем product.parameters
    if (infos.isNotEmpty) {
      final joined = infos.join('; ');
      _product.parameters = clean.isEmpty ? joined : '$clean; $joined';
    } else {
      _product.parameters = clean;
    }

    // 4) Перезаписываем таблицу order_paints
    try {
      // удаляем старые
      await _sb.from('order_paints').delete().eq('order_id', orderId);
      // вставляем новые
      if (rows.isNotEmpty) {
        await _sb.from('order_paints').insert(rows);
      }
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
            final qtyKg =
                (qtyRaw is num) ? qtyRaw.toDouble() : double.tryParse('$qtyRaw');
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
              restored.add(
                  _PaintEntry(name: name, qtyGrams: grams, memo: memo));
            }
          }
          setState(() {
            _paints
              ..clear()
              ..addAll(restored.isNotEmpty ? restored : _paints);
            _paintsRestored = true;
          });
          _handlePaintsChanged();
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
    // Флаг: создаём новый заказ или редактируем
    final bool isCreating = (widget.order == null);
    if (!_formKey.currentState!.validate()) return;
    if (_orderDate == null) {
      if (mounted)
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Укажите дату заказа')),
        );
      return;
    }
    if (_dueDate == null) {
      if (mounted)
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Укажите срок выполнения')),
        );
      return;
    }
    if (_lengthExceeded) {
      if (mounted)
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Недостаточно материала на складе')),
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
    late OrderModel createdOrUpdatedOrder;
    if (widget.order == null) {
      // создаём новый заказ
      final _created = await provider.createOrder(
        manager: managerName,
        customer: _customerController.text.trim(),
        orderDate: _orderDate!,
        dueDate: _dueDate,
        product: _product,
        additionalParams: _selectedParams,
        handle: _selectedHandleDescription == '-' ? '-' : _selectedHandleDescription,
        cardboard: _selectedCardboard,
        material: _selectedMaterial,
        makeready: _makeready,
        val: _val,
        stageTemplateId: _stageTemplateId,
        contractSigned: _contractSigned,
        paymentDone: _paymentDone,
        comments: _commentsController.text.trim(),
      );
      if (_created == null) {
        if (mounted)
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Не удалось создать заказ')),
          );
        return;
      }
      createdOrUpdatedOrder = _created;
    } else {
      // обновляем существующий заказ, сохраняя assignmentId/assignmentCreated
      final updated = OrderModel(
        id: widget.order!.id,
        manager: managerName,
        customer: _customerController.text.trim(),
        orderDate: _orderDate!,
        dueDate: _dueDate,
        product: _product,
        additionalParams: _selectedParams,
        handle: _selectedHandleDescription == '-' ? '-' : _selectedHandleDescription,
        cardboard: _selectedCardboard,
        material: _selectedMaterial,
        makeready: _makeready,
        val: _val,
        pdfUrl: widget.order!.pdfUrl,
        stageTemplateId: _stageTemplateId,
        contractSigned: _contractSigned,
        paymentDone: _paymentDone,
        comments: _commentsController.text.trim(),
        status: widget.order!.status,
        assignmentId: widget.order!.assignmentId,
        assignmentCreated: widget.order!.assignmentCreated,
      );
      await provider.updateOrder(updated);
      createdOrUpdatedOrder = updated;
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
          makeready: createdOrUpdatedOrder.makeready,
          val: createdOrUpdatedOrder.val,
          pdfUrl: createdOrUpdatedOrder.pdfUrl,
          stageTemplateId: createdOrUpdatedOrder.stageTemplateId,
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
        if (stagesData is List) {
          for (final item in stagesData.whereType<Map>()) {
            stageMaps.add(Map<String, dynamic>.from(item));
          }
        } else if (stagesData is Map) {
          (stagesData as Map).forEach((_, value) {
            if (value is Map) {
              stageMaps.add(Map<String, dynamic>.from(value));
            }
          });
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

        // Build a list of valid stage IDs (must exist in 'workplaces')
        final List<String> __validStageIds = [];
        for (final sm in stageMaps) {
          final sid = (sm['stageId'] as String?) ??
              (sm['stageid'] as String?) ??
              (sm['stage_id'] as String?) ??
              (sm['id'] as String?);
          if (sid == null || sid.isEmpty) continue;
          try {
            final exists = await _sb
                .from('workplaces')
                .select('id')
                .eq('id', sid)
                .maybeSingle();
            if (exists != null) __validStageIds.add(sid);
          } catch (_) {}
        }
        if (__validStageIds.isNotEmpty) {
          await _sb
              .from('tasks')
              .delete()
              .eq('order_id', createdOrUpdatedOrder.id);
          // create new tasks for each stage
        } else {
          // No valid stages resolved — keep existing tasks to avoid losing assignments
          // (logically indicates a template/config error)
        }
        // create new tasks for each stage (only if stage exists)
        for (final sm in stageMaps) {
          final stageId = (sm['stageId'] as String?) ??
              (sm['stageid'] as String?) ??
              (sm['stage_id'] as String?) ??
              (sm['workplaceId'] as String?) ??
              (sm['workplace_id'] as String?) ??
              (sm['id'] as String?);
          if (stageId == null || stageId.isEmpty) continue;
          try {
            final exists = await _sb
                .from('workplaces')
                .select('id')
                .eq('id', stageId)
                .maybeSingle();
            if (exists == null)
              continue; // skip invalid stageId to avoid FK/insert errors
            await _sb.from('tasks').insert({
              'order_id': createdOrUpdatedOrder.id,
              'stage_id': stageId,
              'status': 'waiting',
              'assignees': [],
              'comments': [],
            });
          } catch (e) {
            // ignore problematic stage ids to avoid breaking whole save
          }
        }

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
          for (final sm in stageMaps) {
            final stageId =
                (sm['stageId'] as String?) ?? (sm['stage_id'] as String?);
            if (stageId == null || stageId.isEmpty) continue;
            await _sb.from('prod_plan_stages').insert({
              'plan_id': planId,
              'stage_id': stageId,
              'step': step++,
              'status': 'waiting',
            });
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

        // update order status
        // Mark Bobbin (Бабинорезка) as done when format equals width for this order only
        if (__shouldCompleteBobbin && __bobbinId != null) {
          await _sb.from('tasks').update({
            'status': 'done',
            'completed_at': DateTime.now().toIso8601String(),
          }).match({
            'order_id': createdOrUpdatedOrder.id,
            'stage_id': __bobbinId,
          });
        }

        // update order status to inWork and mark assignment
        final withAssignment = OrderModel(
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
          makeready: createdOrUpdatedOrder.makeready,
          val: createdOrUpdatedOrder.val,
          pdfUrl: createdOrUpdatedOrder.pdfUrl,
          stageTemplateId: createdOrUpdatedOrder.stageTemplateId,
          contractSigned: createdOrUpdatedOrder.contractSigned,
          paymentDone: createdOrUpdatedOrder.paymentDone,
          comments: createdOrUpdatedOrder.comments,
          status: OrderStatus.inWork.name,
          assignmentId: provider.generateAssignmentId(),
          assignmentCreated: true,
        );
        await provider.updateOrder(withAssignment);
        await provider.refresh();
        if (mounted) {
          await context.read<TaskProvider>().refresh();
        }
        createdOrUpdatedOrder = withAssignment;
      }
    }
    // === Обработка формы ===
    await _processFormAssignment(
      createdOrUpdatedOrder,
      isCreating: isCreating,
    );
    // === Конец обработки формы ===

    // Списание материалов/готовой продукции (бумага по длине L)
    final TmcModel? paperTmc = _selectedMaterialTmc ?? _resolvePaperByText();
    final double need = (_product.length ?? 0).toDouble();
    if (paperTmc != null && need > 0) {
      final current = Provider.of<WarehouseProvider>(context, listen: false)
          .allTmc
          .where((t) => t.id == paperTmc.id)
          .toList();
      final double availableQty =
          current.isNotEmpty ? current.first.quantity : paperTmc.quantity;
      final String itemId = paperTmc.id;
      final double prevLen = _paperWriteoffBaselineByItem[itemId] ??
          ((widget.order?.material?.id == itemId)
              ? (widget.order?.product.length ?? 0).toDouble()
              : 0.0);
      final double toWriteOff = need - prevLen;

      if (toWriteOff > 0 && toWriteOff > availableQty) {
        if (mounted)
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
                content: Text(
                    'Недостаточно материала на складе - обновите остатки или уменьшите длину L')),
          );
        return;
      }

      try {
        await provider.applyPaperWriteoff(createdOrUpdatedOrder);
        if (toWriteOff > 0) {
          await warehouse.fetchTmc();
        }
      } catch (error) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('Не удалось списать бумагу: ${error.toString()}'),
            ),
          );
        }
        return;
      }

      _paperWriteoffBaselineByItem[itemId] = need;
    }

    // Повторная выборка позиций из динамической категории перед списанием - чтобы не зависеть от состояния UI.
    if (_writeOffStockExtra) {
      await AppAuth.ensureSignedIn();

      try {
        final String typeTitle = _product.type.trim();
        final selectedExtra = _selectedStockExtraRow;
        final String? sizeLabel = _productSizeLabel();
        final double selectedQty =
            (_stockExtraSelectedQty != null && _stockExtraSelectedQty! > 0)
                ? _stockExtraSelectedQty!
                : 0;
        if (selectedExtra != null &&
            typeTitle.isNotEmpty &&
            selectedQty > 0) {
          final cat = await _sb
              .from('warehouse_categories')
              .select('id, title, code')
              .or('title.eq.' + typeTitle + ',code.eq.' + typeTitle)
              .maybeSingle();
          if (cat != null) {
            final itemId = selectedExtra['id']?.toString();
            if (itemId != null) {
              final row = await _sb
                  .from('warehouse_category_items')
                  .select('quantity, category_id')
                  .eq('id', itemId)
                  .maybeSingle();
              if (row != null &&
                  row['category_id']?.toString() == cat['id']?.toString()) {
                final qv = row['quantity'];
                final double q = (qv is num)
                    ? qv.toDouble()
                    : double.tryParse('${qv ?? ''}') ?? 0.0;
                final double qtyToWriteOff =
                    math.max(0, math.min(selectedQty, q));
                if (qtyToWriteOff > 0) {
                  final writeoffPayload = {
                    'item_id': itemId,
                    'qty': qtyToWriteOff,
                    'reason': _customerController.text.trim(),
                    'by_name': AuthHelper.currentUserName ?? '',
                  };
                  if (sizeLabel != null && sizeLabel.isNotEmpty) {
                    writeoffPayload['size'] = sizeLabel;
                  }
                  await _sb
                      .from('warehouse_category_writeoffs')
                      .insert(writeoffPayload);
                  await _sb
                      .from('warehouse_category_items')
                      .update({
                        'quantity': math.max(0, q - qtyToWriteOff),
                        if (sizeLabel != null && sizeLabel.isNotEmpty)
                          'size': sizeLabel,
                      })
                      .match({'id': itemId});
                }
              }
            }
          }
        }
      } catch (e) {
        if (mounted) {
          if (mounted)
            ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                content: Text('Ошибка списания лишнего: ' + e.toString())));
        }
      }
    }

// Независимо от создания/редактирования - синхронизируем список красок
// c полем product.parameters и таблицей order_paints.
    await _persistPaints(createdOrUpdatedOrder.id);
    if (mounted) Navigator.of(context).pop();
  }

  String _formatDecimal(double value, {int fractionDigits = 2}) {
    final formatted = value.toStringAsFixed(fractionDigits);
    return formatted
        .replaceFirst(RegExp(r'0+$'), '')
        .replaceFirst(RegExp(r'\.$'), '');
  }

  String? _productSizeLabel() {
    String format(double value) {
      final String fixed = value.toStringAsFixed(2);
      final String trimmed = fixed
          .replaceAll(RegExp(r'0+$'), '')
          .replaceAll(RegExp(r'[.]$'), '');
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
    final widthB = formatDimension(_product.widthB);
    if (widthB != null) extras.add('Б $widthB');
    final length = formatDimension(_product.length);
    if (length != null) extras.add('L $length');
    if (extras.isNotEmpty) {
      final extraText = extras.join(', ');
      result = result.isEmpty ? extraText : '$result ($extraText)';
    }

    result = result.trim();
    return result.isEmpty ? null : result;
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
          selectedFormNumber =
              ((form['number'] ?? 0) as num?)?.toInt();
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
          selectedFormNumber =
              ((created['number'] ?? 0) as num?)?.toInt();
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
    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () => Navigator.of(context).pop(),
        ),
        title: Text(isEditing
            ? 'Редактирование заказа ${(widget.order!.assignmentId ?? widget.order!.id)}'
            : 'Новый заказ'),
        actions: [
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
          TextButton(
            onPressed: () async {
              await _saveOrder();
            },
            child:
                const Text('Сохранить', style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
      body: Form(
        key: _formKey,
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            _buildOrderInfoSection(context),
            const SizedBox(height: 12),
            _buildProductBasics(_product),
            const SizedBox(height: 12),
            _buildHandlesSection(context),
            const SizedBox(height: 12),
            _buildPaintsSection(),
            const SizedBox(height: 12),
            _buildFormSection(
              context: context,
              showFormSummary: showFormSummary,
              showFormEditor: showFormEditor,
              isEditing: isEditing,
              hasAssignedForm: hasAssignedForm,
            ),
            const SizedBox(height: 12),
            _buildProductMaterialAndExtras(_product),
            const SizedBox(height: 12),
            _buildProductionSection(context),
            const SizedBox(height: 12),
            TextFormField(
              controller: _commentsController,
              decoration: const InputDecoration(
                labelText: 'Комментарии к заказу',
                border: OutlineInputBorder(),
              ),
              minLines: 2,
              maxLines: 5,
            ),
            const SizedBox(height: 12),
          ],
        ),
      ),
    );
  }

  /// Базовые поля продукта (наименование, тираж, габариты)
  Widget _buildProductBasics(ProductModel product) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _buildFieldGrid([
          Consumer<ProductsProvider>(
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
                  _updateStockExtra();
                },
              );
            },
          ),
          TextFormField(
            initialValue: product.quantity > 0 ? product.quantity.toString() : '',
            decoration: const InputDecoration(
              labelText: 'Тираж',
              border: OutlineInputBorder(),
            ),
            keyboardType: TextInputType.number,
            onChanged: (val) {
              final qty = int.tryParse(val) ?? 0;
              product.quantity = qty;
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
          ),
        ], breakpoint: 680, minItemWidth: 220),
        const SizedBox(height: 12),
        _buildFieldGrid([
          TextFormField(
            initialValue: product.width > 0 ? product.width.toString() : '',
            decoration: const InputDecoration(
              labelText: 'Ширина (мм)',
              border: OutlineInputBorder(),
            ),
            keyboardType: TextInputType.number,
            onChanged: (val) {
              final normalized = val.replaceAll(',', '.');
              setState(() {
                product.width = double.tryParse(normalized) ?? 0;
              });
              _scheduleStagePreviewUpdate();
            },
          ),
          TextFormField(
            initialValue: product.height > 0 ? product.height.toString() : '',
            decoration: const InputDecoration(
              labelText: 'Высота (мм)',
              border: OutlineInputBorder(),
            ),
            keyboardType: TextInputType.number,
            onChanged: (val) {
              final normalized = val.replaceAll(',', '.');
              setState(() {
                product.height = double.tryParse(normalized) ?? 0;
              });
            },
          ),
          TextFormField(
            initialValue: product.depth > 0 ? product.depth.toString() : '',
            decoration: const InputDecoration(
              labelText: 'Глубина (мм)',
              border: OutlineInputBorder(),
            ),
            keyboardType: TextInputType.number,
            onChanged: (val) {
              final normalized = val.replaceAll(',', '.');
              setState(() {
                product.depth = double.tryParse(normalized) ?? 0;
              });
            },
          ),
        ], breakpoint: 760, maxColumns: 3, minItemWidth: 180),
      ],
    );
  }

  /// Дополнительные параметры продукта: материал, складские остатки и вложения
  Widget _buildProductMaterialAndExtras(ProductModel product) {
    final paperQty = _currentAvailablePaperQty();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
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

            return Column(
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
                                      .contains(
                                          _matNameCtl.text.trim().toLowerCase()))
                              ? null
                              : 'Выберите материал из списка';
                          _matFormatError = null;
                          _matGramError = null;
                          final lowerNames =
                              allNames.map((e) => e.toLowerCase()).toList();
                          final typed = _matNameCtl.text.trim().toLowerCase();
                          if (lowerNames.contains(typed)) {
                            _matSelectedName = allNames[lowerNames.indexOf(typed)];
                          }
                        });
                        _scheduleStagePreviewUpdate();
                      }
                    });
                    return TextField(
                      controller: controller,
                      focusNode: focusNode,
                      decoration: InputDecoration(
                        labelText: 'Материал',
                        border: const OutlineInputBorder(),
                        errorText: _matNameError,
                      ),
                      onSubmitted: (_) => onFieldSubmitted(),
                    );
                  },
                  onSelected: (value) {
                    setState(() {
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
                const SizedBox(height: 8),
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
                          _matFormatCtl.text = controller.text;
                          _matFormatCtl.selection = controller.selection;
                          _matSelectedFormat = null;
                          _matSelectedGrammage = null;
                          _matGramCtl.text = '';
                          _matFormatError = (_matFormatCtl.text.trim().isEmpty ||
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
                      decoration: InputDecoration(
                        labelText: 'Формат',
                        border: const OutlineInputBorder(),
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
                const SizedBox(height: 8),
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
                          _matGramCtl.text = controller.text;
                          _matGramCtl.selection = controller.selection;
                          _matSelectedGrammage = null;
                          _matGramError = (_matGramCtl.text.trim().isEmpty ||
                                  gramOptions
                                      .map((e) => e.toLowerCase())
                                      .contains(
                                          _matGramCtl.text.trim().toLowerCase()))
                              ? null
                              : 'Выберите грамаж из списка';
                          final lowerG =
                              gramOptions.map((e) => e.toLowerCase()).toList();
                          final typed = _matGramCtl.text.trim().toLowerCase();
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
                      enabled:
                          _matSelectedName != null && _matSelectedFormat != null,
                      decoration: InputDecoration(
                        labelText: 'Грамаж',
                        border: const OutlineInputBorder(),
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
                      _matGramCtl.text = value;
                      _matSelectedGrammage = value;
                      _matGramError = null;
                      final tmc =
                          findExact(_matSelectedName!, _matSelectedFormat!, value);
                      if (tmc != null) {
                        _selectMaterial(tmc);
                      }
                    });
                  },
                ),
                if (paperQty != null) ...[
                  const SizedBox(height: 8),
                  Text(
                      'Остаток бумаги по выбранному материалу: ${paperQty.toStringAsFixed(2)}'),
                ],
              ],
            );
          },
        ),
        const SizedBox(height: 12),
        _buildStockExtraLayout(
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: _stockExtraSearchController,
                focusNode: _stockExtraFocusNode,
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
              const SizedBox(height: 6),
              Text(
                _stockExtra != null
                    ? 'Доступно: ${_stockExtra!.toStringAsFixed(2)}'
                    : 'Доступно: —',
                style: Theme.of(context).textTheme.bodySmall,
              ),
              const SizedBox(height: 8),
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
                keyboardType:
                    const TextInputType.numberWithOptions(decimal: true),
                onChanged: (value) {
                  final normalized = value.replaceAll(',', '.');
                  final parsed = double.tryParse(normalized);
                  double? nextValue =
                      parsed != null && parsed >= 0 ? parsed : null;
                  if (nextValue != null && _stockExtra != null) {
                    final double available = _stockExtra!;
                    if (available >= 0 && nextValue > available) {
                      nextValue = available;
                      final text = _formatDecimal(available);
                      _stockExtraQtyController.value = TextEditingValue(
                        text: text,
                        selection:
                            TextSelection.collapsed(offset: text.length),
                      );
                    }
                  }
                  setState(() {
                    _stockExtraQtyTouched = true;
                    _stockExtraSelectedQty = nextValue;
                    _product.leftover =
                        _stockExtraSelectedQty != null &&
                                _stockExtraSelectedQty! > 0
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
              _buildStockExtraResults(),
            ],
          ),
          SwitchListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            title: const Text('Списать лишнее при сохранении'),
            value: _writeOffStockExtra,
            onChanged: (_selectedStockExtraRow != null &&
                    (_stockExtraSelectedQty ?? 0) > 0)
                ? (v) => setState(() => _writeOffStockExtra = v)
                : null,
          ),
        ),
        const SizedBox(height: 12),
        _buildFieldGrid([
          TextFormField(
            initialValue: product.widthB?.toString() ?? '',
            decoration: const InputDecoration(
              labelText: 'Ширина b',
              border: OutlineInputBorder(),
            ),
            keyboardType: TextInputType.number,
            onChanged: (val) {
              final normalized = val.replaceAll(',', '.');
              product.widthB = double.tryParse(normalized);
              _scheduleStagePreviewUpdate();
            },
          ),
          TextFormField(
            initialValue: product.length?.toString() ?? '',
            decoration: InputDecoration(
              labelText: 'Длина L',
              border: const OutlineInputBorder(),
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
                    final current = Provider.of<WarehouseProvider>(context,
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
        ], breakpoint: 680, minItemWidth: 200),
        const SizedBox(height: 12),
        Row(
          children: [
            ElevatedButton.icon(
              onPressed: _pickPdf,
              icon: const Icon(Icons.attach_file),
              label: Text(
                _pickedPdf?.name ??
                    (widget.order?.pdfUrl != null
                        ? widget.order!.pdfUrl!.split('/').last
                        : 'Прикрепить PDF'),
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
        ),
      ],
    );
  }

  Widget _buildSectionCard({
    required BuildContext context,
    required String title,
    required List<Widget> children,
  }) {
    final _ = title;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: children,
    );
  }

  Widget _buildFieldGrid(
    List<Widget> fields, {
    double breakpoint = 720,
    double spacing = 16,
    double runSpacing = 12,
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

  Widget _buildOrderInfoSection(BuildContext context) {
    return _buildSectionCard(
      context: context,
      title: 'Информация о заказе',
      children: [
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
        const SizedBox(height: 12),
        LayoutBuilder(
          builder: (context, constraints) {
            final bool narrow = constraints.maxWidth < 520;
            final contractTile = _buildContractSignedTile();
            final paymentTile = _buildPaymentDoneTile();
            if (narrow) {
              return Column(
                children: [
                  contractTile,
                  const SizedBox(height: 8),
                  paymentTile,
                ],
              );
            }
            return Row(
              children: [
                Expanded(child: contractTile),
                const SizedBox(width: 16),
                Expanded(child: paymentTile),
              ],
            );
          },
        ),
      ],
    );
  }

  Widget _buildHandlesSection(BuildContext context) {
    return _buildSectionCard(
      context: context,
      title: 'Дополнительные параметры',
      children: [
        Consumer<WarehouseProvider>(
          builder: (context, warehouse, _) {
            final seen = <String>{};
            final List<TmcModel> handleItems = [
              ...warehouse.getTmcByType('Ручки'),
              ...warehouse.getTmcByType('ручки'),
            ]
                .where((item) => seen.add(item.id))
                .toList(growable: true);
            handleItems.sort((a, b) =>
                a.description.toLowerCase().compareTo(b.description.toLowerCase()));

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
                  child: Text(item.description.isEmpty ? item.id : item.description),
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
                            _selectedHandleDescription == '-' ? '-' :
                                _selectedHandleDescription;
                      } else {
                        final desc = matches.first.description.trim();
                        _selectedHandleDescription =
                            desc.isEmpty ? '-' : matches.first.description;
                      }
                    }
                  });
                },
              ),
              DropdownButtonFormField<String>(
                value: _selectedCardboard,
                decoration: const InputDecoration(
                  labelText: 'Картон',
                  border: OutlineInputBorder(),
                ),
                items: const [
                  DropdownMenuItem(value: 'нет', child: Text('нет')),
                  DropdownMenuItem(value: 'есть', child: Text('есть')),
                ],
                onChanged: (val) =>
                    setState(() => _selectedCardboard = val ?? 'нет'),
              ),
            ],
                breakpoint: 680,
                maxColumns: 3,
                minItemWidth: 200,
                runSpacing: 16);
          },
        ),
      ],
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

  Widget _buildContractSignedTile() {
    return CheckboxListTile(
      value: _contractSigned,
      onChanged: (val) => setState(() => _contractSigned = val ?? false),
      title: const Text('Договор подписан'),
      dense: true,
      visualDensity: VisualDensity.compact,
      controlAffinity: ListTileControlAffinity.leading,
      contentPadding: EdgeInsets.zero,
    );
  }

  Widget _buildPaymentDoneTile() {
    return CheckboxListTile(
      value: _paymentDone,
      onChanged: (val) => setState(() => _paymentDone = val ?? false),
      title: const Text('Оплата произведена'),
      dense: true,
      visualDensity: VisualDensity.compact,
      controlAffinity: ListTileControlAffinity.leading,
      contentPadding: EdgeInsets.zero,
    );
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

  Widget _buildStockExtraLayout(Widget searchColumn, Widget writeOffSwitch) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final isWide = constraints.maxWidth >= 720;
        if (isWide) {
          return Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(child: searchColumn),
              const SizedBox(width: 16),
              SizedBox(width: 240, child: writeOffSwitch),
            ],
          );
        }
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            searchColumn,
            const SizedBox(height: 12),
            writeOffSwitch,
          ],
        );
      },
    );
  }

  Widget _buildProductionSection(BuildContext context) {
    return _buildSectionCard(
      context: context,
      title: 'Производство',
      children: [
        _buildFieldGrid([
          TextFormField(
            initialValue: _makeready > 0 ? '$_makeready' : '',
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
            initialValue: _val > 0 ? '$_val' : '',
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
        ], breakpoint: 680, minItemWidth: 200),
        const SizedBox(height: 16),
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
                        .where(
                            (tpl) => tpl.name.toLowerCase().contains(query));
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
                            (t) =>
                                t.name.toLowerCase() == value.toLowerCase(),
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
                const SizedBox(height: 12),
                _buildStagePreviewSection(context),
              ],
            );
          },
        ),
        const SizedBox(height: 16),
        TextFormField(
          initialValue: _actualQuantity,
          decoration: const InputDecoration(
            labelText: 'Фактическое количество',
            border: OutlineInputBorder(),
          ),
          readOnly: true,
        ),
      ],
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
  }) {
    final content = <Widget>[];
    if (showFormSummary) {
      content.addAll([
        _buildFormSummary(context),
        const SizedBox(height: 8),
        Align(
          alignment: Alignment.centerLeft,
          child: OutlinedButton.icon(
            onPressed: _startFormEditing,
            icon: const Icon(Icons.edit),
            label: const Text('Изменить форму'),
          ),
        ),
      ]);
    }
    if (showFormEditor) {
      if (content.isNotEmpty) {
        content.add(const SizedBox(height: 12));
      }
      if (isEditing && hasAssignedForm) {
        content.addAll([
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
      content.addAll(_buildFormEditorControls());
    }

    if (content.isNotEmpty) {
      content.add(const SizedBox(height: 12));
    }

    content.add(
      InputDecorator(
        decoration: const InputDecoration(
          labelText: 'Номер формы',
          border: OutlineInputBorder(),
        ),
        child: Text(_formDisplayPreview()),
      ),
    );

    return _buildSectionCard(
      context: context,
      title: 'Форма',
      children: content,
    );
  }

  Widget _buildPaintsSection() {
    return _buildSectionCard(
      context: context,
      title: 'Краски',
      children: [
        ...List.generate(_paints.length, (i) {
          final row = _paints[i];
          return Padding(
            padding: const EdgeInsets.only(bottom: 8.0),
            child: Row(
              children: [
                // Выбор краски
                Expanded(
                  flex: 5,
                  child: Autocomplete<TmcModel>(
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
                        decoration: const InputDecoration(
                          labelText: 'Краска (необязательно)',
                          border: OutlineInputBorder(),
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
                          _handlePaintsChanged();
                        },
                      );
                    },
                    onSelected: (tmc) {
                      setState(() {
                        row.tmc = tmc;
                        row.name = tmc.description;
                        if (row.qtyGrams != null) {
                          final need =
                              _gramsToStockUnit(row.qtyGrams!, tmc);
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
                          elevation: 4,
                          child: SizedBox(
                            width: 400,
                            height: 240,
                            child: ListView.builder(
                              itemCount: options.length,
                              itemBuilder: (context, index) {
                                final tmc = options.elementAt(index);
                                return ListTile(
                                  title: Text(tmc.description),
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
                  ),
                ),
                const SizedBox(width: 8),
                // Мелкая ячейка для пометок (напр. "1*2 4*0")
                SizedBox(
                  width: 100,
                  child: TextFormField(
                    key: ValueKey('memo_\${i}'),
                    initialValue: row.memo,
                    decoration: const InputDecoration(
                      labelText: 'Инфо',
                      border: OutlineInputBorder(),
                    ),
                    onChanged: (v) => setState(() => row.memo = v.trim()),
                  ),
                ),
                const SizedBox(width: 12),
                // Кол-во (г)
                SizedBox(
                  width: 130,
                  child: TextFormField(
                    key: ValueKey('qty_\${i}'),
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
                ),
                const SizedBox(width: 8),
                // Удаление строки
                if (_paints.length > 1)
                  IconButton(
                    tooltip: 'Удалить краску',
                    onPressed: () {
                      setState(() => _paints.removeAt(i));
                      _handlePaintsChanged();
                    },
                    icon: const Icon(Icons.remove_circle_outline),
                  ),
              ],
            ),
          );
        }),
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(
            onPressed: () {
              setState(() => _paints.add(_PaintEntry()));
              _handlePaintsChanged();
            },
            icon: const Icon(Icons.add),
            label: const Text('Добавить краску'),
          ),
        ),
      ],
    );
  }

  List<Widget> _buildFormEditorControls() {
    final widgets = <Widget>[
      SwitchListTile(
        title: Text(_isOldForm ? 'Старая форма' : 'Новая форма'),
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
        contentPadding: EdgeInsets.zero,
      ),
    ];

    if (_isOldForm) {
      widgets.add(TextField(
        controller: _formSearchCtl,
        focusNode: _formSearchFocusNode,
        decoration: const InputDecoration(
          hintText: 'Поиск формы (название или номер)',
          prefixIcon: Icon(Icons.search),
          border: OutlineInputBorder(),
        ),
        onChanged: _onFormSearchChanged,
      ));
      widgets.add(const SizedBox(height: 8));
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
          child: Image.network(imageUrl, height: 120),
        ));
      }
    } else {
      widgets.add(const SizedBox(height: 8));
      if (_newFormImageBytes != null) {
        widgets.add(Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: Image.memory(_newFormImageBytes!, height: 100),
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
    final items = <Widget>[];
    if (_orderFormDisplay != null &&
        _orderFormDisplay!.isNotEmpty &&
        _orderFormDisplay! != '-') {
      items.add(Text('Код формы: ${_orderFormDisplay!}'));
    }
    if (_orderFormIsOld != null) {
      items.add(Text(_orderFormIsOld! ? 'Старая форма' : 'Новая форма'));
    }
    if (_orderFormSeries != null && _orderFormSeries!.isNotEmpty) {
      items.add(Text('Название формы: ${_orderFormSeries!}'));
    }
    if (_orderFormNo != null) {
      items.add(Text('Номер формы: ${_orderFormNo}'));
    }
    if (_orderFormSize != null && _orderFormSize!.trim().isNotEmpty) {
      items.add(Text('Размер: ${_orderFormSize!}'));
    }
    if (_orderFormProductType != null &&
        _orderFormProductType!.trim().isNotEmpty) {
      items.add(Text('Тип продукта: ${_orderFormProductType!}'));
    }
    if (_orderFormColors != null && _orderFormColors!.trim().isNotEmpty) {
      items.add(Text('Цвета: ${_orderFormColors!}'));
    }
    if (_orderFormImageUrl != null && _orderFormImageUrl!.isNotEmpty) {
      items.add(Padding(
        padding: const EdgeInsets.only(top: 4),
        child: Image.network(
          _orderFormImageUrl!,
          height: 120,
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
            final size = (form['size'] ?? form['title'] ?? '').toString().trim();
            final productType = (form['product_type'] ?? '').toString().trim();
            final colors = (form['colors'] ?? form['description'] ?? '')
                .toString()
                .trim();
            final subtitle = <String>[];
            if (size.isNotEmpty) subtitle.add('Размер: $size');
            if (productType.isNotEmpty) subtitle.add('Тип: $productType');
            if (colors.isNotEmpty) subtitle.add('Цвета: $colors');
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
                  _selectedOldFormImageUrl = imageUrl.isNotEmpty ? imageUrl : null;
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
