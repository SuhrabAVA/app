import 'dart:convert';
import 'dart:typed_data';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:provider/provider.dart';
import 'package:uuid/uuid.dart';

import '../warehouse/supplier_provider.dart';
import '../warehouse/tmc_model.dart';
import '../warehouse/warehouse_provider.dart';
import '../../utils/kostanay_time.dart';

class PaperOption {
  final String name;
  final String? format;
  final String? grammage;

  const PaperOption({required this.name, this.format, this.grammage});
  String get key => '${name}|${format ?? ''}|${grammage ?? ''}';
  String get display =>
      '$name • ${format == null || format!.isEmpty ? '-' : format} • ${grammage == null || grammage!.isEmpty ? '-' : grammage}';
}

class AddEntryDialog extends StatefulWidget {
  final String? initialTable;
  final TmcModel? existing;
  const AddEntryDialog({super.key, this.initialTable, this.existing});

  @override
  State<AddEntryDialog> createState() => _AddEntryDialogState();
}

class _AddEntryDialogState extends State<AddEntryDialog> {
  final _formKey = GlobalKey<FormState>();
  String? _selectedTable;
  bool get _isEdit => widget.existing != null;

  bool _isSaving = false;

  final Map<String, TextEditingController> _controllers = {
    'view': TextEditingController(),
    'color': TextEditingController(),
    'pairs': TextEditingController(),
    'low': TextEditingController(),
    'critical': TextEditingController(),
    'note': TextEditingController(),
    'name': TextEditingController(),
    'quantity': TextEditingController(),
    'length': TextEditingController(),
    'width': TextEditingController(),
    'weight': TextEditingController(),
    'diameter': TextEditingController(),
    'format': TextEditingController(),
    'grammage': TextEditingController(),
    'characteristics': TextEditingController(),
    'orderId': TextEditingController(),
    'comment': TextEditingController(),
    'note': TextEditingController(),
    'lowThreshold': TextEditingController(),
    'criticalThreshold': TextEditingController(),
    'color': TextEditingController(),
    'counted': TextEditingController(),
  };

  final List<String> _tables = const [
    'Рулон',
    'Бобина',
    'Краска',
    'Универсальное изделие',
    'Готовое изделие',
    'Бумага',
    'Канцелярия',
    'Списание',
    'Инвентаризация',
    'Форма',
    'Ручки',
  ];

  final List<PaperOption> _paperOptions = <PaperOption>[];
  // Уникальные списки для каскадного выбора бумаги
  List<String> _paperNameChoices = [];
  List<String> _formatChoices = [];
  List<String> _grammageChoices = [];
  String? _selectedName;
  String? _selectedFormat;
  String? _selectedGrammage;

  final Map<String, PaperOption> _paperMap = <String, PaperOption>{};
  String? _selectedPaperKey;
  bool _isNewPaper = false;

  String _paperMethod = 'meters'; // meters | weight | diameter
  String? _paperDiameterColor; // white | brown

  String? _selectedUnit;
  final List<String> _units = const [
    'коробка',
    'шт',
    'лист',
    'рулон',
    'талон',
    'литр',
    'пачка',
    'кг',
    'мешков',
  ];

  final List<String> _materials = const [
    'Бел',
    'Кор',
    'Материал X',
    'Материал Y',
  ];
  String? _selectedMaterial;
  String? _selectedSupplierId;
  String? _selectedColor;
  String? _selectedRollId;
  String? _selectedProductType;

  List<TmcModel> _rollItems = [];

  XFile? _pickedImage;
  String? _existingImageUrl;
  Uint8List? _imageBytes;

  final List<String> _colors = const [
    'Красный',
    'Синий',
    'Зелёный',
    'Жёлтый',
    'Оранжевый',
    'Фиолетовый',
    'Розовый',
    'Коричневый',
    'Чёрный',
    'Белый',
    'Серый',
    'Голубой',
    'Бежевый',
    'Бирюзовый',
    'Лаймовый',
    'Золотой',
    'Серебряный',
    'Малиновый',
    'Индиго',
    'Песочный',
  ];

  final List<String> _productTypes = const [
    'п-пакет',
    'v-пакет',
    'уголок',
    'листы',
    'тарталетка',
    'мафин',
    'тюльпан',
    'рулонная печать',
  ];

  bool get _needSuppliers =>
      _selectedTable == 'Рулон' || _selectedTable == 'Бобина';

  Future<void> _ensureSuppliersLoaded() async {
    if (!_needSuppliers) return;
    final sp = Provider.of<SupplierProvider>(context, listen: false);
    if (sp.suppliers.isEmpty) {
      await sp.fetchSuppliers();
    }
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      final wh = Provider.of<WarehouseProvider>(context, listen: false);
      await wh.fetchTmc();

      if (widget.initialTable == 'Ручки') {
        wh.setStationeryKey('pens');
      }

      final papers = wh.getTmcByType('Бумага');
      final rolls = wh.getTmcByType('Рулон');

      final Set<String> seen = <String>{};
      for (final e in papers) {
        final opt = PaperOption(
          name: e.description,
          format: e.format,
          grammage: e.grammage,
        );
        if (seen.add(opt.key)) {
          _paperOptions.add(opt);
          _paperMap[opt.key] = opt;
        }
      }

      // сформировать уникальные названия
      _paperNameChoices = _paperOptions.map((e) => e.name).toSet().toList()
        ..sort();

      // Список уникальных названий без дублей
      _paperNameChoices = _paperOptions.map((o) => o.name).toSet().toList()
        ..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
      if (!mounted) return;
      setState(() {
        _rollItems = rolls;
        if (_isEdit && _selectedTable == 'Бумага' && widget.existing != null) {
          final existing = widget.existing!;
          _selectedName = existing.description;
          _refreshChoicesForName(existing.description);
          final format = existing.format ?? '';
          final grammage = existing.grammage ?? '';
          if (format.isNotEmpty) {
            _applyFormatSelection(format);
          }
          if (grammage.isNotEmpty) {
            _applyGrammageSelection(grammage);
          }
          final descLower = existing.description.toLowerCase();
          if (descLower.contains('бел')) {
            _paperDiameterColor = 'white';
          } else if (descLower.contains('коричнев')) {
            _paperDiameterColor = 'brown';
          }
        }
      });
    });

    if (_isEdit) {
      _selectedTable = _mapTypeToUi(widget.existing!.type);
      _populateForEdit(widget.existing!);

      if (widget.existing!.imageBase64 != null) {
        try {
          _imageBytes = base64Decode(widget.existing!.imageBase64!);
        } catch (_) {}
      }
      _existingImageUrl = widget.existing!.imageUrl;
    } else if (widget.initialTable != null) {
      _selectedTable = widget.initialTable;
    }
  }

  @override
  void dispose() {
    for (final c in _controllers.values) {
      c.dispose();
    }
    super.dispose();
  }

  void _onTableChanged(String? value) async {
    setState(() => _selectedTable = value);
    await _ensureSuppliersLoaded();
    if (value == 'Ручки') {
      final wh = Provider.of<WarehouseProvider>(context, listen: false);
      wh.setStationeryKey('pens');
    }
  }

  String _mapTypeToUi(String type) {
    final t = type.toLowerCase();
    if (t.contains('paper') || t.contains('бумага')) return 'Бумага';
    if (t.contains('paint') || t.contains('краска')) return 'Краска';
    if (t.contains('stationery') || t.contains('канцеляр')) return 'Канцелярия';
    if (t.contains('рулон')) return 'Рулон';
    if (t.contains('бобина')) return 'Бобина';
    if (t.contains('инвент')) return 'Инвентаризация';
    if (t.contains('спис')) return 'Списание';
    if (t.contains('форма')) return 'Форма';
    if (t.contains('готов')) return 'Готовое изделие';
    if (t.contains('универс')) return 'Универсальное изделие';
    return type;
  }

  void _populateForEdit(TmcModel item) {
    final uiType = _mapTypeToUi(item.type);
    switch (uiType) {
      case 'Бумага':
        _controllers['name']!.text = item.description;
        _controllers['format']!.text = item.format ?? '';
        _controllers['grammage']!.text = item.grammage ?? '';
        _controllers['length']!.text = item.quantity.toString();
        break;
      case 'Рулон':
        _controllers['name']!.text = item.description;
        _controllers['length']!.text = item.quantity.toString();
        final parts = item.description.split(' ');
        if (parts.length >= 2) {
          final widthPart = parts.last;
          final w = double.tryParse(
            widthPart.replaceAll(RegExp(r'[^0-9\.,]'), ''),
          );
          if (w != null) _controllers['width']!.text = w.toString();
        }
        break;
      case 'Бобина':
        _controllers['name']!.text = item.description;
        _controllers['length']!.text = item.quantity.toString();
        break;
      case 'Краска':
        _controllers['name']!.text = item.description;
        final unitLower = item.unit.toLowerCase().trim();
        final qtyGrams = unitLower == 'кг' ? item.quantity * 1000 : item.quantity;
        _controllers['weight']!.text = qtyGrams.toString();
        break;
      case 'Канцелярия':
      case 'Универсальное изделие':
      case 'Готовое изделие':
        _controllers['name']!.text = item.description;
        _controllers['quantity']!.text = item.quantity.toString();
        _selectedUnit = item.unit;
        break;
      case 'Списание':
        _controllers['name']!.text = item.description;
        _controllers['length']!.text = item.quantity.toString();
        break;
      default:
        _controllers['name']!.text = item.description;
        _controllers['quantity']!.text = item.quantity.toString();
    }
    _controllers['note']!.text = item.note ?? '';
    if (item.lowThreshold != null) {
      _controllers['lowThreshold']!.text = item.lowThreshold.toString();
    }
    if (item.criticalThreshold != null) {
      _controllers['criticalThreshold']!.text =
          item.criticalThreshold.toString();
    }
  }

  Future<void> _pickImage() async {
    final picker = ImagePicker();
    final XFile? file = await picker.pickImage(source: ImageSource.gallery);
    if (file != null) {
      final bytes = await file.readAsBytes();
      setState(() {
        _pickedImage = file;
        _imageBytes = bytes;
      });
    }
  }

  Future<void> _submit() async {
    if (_selectedTable == null) return;
    if (!_formKey.currentState!.validate()) return;
    if (_isSaving) return;
    setState(() => _isSaving = true);

    final wh = Provider.of<WarehouseProvider>(context, listen: false);

    double? lowTh;
    double? critTh;
    final s1 = _controllers['lowThreshold']!.text.trim();
    if (s1.isNotEmpty) lowTh = double.tryParse(s1.replaceAll(',', '.'));
    final s2 = _controllers['criticalThreshold']!.text.trim();
    if (s2.isNotEmpty) critTh = double.tryParse(s2.replaceAll(',', '.'));

    try {
      if (_isEdit) {
        final item = widget.existing!;
        final note = _controllers['note']!.text.trim();
        final uiType = _mapTypeToUi(item.type);

        switch (uiType) {
          case 'Бумага':
            await wh.updateTmc(
              id: item.id,
              description: _controllers['name']!.text.trim().isNotEmpty
                  ? _controllers['name']!.text.trim()
                  : item.description,
              unit: 'м',
              quantity: double.tryParse(_controllers['length']!
                      .text
                      .trim()
                      .replaceAll(',', '.')) ??
                  item.quantity,
              note: note.isNotEmpty ? note : item.note,
              format: _controllers['format']!.text.trim().isNotEmpty
                  ? _controllers['format']!.text.trim()
                  : item.format,
              grammage: _controllers['grammage']!.text.trim().isNotEmpty
                  ? _controllers['grammage']!.text.trim()
                  : item.grammage,
              lowThreshold: lowTh,
              criticalThreshold: critTh,
            );
            break;

          case 'Рулон':
            await wh.updateTmc(
              id: item.id,
              description: _controllers['name']!.text.trim().isNotEmpty
                  ? _controllers['name']!.text.trim()
                  : item.description,
              unit: 'м',
              quantity: double.tryParse(_controllers['length']!
                      .text
                      .trim()
                      .replaceAll(',', '.')) ??
                  item.quantity,
              note: note.isNotEmpty ? note : item.note,
              lowThreshold: lowTh,
              criticalThreshold: critTh,
            );
            break;

          case 'Бобина':
            await wh.updateTmc(
              id: item.id,
              description: _controllers['name']!.text.trim().isNotEmpty
                  ? _controllers['name']!.text.trim()
                  : item.description,
              quantity: double.tryParse(_controllers['length']!
                      .text
                      .trim()
                      .replaceAll(',', '.')) ??
                  item.quantity,
              note: note.isNotEmpty ? note : item.note,
              lowThreshold: lowTh,
              criticalThreshold: critTh,
            );
            break;

          case 'Краска':
            String? imageBase64 = item.imageBase64;
            if (_imageBytes != null) imageBase64 = base64Encode(_imageBytes!);
            final currentQtyGrams = item.unit.toLowerCase().trim() == 'кг'
                ? item.quantity * 1000
                : item.quantity;
            final enteredQty = double.tryParse(_controllers['weight']!
                    .text
                    .trim()
                    .replaceAll(',', '.')) ??
                currentQtyGrams;
            await wh.updateTmc(
              id: item.id,
              description: _controllers['name']!.text.trim().isNotEmpty
                  ? _controllers['name']!.text.trim()
                  : item.description,
              unit: 'гр',
              quantity: enteredQty,
              note: note.isNotEmpty ? note : item.note,
              imageBase64: imageBase64,
              lowThreshold: lowTh,
              criticalThreshold: critTh,
            );
            break;

          default:
            await wh.updateTmc(
              id: item.id,
              description: _controllers['name']!.text.trim().isNotEmpty
                  ? _controllers['name']!.text.trim()
                  : item.description,
              quantity: double.tryParse(_controllers['quantity']!
                      .text
                      .trim()
                      .replaceAll(',', '.')) ??
                  item.quantity,
              note: note.isNotEmpty ? note : item.note,
              lowThreshold: lowTh,
              criticalThreshold: critTh,
            );
        }

        if (mounted) Navigator.of(context).pop();
        return;
      }

      // ===== Create =====
      final table = _selectedTable!;
      final note = _controllers['note']!.text.trim();

      if (table == 'Инвентаризация') {
        final selectedKey = _selectedPaperKey ?? '';
        final opt = _paperMap[selectedKey];
        final counted = double.tryParse(
                _controllers['counted']!.text.trim().replaceAll(',', '.')) ??
            0;

        final papers = wh.getTmcByType('Бумага');
        final existing = papers.firstWhere(
          (e) =>
              e.description ==
                  (opt?.name ?? _controllers['name']!.text.trim()) &&
              (e.format ?? '') ==
                  (opt?.format ?? _controllers['format']!.text.trim()) &&
              (e.grammage ?? '') ==
                  (opt?.grammage ?? _controllers['grammage']!.text.trim()),
          orElse: () => TmcModel(
            id: '',
            date: '',
            supplier: null,
            type: 'Бумага',
            description: '',
            quantity: 0,
            unit: 'м',
            note: null,
            imageUrl: null,
            imageBase64: null,
            format: null,
            grammage: null,
            weight: null,
            lowThreshold: null,
            criticalThreshold: null,
          ),
        );
        if (existing.id.isEmpty) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Такой вид бумаги отсутствует.')),
          );
          return;
        }
        await wh.updateTmc(
          id: existing.id,
          quantity: counted,
          note: note.isEmpty ? existing.note : note,
        );
        if (mounted) Navigator.of(context).pop();
        return;
      }

      if (table == 'Бумага') {
        final formatStr = _controllers['format']!.text.trim();
        final grammageStr = _controllers['grammage']!.text.trim();
        final note = _controllers['note']!.text.trim();

        final format = double.tryParse(formatStr.replaceAll(',', '.')) ?? 0.0;
        final grammage =
            double.tryParse(grammageStr.replaceAll(',', '.')) ?? 0.0;
        double length = 0.0;

        double? fromWeight(double wKg) =>
            ((wKg * 1000) / grammage) / (format / 100.0);

        double? fromDiameter(double d, bool isWhite) {
          final r_m = (d / 2.0) / 100.0;
          final area_m2 = r_m * r_m * math.pi;
          final k = (isWhite ? 8.8 : 7.75) * format;
          return ((area_m2 * k) * 1000.0) / grammage / (format / 100.0);
        }

        String selectedName = _controllers['name']!.text.trim();
        String selectedFormat = formatStr;
        String selectedGrammage = grammageStr;
        PaperOption? sel;
        if (!_isNewPaper &&
            (_selectedPaperKey != null && _selectedPaperKey!.isNotEmpty)) {
          sel = _paperMap[_selectedPaperKey!];
          if (sel != null) {
            selectedName = sel.name;
            selectedFormat = sel.format ?? selectedFormat;
            selectedGrammage = sel.grammage ?? selectedGrammage;
          }
        }

        if (_paperMethod == 'meters') {
          length = double.tryParse(
                  _controllers['length']!.text.replaceAll(',', '.')) ??
              0.0;
        } else if (_paperMethod == 'weight') {
          final w = double.tryParse(
                  _controllers['weight']!.text.replaceAll(',', '.')) ??
              0.0;
          length = fromWeight(w) ?? 0.0;
        } else if (_paperMethod == 'diameter') {
          final d = double.tryParse(
                  _controllers['diameter']!.text.replaceAll(',', '.')) ??
              0.0;
          if ((_paperDiameterColor ?? '').isEmpty) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('Выберите тип бумаги')),
            );
            return;
          }
          final isWhite = _paperDiameterColor == 'white';
          length = fromDiameter(d, isWhite) ?? 0.0;
        }

        if (length <= 0 || format <= 0 || grammage <= 0) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
                content: Text('Проверьте формат/грамаж и количество')),
          );
          return;
        }

        // ЕДИНСТВЕННЫЙ вызов — провайдер сам разрулит (arrival_add)
        await wh.addTmc(
          type: 'Бумага',
          description: selectedName,
          quantity: length,
          unit: 'м',
          note: note.isEmpty ? null : note,
          format: selectedFormat.isEmpty ? null : selectedFormat,
          grammage: selectedGrammage.isEmpty ? null : selectedGrammage,
          lowThreshold: lowTh,
          criticalThreshold: critTh,
        );

        if (mounted) Navigator.of(context).pop();
        return;
      }

      if (table == 'Списание') {
        final selectedKey = _selectedPaperKey ?? '';
        final opt = _paperMap[selectedKey];
        final length = double.tryParse(
                _controllers['length']!.text.trim().replaceAll(',', '.')) ??
            0;
        final comment = _controllers['comment']!.text.trim();

        final papers = wh.getTmcByType('Бумага');
        final existing = papers.where((e) {
          return e.description ==
                  (opt?.name ?? _controllers['name']!.text.trim()) &&
              (e.format ?? '') ==
                  (opt?.format ?? _controllers['format']!.text.trim()) &&
              (e.grammage ?? '') ==
                  (opt?.grammage ?? _controllers['grammage']!.text.trim());
        }).toList();

        if (existing.isEmpty) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Такой вид бумаги отсутствует.')),
          );
          return;
        }
        if (existing.first.quantity < length) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Недостаточно бумаги для списания.')),
          );
          return;
        }

        await wh.registerShipment(
          id: existing.first.id,
          type: 'Бумага',
          qty: length,
          reason: comment.isEmpty ? null : comment,
        );
        if (mounted) Navigator.of(context).pop();
        return;
      }

      if (table == 'Канцелярия') {
        await wh.addTmc(
          type: table,
          description: _controllers['name']!.text.trim(),
          quantity: double.tryParse(
                  _controllers['quantity']!.text.trim().replaceAll(',', '.')) ??
              0,
          unit: _selectedUnit ?? 'шт',
          note: note.isEmpty ? null : note,
          lowThreshold: lowTh,
          criticalThreshold: critTh,
        );
        if (mounted) Navigator.of(context).pop();
        return;
      }

      if (table == 'Ручки') {
        final name = _controllers['name']!.text.trim();
        final color = _controllers['color']!.text.trim();
        final desc = [name, color].where((s) => s.isNotEmpty).join(' • ');
        await wh.addTmc(
          type: table,
          description: desc,
          quantity: double.tryParse(
                  _controllers['quantity']!.text.trim().replaceAll(',', '.')) ??
              0,
          unit: 'пар', // фиксированная единица измерения
          note: note.isEmpty ? null : note,
          lowThreshold: lowTh,
          criticalThreshold: critTh,
        );
        if (mounted) Navigator.of(context).pop();
        return;
      }

      if (table == 'Рулон') {
        final material = _selectedMaterial ?? _controllers['name']!.text.trim();
        final width = double.tryParse(
                _controllers['width']!.text.trim().replaceAll(',', '.')) ??
            0;
        final length = double.tryParse(
                _controllers['length']!.text.trim().replaceAll(',', '.')) ??
            0;
        final description = width > 0 ? '$material ${width}м' : material;

        await wh.addTmc(
          supplier: _selectedSupplierId,
          type: 'Рулон',
          description: description,
          quantity: length,
          unit: 'м',
          note: note.isEmpty ? null : note,
          lowThreshold: lowTh,
          criticalThreshold: critTh,
        );
        if (mounted) Navigator.of(context).pop();
        return;
      }

      if (table == 'Бобина') {
        final roll = _selectedRollId;
        final material = _selectedMaterial ?? '';
        final width = double.tryParse(
                _controllers['width']!.text.trim().replaceAll(',', '.')) ??
            0;
        final length = double.tryParse(
                _controllers['length']!.text.trim().replaceAll(',', '.')) ??
            0;
        String description;
        if (roll != null) {
          final rollItem = _rollItems.firstWhere(
            (r) => r.id == roll,
            orElse: () => TmcModel(
              id: roll,
              date: nowInKostanayIsoString(),
              supplier: null,
              type: 'Рулон',
              description: roll,
              quantity: 0,
              unit: 'м',
              note: null,
              imageUrl: null,
              imageBase64: null,
              format: null,
              grammage: null,
              weight: null,
              lowThreshold: null,
              criticalThreshold: null,
            ),
          );
          description =
              '${material.isNotEmpty ? '$material ' : ''}${width > 0 ? '$widthм ' : ''}(из ${rollItem.description})';
        } else {
          description =
              '${material.isNotEmpty ? '$material ' : ''}${width > 0 ? '$widthм' : ''}';
        }
        await wh.addTmc(
          type: 'Бобина',
          description: description.trim(),
          quantity: length,
          unit: 'м',
          note: note.isEmpty ? null : note,
          lowThreshold: lowTh,
          criticalThreshold: critTh,
        );
        if (mounted) Navigator.of(context).pop();
        return;
      }

      if (table == 'Краска') {
        final name = _controllers['name']!.text.trim();
        final color = _selectedColor ?? '';
        final grams = double.tryParse(
                _controllers['weight']!.text.trim().replaceAll(',', '.')) ??
            0;
        final description = color.isNotEmpty ? '$name $color' : name;

        await wh.addTmc(
          id: const Uuid().v4(),
          type: 'Краска',
          description: description,
          quantity: grams,
          unit: 'гр',
          note: note.isEmpty ? null : note,
          imageBytes: _imageBytes,
          lowThreshold: lowTh,
          criticalThreshold: critTh,
        );
        if (mounted) Navigator.of(context).pop();
        return;
      }

      if (table == 'Универсальное изделие' ||
          table == 'Форма' ||
          table == 'Готовое изделие') {
        final name = _controllers['name']!.text.trim();
        final qty = double.tryParse(
                _controllers['quantity']!.text.trim().replaceAll(',', '.')) ??
            0;
        final supplierLike = table == 'Готовое изделие'
            ? _controllers['orderId']!.text.trim()
            : _controllers['characteristics']!.text.trim();

        await wh.addTmc(
          supplier: supplierLike.isEmpty ? null : supplierLike,
          type: 'Рулон',
          description: name.isEmpty ? table : name,
          quantity: qty,
          unit: 'шт',
          note: note.isEmpty ? null : note,
          lowThreshold: lowTh,
          criticalThreshold: critTh,
        );
        if (mounted) Navigator.of(context).pop();
        return;
      }
    } catch (e) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Ошибка при сохранении: $e')));
    } finally {
      if (mounted) setState(() => _isSaving = false);
    }
  }

  Widget _buildThresholdFields() {
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 6.0),
          child: TextFormField(
            controller: _controllers['lowThreshold'],
            decoration: const InputDecoration(
              labelText: 'Низкий остаток (желтый)',
              border: OutlineInputBorder(),
            ),
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 6.0),
          child: TextFormField(
            controller: _controllers['criticalThreshold'],
            decoration: const InputDecoration(
              labelText: 'Очень низкий остаток (красный)',
              border: OutlineInputBorder(),
            ),
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
          ),
        ),
      ],
    );
  }

  void _updateSelectedPaperKey() {
    final name = _controllers['name']?.text.trim() ?? '';
    final format = _controllers['format']?.text.trim() ?? '';
    final grammage = _controllers['grammage']?.text.trim() ?? '';

    final match = _paperOptions.where((o) {
      final optFormat = o.format ?? '';
      final optGrammage = o.grammage ?? '';
      return o.name == name && optFormat == format && optGrammage == grammage;
    }).toList();

    if (match.isNotEmpty) {
      _selectedPaperKey = match.first.key;
      final lower = match.first.name.toLowerCase();
      if (lower.contains('бел')) {
        _paperDiameterColor = 'white';
      } else if (lower.contains('коричнев')) {
        _paperDiameterColor = 'brown';
      }
    } else {
      _selectedPaperKey = null;
    }
  }

  void _updateGrammageChoicesForFormat(String? formatValue) {
    final currentName = _controllers['name']?.text.trim() ?? '';
    final format = (formatValue ?? '').trim();
    if (currentName.isEmpty || format.isEmpty) {
      _grammageChoices = [];
      _selectedGrammage = null;
      return;
    }

    final seenG = <String>{};
    _grammageChoices = _paperOptions
        .where((o) => o.name == currentName && (o.format ?? '') == format)
        .map((o) => o.grammage ?? '')
        .where((s) => s.isNotEmpty && seenG.add(s))
        .toList()
      ..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));

    final currentGrammage = _controllers['grammage']?.text.trim() ?? '';
    if (_grammageChoices.contains(currentGrammage)) {
      _selectedGrammage = currentGrammage;
    } else {
      _selectedGrammage = null;
    }
  }

  void _applyFormatSelection(String value) {
    final trimmed = value.trim();
    _controllers['format']?.text = trimmed;
    _selectedFormat = trimmed;
    _updateGrammageChoicesForFormat(trimmed);
    _updateSelectedPaperKey();
  }

  void _applyGrammageSelection(String value) {
    final trimmed = value.trim();
    _controllers['grammage']?.text = trimmed;
    _selectedGrammage = trimmed;
    _updateSelectedPaperKey();
  }

  void _refreshChoicesForName(String? name) {
    final trimmed = (name ?? '').trim();
    if (trimmed.isEmpty) {
      _formatChoices = [];
      _selectedFormat = null;
      _grammageChoices = [];
      _selectedGrammage = null;
      _selectedPaperKey = null;
      return;
    }

    final seenF = <String>{};
    _formatChoices = _paperOptions
        .where((o) => o.name == trimmed)
        .map((o) => o.format ?? '')
        .where((s) => s.isNotEmpty && seenF.add(s))
        .toList()
      ..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));

    final currentFormat = _controllers['format']?.text.trim() ?? '';
    if (_formatChoices.contains(currentFormat)) {
      _selectedFormat = currentFormat;
    } else {
      _selectedFormat = null;
    }

    _updateGrammageChoicesForFormat(currentFormat);
    _updateSelectedPaperKey();
  }

  Widget _buildField(
    String key,
    String label, {
    TextInputType? keyboardType,
    String? Function(String?)? validator,
    void Function(String)? onChanged,
  }) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6.0),
      child: TextFormField(
        controller: _controllers[key],
        decoration: InputDecoration(
          labelText: label,
          border: const OutlineInputBorder(),
        ),
        keyboardType: keyboardType,
        onChanged: onChanged,
        validator: validator ??
            (value) {
              if (key == 'note') return null;
              return (value == null || value.isEmpty)
                  ? 'Обязательное поле'
                  : null;
            },
      ),
    );
  }

  Widget _buildFields() {
    switch (_selectedTable) {
      case 'Бумага':
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (_isEdit)
              _buildField(
                'name',
                'Вид бумаги',
                onChanged: (value) {
                  setState(() {
                    final trimmed = value.trim();
                    _selectedName = trimmed.isEmpty ? null : trimmed;
                    _refreshChoicesForName(value);
                  });
                },
              )
            else
              DropdownButtonFormField<String>(
                value: _selectedName != null &&
                        _paperNameChoices.contains(_selectedName)
                    ? _selectedName
                    : null,
                items: [
                  ..._paperNameChoices.map(
                    (n) => DropdownMenuItem<String>(value: n, child: Text(n)),
                  ),
                  const DropdownMenuItem<String>(
                    value: '__new__',
                    child: Text('Добавить новый вид'),
                  ),
                ],
                onChanged: (v) {
                  setState(() {
                    if (v == '__new__') {
                      _isNewPaper = true;
                      _selectedName = null;
                      _selectedPaperKey = null;
                      _controllers['name']?.text = '';
                      _controllers['format']?.text = '';
                      _controllers['grammage']?.text = '';
                      _refreshChoicesForName(null);
                    } else {
                      _isNewPaper = false;
                      _selectedName = v;
                      _controllers['name']?.text = v ?? '';
                      _controllers['format']?.text = '';
                      _controllers['grammage']?.text = '';
                      _refreshChoicesForName(v);
                    }
                    _updateSelectedPaperKey();
                  });
                },
                decoration: const InputDecoration(
                  labelText: 'Вид бумаги',
                  border: OutlineInputBorder(),
                ),
                validator: (value) => _isNewPaper
                    ? null
                    : (value == null || value.isEmpty
                        ? 'Обязательное поле'
                        : null),
              ),
            if (_isNewPaper) ...[
              const SizedBox(height: 8),
              _buildField(
                'name',
                'Название нового вида',
                onChanged: (value) {
                  setState(() {
                    final trimmed = value.trim();
                    _selectedName = trimmed.isEmpty ? null : trimmed;
                    _refreshChoicesForName(value);
                  });
                },
              ),
            ],
            const SizedBox(height: 8),
            // ФОРМАТ
            Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _buildField(
                  'format',
                  'Формат',
                  onChanged: (value) {
                    setState(() {
                      final trimmed = value.trim();
                      if (_formatChoices.contains(trimmed)) {
                        _selectedFormat = trimmed;
                      } else {
                        _selectedFormat = null;
                      }
                      _updateGrammageChoicesForFormat(trimmed);
                      _updateSelectedPaperKey();
                    });
                  },
                ),
                if (_formatChoices.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 6.0),
                    child: Wrap(
                      spacing: 6,
                      runSpacing: 6,
                      children: _formatChoices
                          .map(
                            (f) => ChoiceChip(
                              label: Text(f),
                              selected: _selectedFormat == f,
                              onSelected: (_) {
                                setState(() {
                                  _applyFormatSelection(f);
                                });
                              },
                            ),
                          )
                          .toList(),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 8),
            // ГРАМАЖ
            Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _buildField(
                  'grammage',
                  'Грамаж',
                  onChanged: (value) {
                    setState(() {
                      final trimmed = value.trim();
                      if (_grammageChoices.contains(trimmed)) {
                        _selectedGrammage = trimmed;
                      } else {
                        _selectedGrammage = null;
                      }
                      _updateSelectedPaperKey();
                    });
                  },
                ),
                if (_grammageChoices.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 6.0),
                    child: Wrap(
                      spacing: 6,
                      runSpacing: 6,
                      children: _grammageChoices
                          .map(
                            (g) => ChoiceChip(
                              label: Text(g),
                              selected: _selectedGrammage == g,
                              onSelected: (_) {
                                setState(() {
                                  _applyGrammageSelection(g);
                                });
                              },
                            ),
                          )
                          .toList(),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 8),
            DropdownButtonFormField<String>(
              decoration: const InputDecoration(
                labelText: 'Способ ввода',
                border: OutlineInputBorder(),
              ),
              value: _paperMethod,
              items: const [
                DropdownMenuItem(value: 'meters', child: Text('Ввести метры')),
                DropdownMenuItem(value: 'weight', child: Text('По весу (кг)')),
                DropdownMenuItem(
                    value: 'diameter', child: Text('По диаметру (см)')),
              ],
              onChanged: (v) => setState(() => _paperMethod = v ?? 'meters'),
            ),
            const SizedBox(height: 8),
            if (_paperMethod == 'meters')
              _buildField(
                'length',
                'Количество метров (приход)',
                keyboardType:
                    const TextInputType.numberWithOptions(decimal: true),
              ),
            if (_paperMethod == 'weight')
              _buildField(
                'weight',
                'Вес (кг)',
                keyboardType:
                    const TextInputType.numberWithOptions(decimal: true),
              ),
            if (_paperMethod == 'diameter') ...[
              _buildField(
                'diameter',
                'Диаметр (см)',
                keyboardType:
                    const TextInputType.numberWithOptions(decimal: true),
              ),
              const SizedBox(height: 8),
              FormField<String>(
                initialValue: _paperDiameterColor,
                validator: (value) {
                  final current = value ?? _paperDiameterColor;
                  if (_paperMethod == 'diameter' && (current == null || current.isEmpty)) {
                    return 'Выберите тип бумаги';
                  }
                  return null;
                },
                builder: (state) {
                  final options = const <Map<String, String>>[
                    {'key': 'white', 'label': 'Белый крафт'},
                    {'key': 'brown', 'label': 'Крафт коричневый'},
                  ];
                  return InputDecorator(
                    decoration: InputDecoration(
                      labelText: 'Тип бумаги',
                      border: const OutlineInputBorder(),
                      errorText: state.errorText,
                    ),
                    child: Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: options.map((opt) {
                        final key = opt['key']!;
                        final label = opt['label']!;
                        final isSelected = _paperDiameterColor == key;
                        return ChoiceChip(
                          label: Text(label),
                          selected: isSelected,
                          onSelected: (selected) {
                            setState(() {
                              _paperDiameterColor = selected ? key : null;
                            });
                            state.didChange(selected ? key : null);
                          },
                        );
                      }).toList(),
                    ),
                  );
                },
              ),
            ],
            _buildThresholdFields(),
            _buildField('note', 'Заметки'),
          ],
        );

      case 'Канцелярия':
        return Column(
          children: [
            _buildField('name', 'Наименование'),
            _buildField(
              'quantity',
              'Количество',
              keyboardType: const TextInputType.numberWithOptions(
                decimal: true,
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 6.0),
              child: DropdownButtonFormField<String>(
                decoration: const InputDecoration(
                  labelText: 'Единица измерения',
                  border: OutlineInputBorder(),
                ),
                value: _selectedUnit,
                items: _units
                    .map((u) =>
                        DropdownMenuItem<String>(value: u, child: Text(u)))
                    .toList(),
                onChanged: (v) {
                  setState(() => _selectedUnit = v);
                },
              ),
            ),
            _buildThresholdFields(),
            _buildField('note', 'Заметки'),
          ],
        );

      case 'Ручки':
        // Спец-форма: Вид / Цвет / Кол-во пар / пороги / комментарий
        return Column(
          children: [
            _buildField('name', 'Вид'),
            _buildField('color', 'Цвет'),
            _buildField(
              'quantity',
              'Количество пар',
              keyboardType: const TextInputType.numberWithOptions(
                decimal: true,
              ),
            ),
            // Единица измерения фиксирована как 'пар' — селектор не показываем
            _buildThresholdFields(),
            _buildField('note', 'Комментарий'),
          ],
        );

      case 'Списание':
        return Column(
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 6.0),
              child: DropdownButtonFormField<String>(
                decoration: const InputDecoration(
                  labelText: 'Название из таблицы Бумага',
                  border: OutlineInputBorder(),
                ),
                value: _selectedName,
                items: _paperOptions
                    .map(
                      (o) => DropdownMenuItem<String>(
                        value: o.key,
                        child: Text(o.display),
                      ),
                    )
                    .toList(),
                onChanged: (v) {
                  setState(() {
                    _selectedPaperKey = v;
                    final opt = v == null ? null : _paperMap[v];
                    _controllers['name']!.text = opt?.name ?? '';
                    _controllers['format']!.text = opt?.format ?? '';
                    _controllers['grammage']!.text = opt?.grammage ?? '';
                  });
                },
                validator: (val) => val == null ? 'Выберите бумагу' : null,
              ),
            ),
            _buildField(
              'length',
              'Количество метров (списание)',
              keyboardType: const TextInputType.numberWithOptions(
                decimal: true,
              ),
            ),
            _buildField('comment', 'Комментарий (причина)'),
            _buildThresholdFields(),
            _buildField('note', 'Заметки'),
          ],
        );

      case 'Инвентаризация':
        return Column(
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 6.0),
              child: DropdownButtonFormField<String>(
                decoration: const InputDecoration(
                  labelText: 'Название из таблицы Бумага',
                  border: OutlineInputBorder(),
                ),
                value: _selectedName,
                items: _paperOptions
                    .map(
                      (o) => DropdownMenuItem<String>(
                        value: o.key,
                        child: Text(o.display),
                      ),
                    )
                    .toList(),
                onChanged: (v) {
                  setState(() {
                    _selectedPaperKey = v;
                    final opt = v == null ? null : _paperMap[v];
                    _controllers['name']!.text = opt?.name ?? '';
                    _controllers['format']!.text = opt?.format ?? '';
                    _controllers['grammage']!.text = opt?.grammage ?? '';
                  });
                },
                validator: (val) => val == null ? 'Выберите бумагу' : null,
              ),
            ),
            _buildField(
              'counted',
              'Фактическое количество метров',
              keyboardType: const TextInputType.numberWithOptions(
                decimal: true,
              ),
            ),
            _buildField('note', 'Заметки'),
          ],
        );

      case 'Рулон':
        return Column(
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 6.0),
              child: DropdownButtonFormField<String>(
                decoration: const InputDecoration(
                  labelText: 'Материал',
                  border: OutlineInputBorder(),
                ),
                value: _selectedMaterial,
                items: _materials
                    .map(
                      (m) => DropdownMenuItem<String>(value: m, child: Text(m)),
                    )
                    .toList(),
                onChanged: (v) => setState(() => _selectedMaterial = v),
                validator: (val) => val == null ? 'Выберите материал' : null,
              ),
            ),
            Consumer<SupplierProvider>(
              builder: (context, sp, _) {
                return Padding(
                  padding: const EdgeInsets.symmetric(vertical: 6.0),
                  child: DropdownButtonFormField<String>(
                    decoration: const InputDecoration(
                      labelText: 'Поставщик',
                      border: OutlineInputBorder(),
                    ),
                    value: _selectedSupplierId,
                    items: sp.suppliers
                        .map(
                          (s) => DropdownMenuItem<String>(
                            value: s.id,
                            child: Text(s.name),
                          ),
                        )
                        .toList(),
                    onChanged: (v) => setState(() => _selectedSupplierId = v),
                  ),
                );
              },
            ),
            _buildField(
              'width',
              'Ширина (м)',
              keyboardType: const TextInputType.numberWithOptions(
                decimal: true,
              ),
            ),
            _buildField(
              'length',
              'Длина (м)',
              keyboardType: const TextInputType.numberWithOptions(
                decimal: true,
              ),
            ),
            _buildThresholdFields(),
            _buildField('note', 'Заметки'),
          ],
        );

      case 'Бобина':
        return Column(
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 6.0),
              child: DropdownButtonFormField<String>(
                decoration: const InputDecoration(
                  labelText: 'Рулон',
                  border: OutlineInputBorder(),
                ),
                value: _selectedRollId,
                items: _rollItems
                    .map(
                      (r) => DropdownMenuItem<String>(
                        value: r.id,
                        child: Text(r.description),
                      ),
                    )
                    .toList(),
                onChanged: (v) => setState(() => _selectedRollId = v),
                validator: (val) => val == null ? 'Выберите рулон' : null,
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 6.0),
              child: DropdownButtonFormField<String>(
                decoration: const InputDecoration(
                  labelText: 'Материал',
                  border: OutlineInputBorder(),
                ),
                value: _selectedMaterial,
                items: _materials
                    .map(
                      (m) => DropdownMenuItem<String>(value: m, child: Text(m)),
                    )
                    .toList(),
                onChanged: (v) => setState(() => _selectedMaterial = v),
              ),
            ),
            _buildField(
              'width',
              'Ширина (м)',
              keyboardType: const TextInputType.numberWithOptions(
                decimal: true,
              ),
            ),
            _buildField(
              'length',
              'Длина (м)',
              keyboardType: const TextInputType.numberWithOptions(
                decimal: true,
              ),
            ),
            _buildThresholdFields(),
            _buildField('note', 'Заметки'),
          ],
        );

      case 'Краска':
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (_imageBytes != null)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 6.0),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child: Image.memory(
                    _imageBytes!,
                    height: 120,
                    width: 120,
                    fit: BoxFit.cover,
                  ),
                ),
              )
            else if (_existingImageUrl != null)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 6.0),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child: Image.network(
                    _existingImageUrl!,
                    height: 120,
                    width: 120,
                    fit: BoxFit.cover,
                  ),
                ),
              ),
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 6.0),
              child: ElevatedButton.icon(
                onPressed: _pickImage,
                icon: const Icon(Icons.photo_library),
                label: Text(
                  _pickedImage != null || _existingImageUrl != null
                      ? 'Изменить фото'
                      : 'Добавить фото',
                ),
              ),
            ),
            _buildField('name', 'Название'),
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 6.0),
              child: DropdownButtonFormField<String>(
                decoration: const InputDecoration(
                  labelText: 'Цвет',
                  border: OutlineInputBorder(),
                ),
                value: _selectedColor,
                items: _colors
                    .map(
                      (c) => DropdownMenuItem<String>(value: c, child: Text(c)),
                    )
                    .toList(),
                onChanged: (v) => setState(() => _selectedColor = v),
                validator: (val) => val == null ? 'Выберите цвет' : null,
              ),
            ),
            _buildField(
              'weight',
              'Вес (г)',
              keyboardType: const TextInputType.numberWithOptions(
                decimal: true,
              ),
            ),
            _buildThresholdFields(),
            _buildField('note', 'Заметки'),
          ],
        );

      case 'Универсальное изделие':
        return Column(
          children: [
            _buildField('name', 'Наименование'),
            _buildField('characteristics', 'Характеристики'),
            _buildField(
              'quantity',
              'Количество (шт)',
              keyboardType: const TextInputType.numberWithOptions(
                decimal: true,
              ),
            ),
            _buildThresholdFields(),
            _buildField('note', 'Заметки'),
          ],
        );

      case 'Готовое изделие':
        return Column(
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 6.0),
              child: DropdownButtonFormField<String>(
                decoration: const InputDecoration(
                  labelText: 'Тип изделия',
                  border: OutlineInputBorder(),
                ),
                value: _selectedProductType,
                items: _productTypes
                    .map(
                      (p) => DropdownMenuItem<String>(value: p, child: Text(p)),
                    )
                    .toList(),
                onChanged: (v) => setState(() => _selectedProductType = v),
                validator: (val) => val == null ? 'Выберите тип изделия' : null,
              ),
            ),
            _buildField('orderId', 'ID заказа'),
            _buildField(
              'quantity',
              'Количество (шт)',
              keyboardType: const TextInputType.numberWithOptions(
                decimal: true,
              ),
            ),
            _buildThresholdFields(),
            _buildField('note', 'Заметки'),
          ],
        );

      case 'Форма':
        return Column(
          children: [
            _buildField('name', 'Номер формы'),
            _buildField(
              'quantity',
              'Количество',
              keyboardType: const TextInputType.numberWithOptions(
                decimal: true,
              ),
            ),
            _buildThresholdFields(),
            _buildField('note', 'Заметки'),
          ],
        );

      default:
        return Column(
          children: [
            _buildField('name', 'Наименование'),
            _buildField(
              'quantity',
              'Количество',
              keyboardType: const TextInputType.numberWithOptions(
                decimal: true,
              ),
            ),
          ],
        );
    }
  }

  @override
  Widget build(BuildContext context) {
    final wp = context.watch<WarehouseProvider>();
    final bool isPens = (['ручки', 'pens', 'handles']
            .contains(wp.stationeryKey.toLowerCase())) ||
        (((widget.initialTable ?? _selectedTable) ?? '') == 'Ручки');

    final headerTable = _isEdit
        ? _mapTypeToUi(widget.existing!.type)
        : (widget.initialTable ?? _selectedTable ?? '');

    return AlertDialog(
      title: Text(_isEdit ? 'Редактировать запись' : 'Добавить запись'),
      content: Form(
        key: _formKey,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (widget.initialTable == null && !_isEdit) ...[
                DropdownButtonFormField<String>(
                  decoration: const InputDecoration(
                    labelText: 'Выберите таблицу',
                    border: OutlineInputBorder(),
                  ),
                  items: _tables
                      .map(
                        (t) =>
                            DropdownMenuItem<String>(value: t, child: Text(t)),
                      )
                      .toList(),
                  value: _selectedTable,
                  onChanged: _onTableChanged,
                  validator: (val) => val == null ? 'Выберите таблицу' : null,
                ),
                const SizedBox(height: 10),
              ] else
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 6.0),
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: Text(
                      'Таблица: $headerTable',
                      style: const TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ),
                ),
              if (_selectedTable != null || headerTable.isNotEmpty)
                _buildFields(),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Отмена'),
        ),
        ElevatedButton(
          onPressed: _isSaving ? null : _submit,
          child: _isSaving
              ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Text('Сохранить'),
        ),
      ],
    );
  }
}
