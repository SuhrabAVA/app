// lib/modules/orders/edit_order_screen.dart
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
  double? qty;
  String memo;
  bool exceeded;
  _PaintEntry({this.tmc, this.qty, this.memo = '', this.exceeded = false});
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
  String _formSeries = 'F';
  List<Map<String, dynamic>> _formResults = [];
  Map<String, dynamic>? _selectedOldFormRow;
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
      });

      // Загрузка дополнительных деталей формы (размер, цвета, изображение)
      try {
        if (series.isNotEmpty && no != null) {
          final form = await _sb
              .from('forms')
              .select('title, description, image_url')
              .eq('series', series)
              .eq('number', no)
              .maybeSingle();
          if (mounted) {
            setState(() {
              _orderFormSize = (form?['title'] ?? '').toString();
              _orderFormColors = (form?['description'] ?? '').toString();
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
    setState(() => _loadingForms = true);
    try {
      final wp = WarehouseProvider();
      // Не фильтруем по _formSeries, поскольку series теперь хранит полное название
      _formResults = await wp.searchForms(
        query: search ?? _formSearchCtl.text,
        limit: 50,
      );
    } catch (_) {
    } finally {
      if (mounted) setState(() => _loadingForms = false);
    }
  }

  final _formKey = GlobalKey<FormState>();
  final _uuid = const Uuid();
  final SupabaseClient _sb = Supabase.instance.client;

  // Персонал: выбранный менеджер из списка сотрудников с ролью «Менеджер»
  String? _selectedManager;
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
  // Ручки (из склада): выбранная ручка
  String _selectedHandle = '-';
  // Картон: либо «нет», либо «есть»
  String _selectedCardboard = 'нет';
  double _makeready = 0;
  double _val = 0;
  String? _stageTemplateId;
  // Кол-во ручек для списания
  double? _handleQty;
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
  bool _writeOffStockExtra =
      false; // <-- добавлено: списывать ли лишнее при сохранении

  PlatformFile? _pickedPdf;
  bool _lengthExceeded = false;
  // Краски (мультисекция)
  final List<_PaintEntry> _paints = <_PaintEntry>[];
  bool _paintsRestored = false;
  bool _fetchedOrderForm = false;
  // Форма: использование старой формы или создание новой
  bool _isOldForm = false;
  // Список существующих форм (номера) из склада
  // Считанные из БД параметры формы для существующего заказа (только просмотр)
  bool? _orderFormIsOld;
  int? _orderFormNo;
  String? _orderFormSeries;
  String? _orderFormCode;
  String? _orderFormDisplay;
  // Детали формы для существующего заказа
  String? _orderFormSize;
  String? _orderFormColors;
  String? _orderFormImageUrl;

  List<String> _availableForms = [];
  // Номер новой формы по умолчанию (max+1)
  int _defaultFormNumber = 1;
  final TextEditingController _newFormNoCtl = TextEditingController();
  // Поля для создания новой формы (название, размер/тип, цвета)
  final TextEditingController _newFormNameCtl = TextEditingController();
  final TextEditingController _newFormSizeCtl = TextEditingController();
  final TextEditingController _newFormColorsCtl = TextEditingController();
  // Фото новой формы (при создании)
  Uint8List? _newFormImageBytes;
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

    super.initState();

    _reloadForms();
    // order передан при редактировании, initialOrder - при создании на основе шаблона
    final template = widget.order ?? widget.initialOrder;
    // Текущий менеджер будет выбран позже в didChangeDependencies, когда загрузится список менеджеров.
    // Здесь просто запомним имя менеджера из шаблона для последующего выбора.
    final initialManager =
        template is OrderModel ? (template as OrderModel).manager : '';
    _selectedManager = initialManager.isNotEmpty ? initialManager : null;
    _customerController = TextEditingController(text: template?.customer ?? '');
    _commentsController = TextEditingController(text: template?.comments ?? '');
    _orderDate = template?.orderDate;
    _dueDate = template?.dueDate;
    _contractSigned = template?.contractSigned ?? false;
    _paymentDone = template?.paymentDone ?? false;
    _selectedParams = List<String>.from(template?.additionalParams ?? const []);
    _selectedHandle = template?.handle ?? '-';
    // Если редактируем и есть строка 'Ручки:' в параметрах - подставим предыдущее количество
    try {
      if (_selectedHandle != '-' && widget.order != null) {
        final q = _previousPenQty(penName: _selectedHandle);
        if (q > 0) _handleQty = q;
      }
    } catch (_) {}

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
    _customerController.addListener(_updateStockExtra);
    // ensure at least one paint row only for new orders (not editing)
    if (_paints.isEmpty && widget.order == null) _paints.add(_PaintEntry());
    _loadCategoriesForProduct();
    WidgetsBinding.instance.addPostFrameCallback((_) => _updateStockExtra());
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
      if (_selectedManager != null &&
          !_managerNames.contains(_selectedManager)) {
        _selectedManager = null;
      }
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
              _newFormNoCtl.text = _defaultFormNumber.toString();
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
    _customerController.removeListener(_updateStockExtra);
    _customerController.dispose();
    _commentsController.dispose();

    _matNameCtl.dispose();
    _matFormatCtl.dispose();
    _matGramCtl.dispose();
    _newFormNoCtl.dispose();
    _newFormNameCtl.dispose();
    _newFormSizeCtl.dispose();
    _newFormColorsCtl.dispose();
    super.dispose();
  }

  void _updateStockExtra() async {
    final customer = _customerController.text.trim();
    final typeTitle = _product.type.trim();
    // Сбрасываем, если нет данных
    if (customer.isEmpty || typeTitle.isEmpty) {
      setState(() {
        _stockExtra = null;
        _stockExtraItem = null;
      });
      return;
    }
    try {
      // Ищем категорию по названию (совпадает с «Наименование изделия»)
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
          });
        }
        return;
      }
      // Ищем записи внутри категории, где description == заказчик
      final rows = await _sb
          .from('warehouse_category_items')
          .select('id, description, quantity, table_key')
          .eq('category_id', cat['id'])
          .eq('description', customer);
      double total = 0.0;
      for (final r in (rows as List)) {
        final qv = r['quantity'];
        final q =
            (qv is num) ? qv.toDouble() : double.tryParse('${qv ?? ''}') ?? 0.0;
        total += q;
      }
      if (mounted) {
        setState(() {
          _stockExtra = total > 0 ? total : 0.0;
          // _stockExtraItem не используется для динамических категорий
          _stockExtraItem = null;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _stockExtra = null;
          _stockExtraItem = null;
        });
      }
    }
  }

  /// Обновляет номер новой формы в зависимости от введённого названия.
  Future<void> _updateNewFormNumber() async {
    // Только при создании нового заказа и при выборе «новая форма»
    if (widget.order != null || _isOldForm) return;
    final name = _newFormNameCtl.text.trim();
    if (name.isEmpty) {
      setState(() => _newFormNoCtl.text = '');
      return;
    }
    try {
      final wp = context.read<WarehouseProvider>();
      final next = await wp.getNextFormNumber(series: name);
      setState(() => _newFormNoCtl.text = next.toString());
    } catch (_) {
      // ignore errors
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
        r'Краска:\s*(.+?)\s+([0-9]+(?:[.,][0-9]+)?)\s*кг(?:\s*\(([^)]+)\))?',
        multiLine: false);
    final matches = reg.allMatches(params).toList();
    if (matches.isEmpty) {
      _paintsRestored = true;
      return;
    }
    final restored = <_PaintEntry>[];
    for (final m in matches) {
      final name = (m.group(1) ?? '').trim();
      final qtyStr = (m.group(2) ?? '').replaceAll(',', '.');
      final memo = (m.group(3) ?? '').trim();
      final qty = double.tryParse(qtyStr);
      if (name.isEmpty || qty == null) continue;
      TmcModel? found;
      for (final t in paintTmcList) {
        if (t.description.trim() == name) {
          found = t;
          break;
        }
      }
      if (found != null) {
        restored.add(_PaintEntry(tmc: found, qty: qty, memo: memo));
      }
    }
    if (restored.isNotEmpty) {
      setState(() {
        _paints
          ..clear()
          ..addAll(restored);
        _paintsRestored = true;
      });
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
      // Сохраняем строку в order_paints даже если количество не указано (инфо не теряется).
      if (row.tmc != null) {
        rows.add({
          'order_id': orderId,
          'name': row.tmc!.description,
          'info': row.memo.isNotEmpty ? row.memo : null,
          'qty_kg': row.qty, // может быть null
        });
      }
      // В product.parameters пишем только позиции с указанным количеством > 0
      if (row.tmc != null && (row.qty ?? 0) > 0) {
        infos.add(
            'Краска: ${row.tmc!.description} ${row.qty!.toStringAsFixed(2)} кг${row.memo.isNotEmpty ? ' (${row.memo})' : ''}');
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
            final name = (it['name'] ?? '').toString();
            final qty = (it['qty_kg'] as num?)?.toDouble() ?? 0.0;
            final memo = (it['info'] ?? '').toString();
            final tmc = warehouse.getPaintByName(name);
            if (tmc != null) {
              restored.add(_PaintEntry(tmc: tmc, qty: qty, memo: memo));
            } else {
              // В редком случае, если номенклатуры уже нет - просто с текстом.
              restored.add(_PaintEntry(qty: qty, memo: memo));
            }
          }
          setState(() {
            _paints
              ..clear()
              ..addAll(restored.isNotEmpty ? restored : _paints);
            _paintsRestored = true;
          });
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

  /// Parses previous pen quantity from product.parameters like: "Ручки: NAME QTY шт"
  double _previousPenQty({required String penName}) {
    try {
      final prev = widget.order?.product.parameters ?? '';
      final re = RegExp(r'Ручки:\s*(.+?)\s+([0-9]+(?:[\.,][0-9]+)?)\s*шт',
          caseSensitive: false);
      final m = re.firstMatch(prev);
      if (m == null) return 0.0;
      final name = (m.group(1) ?? '').trim();
      final qty = (m.group(2) ?? '').replaceAll(',', '.');
      if (name.toLowerCase() != penName.trim().toLowerCase()) return 0.0;
      return double.tryParse(qty) ?? 0.0;
    } catch (_) {
      return 0.0;
    }
  }

  /// Build a map of previous paints {name -> qty_kg}
  Future<Map<String, double>> _loadPreviousPaints(String orderId) async {
    try {
      final repo = OrdersRepository();
      final rows = await repo.getPaints(orderId);
      final Map<String, double> prev = {};
      for (final r in rows) {
        final name = (r['name'] ?? '').toString().trim();
        final qv = r['qty_kg'];
        final q =
            (qv is num) ? qv.toDouble() : double.tryParse('${qv ?? ''}') ?? 0.0;
        if (name.isNotEmpty) prev[name.toLowerCase()] = q;
      }
      return prev;
    } catch (_) {
      return {};
    }
  }

  /// Update product.parameters with single line for pens so we can diff next time.
  void _upsertPensInParameters(String penName, double qty) {
    final re =
        RegExp(r'(?:^|;\s*)Ручки:\s*.+?(?=(?:;|$))', caseSensitive: false);
    var p = _product.parameters;
    p = p.replaceAll(re, '').trim();
    if (p.isNotEmpty && !p.trim().endsWith(';')) p = p + '; ';
    if (penName.trim().isNotEmpty && qty > 0) {
      p = p + 'Ручки: ' + penName.trim() + ' ' + qty.toString() + ' шт';
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
    final provider = Provider.of<OrdersProvider>(context, listen: false);
    final warehouse = Provider.of<WarehouseProvider>(context, listen: false);
    late OrderModel createdOrUpdatedOrder;
    if (widget.order == null) {
      // создаём новый заказ
      final _created = await provider.createOrder(
        manager: _selectedManager?.trim() ?? '',
        customer: _customerController.text.trim(),
        orderDate: _orderDate!,
        dueDate: _dueDate,
        product: _product,
        additionalParams: _selectedParams,
        handle: _selectedHandle,
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
        manager: _selectedManager?.trim() ?? '',
        customer: _customerController.text.trim(),
        orderDate: _orderDate!,
        dueDate: _dueDate,
        product: _product,
        additionalParams: _selectedParams,
        handle: _selectedHandle,
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
        final List<Map<String, dynamic>> stageMaps = [];
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

        // === Custom stage logic (Flexo insert; Bobbin remove when format==width) ===
        String? __flexoId;
        String? __flexoTitle;
        String? __bobbinId;
        bool __shouldCompleteBobbin = false;
        String? __bobbinTitle;
        try {
          // Flexo by multiple patterns
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
            __flexoId = (flexo['id'] as String?);
            __flexoTitle =
                (flexo['title'] as String?) ?? (flexo['name'] as String?);
            if (__flexoTitle == null || __flexoTitle.trim().isEmpty)
              __flexoTitle = 'Флексопечать';
            if (__flexoTitle == null ||
                RegExp(r'^[a-z0-9_\-]+$').hasMatch(__flexoTitle)) {
              __flexoTitle = 'Флексопечать';
            }
          }
          // Bobbin by multiple patterns
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
          if (bob != null) {
            __bobbinId = (bob['id'] as String?);
            __bobbinTitle = (bob['title'] as String?);
          }
        } catch (_) {}

        // paints present?
        bool __paintsFilled = (_paints.isNotEmpty) ||
            ((_product.parameters ?? '').toLowerCase().contains('краска'));

        // If paints exist and template has no Flexo - insert Flexo at 1st position,
        // or 2nd if Bobbin exists in the queue

        if (__paintsFilled) {
          // Determine if Flexo already present by id or by name
          final hasFlexo = stageMaps.any((m) {
            final sid = (m['stageId'] as String?) ??
                (m['stageid'] as String?) ??
                (m['stage_id'] as String?) ??
                (m['workplaceId'] as String?) ??
                (m['workplace_id'] as String?) ??
                (m['id'] as String?);
            final title =
                ((m['stageName'] ?? m['title']) as String?)?.toLowerCase() ??
                    '';
            final byId = (__flexoId != null && sid == __flexoId) ||
                (sid != null &&
                    (sid == 'w_flexoprint' || sid.startsWith('w_flexo')));
            final byName =
                title.contains('флексопечать') || title.contains('flexo');
            return byId || byName;
          });

          if (!hasFlexo && __flexoId != null && __flexoId!.isNotEmpty) {
            int insertIndex = 0;
            final bobIndex = stageMaps.indexWhere((m) {
              final sid = (m['stageId'] as String?) ??
                  (m['stageid'] as String?) ??
                  (m['stage_id'] as String?) ??
                  (m['workplaceId'] as String?) ??
                  (m['workplace_id'] as String?) ??
                  (m['id'] as String?);
              final title =
                  ((m['stageName'] ?? m['title']) as String?)?.toLowerCase() ??
                      '';
              final byId = (__bobbinId != null && sid == __bobbinId);
              final byName = title.contains('бобинорезка') ||
                  title.contains('бабинорезка') ||
                  title.contains('bobbin');
              return byId || byName;
            });
            if (bobIndex >= 0) insertIndex = bobIndex + 1;

            stageMaps.insert(insertIndex, {
              'stageId': __flexoId,
              'workplaceId': __flexoId,
              'workplaceId': __flexoId,
              'stageName': (__flexoTitle ?? 'Флексопечать'),
              'workplaceName': (__flexoTitle ?? 'Флексопечать'),
              'order': 0
            });
          }

          // If material format equals width - remove Bobbin (only for this order)
          if (__bobbinId != null || true) {
            double? fmtW;
            if (_matSelectedFormat != null &&
                _matSelectedFormat!.trim().isNotEmpty) {
              final _m =
                  RegExp(r'(\d+(?:[\.,]\d+)?)').firstMatch(_matSelectedFormat!);
              if (_m != null) {
                fmtW = double.tryParse(_m.group(1)!.replaceAll(',', '.'));
              }
            }
            final double w =
                ((_product.widthB ?? _product.width) ?? 0).toDouble();
            if (fmtW != null && w > 0 && (fmtW - w).abs() <= 0.001) {
              // remove Bobbin by id or title
              final idxBob = stageMaps.indexWhere((m) {
                final sid = (m['stageId'] as String?) ??
                    (m['stageid'] as String?) ??
                    (m['stage_id'] as String?) ??
                    (m['workplaceId'] as String?) ??
                    (m['workplace_id'] as String?) ??
                    (m['id'] as String?);
                final title = ((m['stageName'] ?? m['title']) as String?)
                        ?.toLowerCase() ??
                    '';
                final byId = (__bobbinId != null && sid == __bobbinId);
                final byName = title.contains('бобинорезка') ||
                    title.contains('бабинорезка') ||
                    title.contains('bobbin');
                return byId || byName;
              });
              if (idxBob >= 0) {
                __shouldCompleteBobbin = true;
                stageMaps.removeAt(idxBob);
              }
            }
          }
          if (__bobbinId != null) {
            double? fmtW;
            if (_matSelectedFormat != null &&
                _matSelectedFormat!.trim().isNotEmpty) {
              final _m =
                  RegExp(r'(\d+(?:[\.,]\d+)?)').firstMatch(_matSelectedFormat!);
              if (_m != null) {
                fmtW = double.tryParse(_m.group(1)!.replaceAll(',', '.'));
              }
            }
            final double w =
                ((_product.widthB ?? _product.width) ?? 0).toDouble();
            if (fmtW != null && w > 0 && (fmtW - w).abs() <= 0.001) {
              // remember for marking "done" if necessary, then remove
              final idxBob = stageMaps.indexWhere((m) {
                final sid = (m['stageId'] as String?) ??
                    (m['stageid'] as String?) ??
                    (m['stage_id'] as String?) ??
                    (m['workplaceId'] as String?) ??
                    (m['workplace_id'] as String?) ??
                    (m['id'] as String?);
                return sid == __bobbinId;
              });
              if (idxBob >= 0) {
                __shouldCompleteBobbin = true;
                stageMaps.removeAt(idxBob);
              }
            }
          }
          // === /Custom stage logic ===
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
    if (isCreating) {
      try {
        final wp = WarehouseProvider();
        int? selectedFormNumber;
        String series;
        String? formCodeToSave;

        if (_isOldForm) {
          // При выборе старой формы копируем данные из выбранной строки
          series = (_formSeries is String && _formSeries.isNotEmpty)
              ? _formSeries
              : 'F';
          if (_selectedOldFormRow != null) {
            selectedFormNumber =
                ((_selectedOldFormRow!['number'] ?? 0) as num).toInt();
            final s = (_selectedOldFormRow!['series'] ?? '').toString();
            if (s.isNotEmpty) series = s;
            final c = (_selectedOldFormRow!['code'] ?? '').toString();
            if (c.isNotEmpty) formCodeToSave = c;
          } else if (_selectedOldForm != null &&
              _selectedOldForm!.trim().isNotEmpty) {
            final code = _selectedOldForm!.trim();
            final mDigits = RegExp(r'\d+').firstMatch(code);
            final String digits = mDigits != null ? mDigits.group(0)! : code;
            selectedFormNumber = int.tryParse(digits);
            final mSeries = RegExp(r'^[A-Za-zА-Яа-я]+').firstMatch(code);
            if (mSeries != null) series = mSeries.group(0)!;
            formCodeToSave = code;
          }
        } else {
          // Создание новой формы: используем введённые данные
          final name = _newFormNameCtl.text.trim();
          final size = _newFormSizeCtl.text.trim();
          final colors = _newFormColorsCtl.text.trim();
          series = name.isNotEmpty ? name : 'F';
          final created = await wp.createFormAndReturn(
            series: series,
            title: size.isNotEmpty ? size : null,
            description: colors.isNotEmpty ? colors : null,
            imageBytes: _newFormImageBytes,
          );
          selectedFormNumber = ((created['number'] ?? 0) as num).toInt();
          final s = (created['series'] ?? '').toString();
          if (s.isNotEmpty) series = s;
          final c = (created['code'] ?? '').toString();
          if (c.isNotEmpty) formCodeToSave = c;
          try {
            await _reloadForms();
          } catch (_) {}
        }

        if (selectedFormNumber != null) {
          await _sb.from('orders').update({
            'is_old_form': _isOldForm,
            'new_form_no': selectedFormNumber,
            'form_series': series,
            'form_code': formCodeToSave,
          }).eq('id', createdOrUpdatedOrder.id);
          try {
            final upd = await _sb
                .from('orders')
                .update({
                  'is_old_form': _isOldForm,
                  'new_form_no': selectedFormNumber,
                  'form_series': series,
                  'form_code': formCodeToSave,
                })
                .eq('id', createdOrUpdatedOrder.id)
                .select()
                .maybeSingle();
            if (upd == null) throw 'empty response';
          } catch (e) {
            if (mounted) {
              if (mounted)
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                      content: Text(
                          'Не удалось сохранить номер формы: ' + e.toString())),
                );
            }
          }

          if (mounted) {
            setState(() {
              _orderFormDisplay = (formCodeToSave != null &&
                      formCodeToSave.isNotEmpty)
                  ? formCodeToSave
                  : (series + selectedFormNumber!.toString().padLeft(4, '0'));
            });
          }
        }
      } catch (_) {}
    }
    // === Конец обработки формы ===

    // Списание ручек (канцтовары/ручки), если выбраны и указано количество
    if (_selectedHandle != '-' && (_handleQty ?? 0) > 0) {
      try {
        final warehouse =
            Provider.of<WarehouseProvider>(context, listen: false);
        // Ищем позицию ручек по описанию среди типа 'pens'
        final items = warehouse
            .getTmcByType('pens')
            .where((t) => t.description == _selectedHandle)
            .toList(growable: false);
        if (items.isNotEmpty) {
          final item = items.first;
          final double newQty = (_handleQty ?? 0);
          // Определяем, сколько было ранее (если редактируем)
          double prevQty = 0;
          try {
            prevQty = _previousPenQty(penName: _selectedHandle);
          } catch (_) {}
          final double diff = (newQty - prevQty);
          if (diff > 0) {
            // Списываем ТОЛЬКО разницу
            await warehouse.writeOff(
              itemId: item.id,
              qty: diff,
              currentQty: item.quantity,
              reason: _customerController.text.trim(),
              typeHint: 'pens',
            );
          } else if (diff < 0) {
            // Если уменьшили количество по сравнению с прошлой версией - вернём на склад разницу
            await warehouse.registerReturn(
              id: item.id,
              type: 'pens',
              qty: -diff,
              note: 'Коррекция заказа: ' + _customerController.text.trim(),
            );
          }
          // Запишем выбранные ручки в parameters, чтобы при следующем сохранении посчитать дельту
          _upsertPensInParameters(_selectedHandle, newQty);
        }
      } catch (e) {
        if (mounted)
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Ошибка списания ручек: $e')),
          );
      }
    }
// Списание материалов/готовой продукции (бумага по длине L)
    if (_selectedMaterialTmc != null && (_product.length ?? 0) > 0) {
      // Перепроверим остаток по актуальным данным провайдера склада
      final current = Provider.of<WarehouseProvider>(context, listen: false)
          .allTmc
          .where((t) => t.id == _selectedMaterialTmc!.id)
          .toList();
      final availableQty = current.isNotEmpty
          ? (current.first.quantity)
          : _selectedMaterialTmc!.quantity;
      final need = (_product.length ?? 0).toDouble();
      // списываем дельту при редактировании
      final prevLen = (widget.order?.product.length ?? 0).toDouble();
      final delta = need - prevLen;
      final toWriteOff =
          (widget.order == null) ? need : (delta > 0 ? delta : 0.0);
      if (need > availableQty) {
        if (mounted)
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
                content: Text(
                    'Недостаточно материала на складе - обновите остатки или уменьшите длину L')),
          );
        return;
      }

      await warehouse.registerShipment(
        id: _selectedMaterialTmc!.id,
        type: 'paper',
        qty: toWriteOff,
        reason: _customerController.text.trim(),
      );
    }

    // Повторная выборка позиций из динамической категории перед списанием - чтобы не зависеть от состояния UI.
    if (_writeOffStockExtra) {
      await AppAuth.ensureSignedIn();

      try {
        final String customer = _customerController.text.trim();
        final String typeTitle = _product.type.trim();
        if (customer.isNotEmpty && typeTitle.isNotEmpty) {
          final cat = await _sb
              .from('warehouse_categories')
              .select('id, title, code')
              .or('title.eq.' + typeTitle + ',code.eq.' + typeTitle)
              .maybeSingle();
          if (cat != null) {
            final rows = await _sb
                .from('warehouse_category_items')
                .select('id, description, quantity, table_key')
                .eq('category_id', cat['id'])
                .eq('description', customer);
            final toWriteOffRows = <Map<String, dynamic>>[];
            for (final r in (rows as List)) {
              final qv = r['quantity'];
              final q = (qv is num)
                  ? qv.toDouble()
                  : double.tryParse('${qv ?? ''}') ?? 0.0;
              if (q > 0) {
                toWriteOffRows.add({'id': r['id'].toString(), 'quantity': q});
              }
            }
            // Выполним списание, если нашли что списывать
            for (final it in toWriteOffRows) {
              final String itemId = it['id'].toString();
              final double q = (it['quantity'] as num).toDouble();
              // Лог списаний
              await _sb.from('warehouse_category_writeoffs').insert({
                'item_id': itemId,
                'qty': q,
                'reason': _customerController.text.trim(),
                'by_name': AuthHelper.currentUserName ?? '',
              });
              // Обновим остаток
              final row = await _sb
                  .from('warehouse_category_items')
                  .select('quantity')
                  .eq('id', itemId)
                  .maybeSingle();
              final double cur =
                  ((row?['quantity'] ?? 0) as num?)?.toDouble() ?? 0.0;
              final double newQty = (cur - q);
              await _sb.from('warehouse_category_items').update(
                  {'quantity': newQty < 0 ? 0 : newQty}).match({'id': itemId});
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

    // Списание красок (если указано несколько)
    // При редактировании списываем только ДЕЛЬТУ, чтобы не дублировать списания
    if (_paints.isNotEmpty) {
      final prevRows = (widget.order == null)
          ? <Map<String, dynamic>>[]
          : await OrdersRepository().getPaints(createdOrUpdatedOrder.id);
      final Map<String, double> prevByName = {};
      for (final it in prevRows) {
        final name = (it['name'] ?? '').toString();
        final q = (it['qty_kg'] as num?)?.toDouble() ?? 0.0;
        if (name.isNotEmpty) prevByName[name] = q;
      }
      for (final row in _paints) {
        if (row.tmc != null && row.qty != null && row.qty! > 0) {
          final name = row.tmc!.description;
          final double newQ = (row.qty ?? 0);
          final double oldQ = prevByName[name] ?? 0.0;
          final double delta = newQ - oldQ;
          if (delta > 0) {
            await warehouse.registerShipment(
              id: row.tmc!.id,
              type: 'paint',
              qty: delta,
              reason: _customerController.text.trim(),
            );
          }
        }
      }
    }

// Независимо от создания/редактирования - синхронизируем список красок
// c полем product.parameters и таблицей order_paints.
    await _persistPaints(createdOrUpdatedOrder.id);
    if (mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final isEditing = widget.order != null;
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
            // Информация о заказе
            Text('Информация о заказе',
                style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            // Менеджер: выбираем из списка сотрудников с должностью «Менеджер»
            DropdownButtonFormField<String>(
              value: _selectedManager,
              decoration: const InputDecoration(
                labelText: 'Менеджер',
                border: OutlineInputBorder(),
              ),
              items: _managerNames
                  .map((name) => DropdownMenuItem(
                        value: name,
                        child: Text(name),
                      ))
                  .toList(),
              onChanged: (val) => setState(() => _selectedManager = val),
              validator: (value) {
                if (value == null || value.trim().isEmpty) {
                  return 'Выберите менеджера';
                }
                return null;
              },
            ),
            const SizedBox(height: 8),
            // Customer
            TextFormField(
              controller: _customerController,
              decoration: const InputDecoration(
                labelText: 'Заказчик',
                border: OutlineInputBorder(),
              ),
              onChanged: (_) => _updateStockExtra(),
              validator: (value) {
                if (value == null || value.trim().isEmpty) {
                  return 'Введите заказчика';
                }
                return null;
              },
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: GestureDetector(
                    onTap: () => _pickOrderDate(context),
                    child: AbsorbPointer(
                      child: TextFormField(
                        decoration: const InputDecoration(
                          labelText: 'Дата заказа',
                          border: OutlineInputBorder(),
                        ),
                        controller: TextEditingController(
                          text: _orderDate != null
                              ? _formatDate(_orderDate!)
                              : '',
                        ),
                        validator: (value) {
                          if (value == null || value.trim().isEmpty) {
                            return 'Укажите дату заказа';
                          }
                          return null;
                        },
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: GestureDetector(
                    onTap: () => _pickDueDate(context),
                    child: AbsorbPointer(
                      child: TextFormField(
                        decoration: const InputDecoration(
                          labelText: 'Срок выполнения',
                          border: OutlineInputBorder(),
                        ),
                        controller: TextEditingController(
                          text: _dueDate != null ? _formatDate(_dueDate!) : '',
                        ),
                        validator: (value) {
                          if (value == null || value.trim().isEmpty) {
                            return 'Укажите срок';
                          }
                          return null;
                        },
                      ),
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),

// === Форма ===
            Text('Форма', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 4),
            if (widget.order == null) ...[
              SwitchListTile(
                title: const Text('Старая форма'),
                value: _isOldForm,
                onChanged: (val) {
                  setState(() {
                    _isOldForm = val;
                    if (_isOldForm) {
                      // Переключение на старые формы - очищаем поля новой формы
                      _newFormNameCtl.clear();
                      _newFormSizeCtl.clear();
                      _newFormColorsCtl.clear();
                      _newFormNoCtl.clear();
                      _newFormImageBytes = null;
                    } else {
                      // Переключение на новые формы - сбрасываем выбранные старые
                      _selectedOldFormRow = null;
                      _selectedOldForm = null;
                    }
                  });
                },
                contentPadding: EdgeInsets.zero,
              ),
              if (_isOldForm) ...[
                TextField(
                  controller: _formSearchCtl,
                  decoration: const InputDecoration(
                    hintText: 'Поиск формы (название или номер)',
                    prefixIcon: Icon(Icons.search),
                    border: OutlineInputBorder(),
                  ),
                  onChanged: (v) => _reloadForms(search: v),
                ),
                const SizedBox(height: 8),
                DropdownButtonFormField<Map<String, dynamic>>(
                  value: _selectedOldFormRow,
                  isExpanded: true,
                  decoration: const InputDecoration(
                    labelText: 'Формы со склада',
                    border: OutlineInputBorder(),
                  ),
                  items: _formResults.map((f) {
                    final series = (f['series'] ?? '').toString();
                    final n = ((f['number'] ?? 0) as num).toInt();
                    final nameNumber = series.isNotEmpty
                        ? '$series ${n > 0 ? n.toString() : ''}'
                        : (n > 0 ? n.toString() : '?');
                    final size = (f['title'] ?? '').toString();
                    final colors = (f['description'] ?? '').toString();
                    final subtitle = <String>[];
                    if (size.isNotEmpty) subtitle.add(size);
                    if (colors.isNotEmpty) subtitle.add('Цвета: $colors');
                    return DropdownMenuItem<Map<String, dynamic>>(
                      value: f,
                      child: Text(subtitle.isEmpty
                          ? nameNumber
                          : '$nameNumber - ${subtitle.join(' - ')}'),
                    );
                  }).toList(),
                  onChanged: (v) => setState(() => _selectedOldFormRow = v),
                ),
                if (_loadingForms)
                  const Padding(
                    padding: EdgeInsets.only(top: 8),
                    child: LinearProgressIndicator(minHeight: 2),
                  ),
              ] else ...[
                // Ввод данных для новой формы
                TextFormField(
                  controller: _newFormNameCtl,
                  decoration: const InputDecoration(
                    labelText: 'Название формы',
                    border: OutlineInputBorder(),
                  ),
                  validator: (value) {
                    if (value == null || value.trim().isEmpty) {
                      return 'Введите название формы';
                    }
                    return null;
                  },
                ),
                const SizedBox(height: 8),
                TextFormField(
                  controller: _newFormSizeCtl,
                  decoration: const InputDecoration(
                    labelText: 'Размер, Тип продукта',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 8),
                TextFormField(
                  controller: _newFormColorsCtl,
                  decoration: const InputDecoration(
                    labelText: 'Цвета',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 8),
                TextFormField(
                  controller: _newFormNoCtl,
                  decoration: const InputDecoration(
                    labelText: 'Номер новой формы',
                    border: OutlineInputBorder(),
                  ),
                  readOnly: true,
                ),
                // Предпросмотр и выбор фото новой формы
                const SizedBox(height: 8),
                if (_newFormImageBytes != null)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: Image.memory(_newFormImageBytes!, height: 100),
                  ),
                ElevatedButton.icon(
                  onPressed: _pickNewFormImage,
                  icon: const Icon(Icons.photo_library),
                  label: const Text('Выбрать фото (не обязательно)'),
                ),
              ],
            ] else ...[
              // Редактирование: форма уже сохранена - отображаем сведения
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (_orderFormSeries != null && _orderFormSeries!.isNotEmpty)
                    Text('Название формы: ${_orderFormSeries!}'),
                  if (_orderFormNo != null)
                    Text('Номер формы: ${_orderFormNo}'),
                  if (_orderFormSize != null &&
                      _orderFormSize!.trim().isNotEmpty)
                    Text('Размер, Тип продукта: ${_orderFormSize!}'),
                  if (_orderFormColors != null &&
                      _orderFormColors!.trim().isNotEmpty)
                    Text('Цвета: ${_orderFormColors!}'),
                  if (_orderFormImageUrl != null &&
                      _orderFormImageUrl!.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 4),
                      child: Image.network(
                        _orderFormImageUrl!,
                        height: 120,
                      ),
                    ),
                ],
              ),
            ],
            const SizedBox(height: 8),

// Всегда показываем отображаемый номер формы (предпросмотр при создании, сохранённый при редактировании)
            InputDecorator(
              decoration: const InputDecoration(
                labelText: 'Номер формы',
                border: OutlineInputBorder(),
              ),
              child: Text(_formDisplayPreview()),
            ),
            const SizedBox(height: 12),

// Фактическое количество (пока не вычисляется)
            TextFormField(
              initialValue: _actualQuantity,
              decoration: const InputDecoration(
                labelText: 'Фактическое количество',
                border: OutlineInputBorder(),
              ),
              readOnly: true,
            ),
            const SizedBox(height: 12),
            // === Комментарии ===
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
            // contract and payment
            CheckboxListTile(
              value: _contractSigned,
              onChanged: (val) =>
                  setState(() => _contractSigned = val ?? false),
              title: const Text('Договор подписан'),
              contentPadding: EdgeInsets.zero,
            ),
            CheckboxListTile(
              value: _paymentDone,
              onChanged: (val) => setState(() => _paymentDone = val ?? false),
              title: const Text('Оплата произведена'),
              contentPadding: EdgeInsets.zero,
            ),
            const SizedBox(height: 16),
            Text('Продукт в заказе',
                style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            _buildProductCard(_product),
            const SizedBox(height: 16),
            // Дополнительные параметры
            Text('Дополнительные параметры',
                style: Theme.of(context).textTheme.titleMedium),
            Consumer<ProductsProvider>(
              builder: (context, provider, _) {
                final params = provider.parameters;
                return Column(
                  children: params.map((p) {
                    final selected = _selectedParams.contains(p);
                    return CheckboxListTile(
                      value: selected,
                      title: Text(p),
                      onChanged: (val) {
                        setState(() {
                          if (val == true) {
                            _selectedParams.add(p);
                          } else {
                            _selectedParams.remove(p);
                          }
                        });
                      },
                      contentPadding: EdgeInsets.zero,
                    );
                  }).toList(),
                );
              },
            ),
            const SizedBox(height: 12),
            // Ручки
            Consumer<WarehouseProvider>(
              builder: (context, warehouse, _) {
                final uniqueHandles = <String>{};
                final handleItems = warehouse.getTmcByType('Ручки');
                for (final t in handleItems) {
                  final desc = t.description;
                  if (desc.isNotEmpty) uniqueHandles.add(desc);
                }
                // Мержим с тем, что даёт другой регистр
                for (final t in warehouse.getTmcByType('ручки')) {
                  final desc = t.description;
                  if (desc.isNotEmpty) uniqueHandles.add(desc);
                }
                final handles = ['-'] + uniqueHandles.toList();
                return Row(children: [
                  Expanded(
                    child: Row(
                      children: [
                        Expanded(
                          child: DropdownButtonFormField<String>(
                            value: handles.contains(_selectedHandle)
                                ? _selectedHandle
                                : '-',
                            decoration: const InputDecoration(
                              labelText: 'Ручки',
                              border: OutlineInputBorder(),
                            ),
                            items: handles
                                .map((h) =>
                                    DropdownMenuItem(value: h, child: Text(h)))
                                .toList(),
                            onChanged: (val) =>
                                setState(() => _selectedHandle = val ?? '-'),
                          ),
                        ),
                        const SizedBox(width: 12),
                        SizedBox(
                          width: 140,
                          child: TextFormField(
                            decoration: const InputDecoration(
                              labelText: 'Кол-во',
                              border: OutlineInputBorder(),
                            ),
                            keyboardType: TextInputType.number,
                            onChanged: (v) {
                              final normalized = v.replaceAll(',', '.');
                              _handleQty = double.tryParse(normalized);
                            },
                          ),
                        ),
                      ],
                    ),
                  ),
                ]);
              },
            ),
            const SizedBox(height: 12),
            // Картон
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
            const SizedBox(height: 12),
            // Приладка/ВАЛ
            Row(
              children: [
                Expanded(
                  child: TextFormField(
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
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: TextFormField(
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
                ),
              ],
            ),
            const SizedBox(height: 12),
            // Очередь (шаблон этапов)
            Consumer<TemplateProvider>(
              builder: (context, provider, _) {
                final templates = provider.templates;
                return DropdownButtonFormField<String>(
                  value: _stageTemplateId,
                  decoration: const InputDecoration(
                    labelText: 'Выберите очередь',
                    border: OutlineInputBorder(),
                  ),
                  items: templates
                      .map((t) =>
                          DropdownMenuItem(value: t.id, child: Text(t.name)))
                      .toList(),
                  onChanged: (val) => setState(() => _stageTemplateId = val),
                );
              },
            ),
          ],
        ),
      ),
    );
  }

  /// Карточка продукта (тип, размеры, материал, краски, вложения и пр.)
  Widget _buildProductCard(ProductModel product) {
    final paperQty = _currentAvailablePaperQty();
    return Card(
      margin: const EdgeInsets.symmetric(vertical: 8),
      elevation: 1,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text('Продукт',
                style: TextStyle(fontWeight: FontWeight.w600)),
            const SizedBox(height: 4),
            // Тип изделия и тираж
            Row(
              children: [
                Expanded(
                  child: Consumer<ProductsProvider>(
                    builder: (context, provider, _) {
                      final items = _categoryTitles;
                      final value =
                          items.contains(product.type) ? product.type : null;
                      return DropdownButtonFormField<String>(
                        value: items.contains(_product.type)
                            ? _product.type
                            : null,
                        decoration: const InputDecoration(
                          labelText: 'Наименование изделия',
                          border: OutlineInputBorder(),
                        ),
                        items: items
                            .map((t) =>
                                DropdownMenuItem(value: t, child: Text(t)))
                            .toList(),
                        onChanged: (val) {
                          setState(() {
                            _product.type = val ?? '';
                          });
                          _updateStockExtra();
                        },
                      );
                    },
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: TextFormField(
                    initialValue:
                        product.quantity > 0 ? product.quantity.toString() : '',
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
                ),
              ],
            ),
            const SizedBox(height: 8),
            // Размеры
            Row(
              children: [
                Expanded(
                  child: TextFormField(
                    initialValue:
                        product.width > 0 ? product.width.toString() : '',
                    decoration: const InputDecoration(
                      labelText: 'Ширина (мм)',
                      border: OutlineInputBorder(),
                    ),
                    keyboardType: TextInputType.number,
                    onChanged: (val) {
                      // Разрешаем ввод дробей с запятой, заменяем запятую на точку.
                      final normalized = val.replaceAll(',', '.');
                      product.width = double.tryParse(normalized) ?? 0;
                    },
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: TextFormField(
                    initialValue:
                        product.height > 0 ? product.height.toString() : '',
                    decoration: const InputDecoration(
                      labelText: 'Высота (мм)',
                      border: OutlineInputBorder(),
                    ),
                    keyboardType: TextInputType.number,
                    onChanged: (val) {
                      final normalized = val.replaceAll(',', '.');
                      product.height = double.tryParse(normalized) ?? 0;
                    },
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: TextFormField(
                    initialValue:
                        product.depth > 0 ? product.depth.toString() : '',
                    decoration: const InputDecoration(
                      labelText: 'Глубина (мм)',
                      border: OutlineInputBorder(),
                    ),
                    keyboardType: TextInputType.number,
                    onChanged: (val) {
                      final normalized = val.replaceAll(',', '.');
                      product.depth = double.tryParse(normalized) ?? 0;
                    },
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),

            // === Материал (каскадный каскад: Материал → Формат → Грамаж) ===
            Builder(
              builder: (context) {
                final papers = _paperItems();
                // Уникальные названия материалов
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
                    ..sort(
                        (a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
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
                    ..sort(
                        (a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
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
                    // Материал (имена, без дублей)
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
                              // Сбрасываем выбор, пока не будет выбран вариант из списка
                              _matSelectedName = null;
                              _matSelectedFormat = null;
                              _matSelectedGrammage = null;
                              _matFormatCtl.text = '';
                              _matGramCtl.text = '';
                              _matNameError =
                                  (_matNameCtl.text.trim().isEmpty ||
                                          allNames
                                              .map((e) => e.toLowerCase())
                                              .contains(_matNameCtl.text
                                                  .trim()
                                                  .toLowerCase()))
                                      ? null
                                      : 'Выберите материал из списка';
                              _matFormatError = null;
                              _matGramError = null;
                              // если текст точно совпадает с вариантом - считаем выбранным
                              final lowerNames =
                                  allNames.map((e) => e.toLowerCase()).toList();
                              final typed =
                                  _matNameCtl.text.trim().toLowerCase();
                              if (lowerNames.contains(typed)) {
                                _matSelectedName =
                                    allNames[lowerNames.indexOf(typed)];
                              }
                            });
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
                          // Очистим выбранный TMC/Material до полного выбора
                          _selectedMaterialTmc = null;
                          _selectedMaterial = null;
                        });
                      },
                    ),
                    const SizedBox(height: 8),
                    // Формат (только форматы выбранного материала)
                    Autocomplete<String>(
                      optionsBuilder: (text) =>
                          filter(formatOptions, text.text),
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
                              _matFormatError =
                                  (_matFormatCtl.text.trim().isEmpty ||
                                          formatOptions
                                              .map((e) => e.toLowerCase())
                                              .contains(_matFormatCtl.text
                                                  .trim()
                                                  .toLowerCase()))
                                      ? null
                                      : 'Выберите формат из списка';
                              // auto-accept exact match
                              final lowerF = formatOptions
                                  .map((e) => e.toLowerCase())
                                  .toList();
                              final typedF =
                                  _matFormatCtl.text.trim().toLowerCase();
                              if (lowerF.contains(typedF)) {
                                _matSelectedFormat =
                                    formatOptions[lowerF.indexOf(typedF)];
                              }
                            });
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
                            errorText: _matSelectedName != null
                                ? _matFormatError
                                : null,
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
                          _selectedMaterialTmc = null;
                          _selectedMaterial = null;
                        });
                      },
                    ),
                    const SizedBox(height: 8),
                    // Грамаж (только для пары Материал+Формат)
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
                              _matGramError = null; // обновится при выборе
                              final lowerG = gramOptions
                                  .map((e) => e.toLowerCase())
                                  .toList();
                              final typedG =
                                  _matGramCtl.text.trim().toLowerCase();
                              if (lowerG.contains(typedG)) {
                                _matSelectedGrammage =
                                    gramOptions[lowerG.indexOf(typedG)];
                                // Если все три заданы - найдём TMC
                                if (_matSelectedName != null &&
                                    _matSelectedFormat != null &&
                                    _matSelectedGrammage != null) {
                                  final tmc = (() {
                                    for (final t in _paperItems()) {
                                      if (t.description.trim().toLowerCase() ==
                                              _matSelectedName!
                                                  .trim()
                                                  .toLowerCase() &&
                                          (t.format ?? '')
                                                  .trim()
                                                  .toLowerCase() ==
                                              _matSelectedFormat!
                                                  .trim()
                                                  .toLowerCase() &&
                                          (t.grammage ?? '')
                                                  .trim()
                                                  .toLowerCase() ==
                                              _matSelectedGrammage!
                                                  .trim()
                                                  .toLowerCase()) {
                                        return t;
                                      }
                                    }
                                    return null;
                                  })();
                                  if (tmc != null) {
                                    _selectMaterial(tmc);
                                  }
                                }
                              }
                            });
                          }
                        });
                        return TextField(
                          controller: controller,
                          focusNode: focusNode,
                          enabled: _matSelectedName != null &&
                              _matSelectedFormat != null,
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
                          // Когда тройка выбрана, найдём точную позицию на складе
                          final tmc = findExact(_matSelectedName!,
                              _matSelectedFormat!, _matSelectedGrammage!);
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
            const SizedBox(height: 8),
            // Лишнее на складе (готовая продукция)
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: TextFormField(
                    readOnly: true,
                    decoration: const InputDecoration(
                      labelText: 'Лишнее на складе',
                      border: OutlineInputBorder(),
                    ),
                    controller: TextEditingController(
                        text:
                            _stockExtra != null ? _stockExtra.toString() : '-'),
                  ),
                ),
                const SizedBox(width: 12),
                SizedBox(
                  width: 240,
                  child: SwitchListTile(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    title: const Text('Списать лишнее при сохранении'),
                    value: _writeOffStockExtra,
                    onChanged: (v) => setState(() => _writeOffStockExtra = v),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            // Ролл / ширина b / длина L
            Row(
              children: [
                Expanded(
                  child: TextFormField(
                    initialValue: product.widthB?.toString() ?? '',
                    decoration: const InputDecoration(
                      labelText: 'Ширина b',
                      border: OutlineInputBorder(),
                    ),
                    keyboardType: TextInputType.number,
                    onChanged: (val) {
                      final normalized = val.replaceAll(',', '.');
                      product.widthB = double.tryParse(normalized);
                    },
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: TextFormField(
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
                        if (_selectedMaterialTmc != null && d != null) {
                          _lengthExceeded = () {
                            final current = Provider.of<WarehouseProvider>(
                                    context,
                                    listen: false)
                                .allTmc
                                .where((t) => t.id == _selectedMaterialTmc!.id)
                                .toList();
                            final available = current.isNotEmpty
                                ? current.first.quantity
                                : _selectedMaterialTmc!.quantity;
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
            const SizedBox(height: 12),
            // === Краски (мультивыбор) ===
            _buildPaintsSection(),
            const SizedBox(height: 12),
            // PDF вложение
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
            const SizedBox(height: 8),
            // Параметры продукта (свободный текст)
            TextFormField(
              initialValue: product.parameters,
              decoration: const InputDecoration(
                labelText: 'Параметры продукта',
                border: OutlineInputBorder(),
              ),
              minLines: 1,
              maxLines: 3,
              onChanged: (val) => product.parameters = val,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildPaintsSection() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Краски', style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 8),
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
                      if (row.tmc != null &&
                          controller.text != row.tmc!.description) {
                        controller.text = row.tmc!.description;
                      }
                      return TextFormField(
                        controller: controller,
                        focusNode: focusNode,
                        decoration: const InputDecoration(
                          labelText: 'Краска (необязательно)',
                          border: OutlineInputBorder(),
                        ),
                      );
                    },
                    onSelected: (tmc) {
                      setState(() {
                        row.tmc = tmc;
                        if (row.qty != null) {
                          row.exceeded = row.qty! > tmc.quantity;
                        } else {
                          row.exceeded = false;
                        }
                      });
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
                // Кол-во (кг)
                SizedBox(
                  width: 130,
                  child: TextFormField(
                    key: ValueKey('qty_\${i}'),
                    decoration: InputDecoration(
                      labelText: 'Кол-во (кг)',
                      border: const OutlineInputBorder(),
                      errorText: row.exceeded ? 'Недостаточно' : null,
                    ),
                    initialValue:
                        (row.qty == null) ? null : row.qty!.toString(),
                    keyboardType: TextInputType.number,
                    onChanged: (val) {
                      final normalized = val.replaceAll(',', '.');
                      final qty = double.tryParse(normalized);
                      setState(() {
                        row.qty = qty;
                        if (row.tmc != null && qty != null) {
                          row.exceeded = qty > row.tmc!.quantity;
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
                    onPressed: () => setState(() => _paints.removeAt(i)),
                    icon: const Icon(Icons.remove_circle_outline),
                  ),
              ],
            ),
          );
        }),
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(
            onPressed: () => setState(() => _paints.add(_PaintEntry())),
            icon: const Icon(Icons.add),
            label: const Text('Добавить краску'),
          ),
        ),
      ],
    );
  }

// Формируем отображаемый код формы для текущего состояния (создание/редактирование)
  String _formDisplayPreview() {
    if (widget.order == null) {
      if (_isOldForm) {
        if (_selectedOldFormRow != null) {
          final series = (_selectedOldFormRow!['series'] ?? '').toString();
          final n = ((_selectedOldFormRow!['number'] ?? 0) as num).toInt();
          if (series.isNotEmpty && n > 0) {
            return '$series ${n.toString()}';
          }
          if (n > 0) return n.toString();
          final code = (_selectedOldFormRow!['code'] ?? '').toString();
          if (code.isNotEmpty) return code;
          return '-';
        }
        if (_selectedOldForm != null && _selectedOldForm!.trim().isNotEmpty) {
          return _selectedOldForm!.trim();
        }
        return '-';
      } else {
        // Отображаем название и номер новой формы. Номер не дополняем нулями,
        // чтобы сохранить читаемость (например: "Орал Пик 585").
        final name = _newFormNameCtl.text.trim();
        final n = int.tryParse(_newFormNoCtl.text) ?? _defaultFormNumber;
        if (name.isNotEmpty && n > 0) {
          return '$name ${n.toString()}';
        }
        if (n > 0) return n.toString();
        return '-';
      }
    } else {
      return (_orderFormDisplay != null && _orderFormDisplay!.isNotEmpty)
          ? _orderFormDisplay!
          : '-';
    }
  }

  String _formatDate(DateTime date) {
    return '${date.day.toString().padLeft(2, '0')}.${date.month.toString().padLeft(2, '0')}.${date.year}';
  }
}
