import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../warehouse/warehouse_provider.dart';
import '../warehouse/tmc_model.dart';
import '../warehouse/supplier_provider.dart';
import 'package:uuid/uuid.dart';
import 'dart:typed_data';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:image_picker/image_picker.dart';

class AddEntryDialog extends StatefulWidget {
  /// Если задан [initialTable], выбор таблицы пользователем блокируется,
  /// и диалог будет использовать только указанную таблицу.
  final String? initialTable;

  /// Существующая запись для редактирования. Если передана, диалог
  /// работает в режиме редактирования и предварительно заполняет поля
  /// данными из этой записи.
  final TmcModel? existing;

  const AddEntryDialog({super.key, this.initialTable, this.existing});

  @override
  State<AddEntryDialog> createState() => _AddEntryDialogState();
}

class _AddEntryDialogState extends State<AddEntryDialog> {
  String? _selectedTable;
  final _formKey = GlobalKey<FormState>();

  final Map<String, TextEditingController> _controllers = {
    'name': TextEditingController(),
    // Общее количество (используется для канцелярии, универсальных и готовых изделий)
    'quantity': TextEditingController(),
    // Длина в метрах (для рулонов и бобин)
    'length': TextEditingController(),
    // Ширина в метрах (для рулонов и бобин)
    'width': TextEditingController(),
    // Вес в килограммах (для красок)
    'weight': TextEditingController(),
    // Формат бумаги
    'format': TextEditingController(),
    // Грамаж бумаги
    'grammage': TextEditingController(),
    // Дополнительные характеристики (для универсальных изделий)
    'characteristics': TextEditingController(),
    // Идентификатор заказа (для готовых изделий)
    'orderId': TextEditingController(),
    // Причина или комментарий (для списания)
    'comment': TextEditingController(),
    'note': TextEditingController(),
  };

  // Список типов ТМЦ, доступных для создания. Добавлены новые типы согласно ТЗ.
  final List<String> _tables = [
    'Рулон',
    'Бобина',
    'Краска',
    'Универсальное изделие',
    'Готовое изделие',
    'Бумага',
    'Канцелярия',
    'Списание',
  ];

  // Дополнительные состояния для работы с бумагой и канцелярией
  List<String> _paperNames = [];
  String? _selectedPaper;
  bool _isNewPaper = false;
  // Выбор единицы измерения для канцелярских товаров
  String? _selectedUnit;
  final List<String> _units = [
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

  // Список материалов для рулонов/бобин. По хорошему должно загружаться из справочника.
  final List<String> _materials = [
    'Бел',
    'Кор',
    'Материал X',
    'Материал Y',
  ];
  // Список Pantone цветов. Должно загружаться из справочника.
  final List<String> _colors = [
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
  // Список типов готовой продукции, согласно ТЗ
  final List<String> _productTypes = [
    'п-пакет',
    'v-пакет',
    'уголок',
    'листы',
    'тарталетка',
    'мафин',
    'тюльпан',
    'рулонная печать',
  ];

  // Выбранные значения для новых типов ТМЦ
  String? _selectedMaterial;
  String? _selectedSupplierId;
  String? _selectedColor;
  String? _selectedRollId;
  String? _selectedProductType;

  // Список рулонов для выбора при создании бобины
  List<TmcModel> _rollItems = [];

  // Хранит выбранное изображение для типа "Краска".
  XFile? _pickedImage;
  // При редактировании существующей записи сохраняем URL изображения.
  String? _existingImageUrl;
  // Байтовое представление выбранного изображения для корректного отображения на вебе.
  Uint8List? _imageBytes;

  /// Открывает галерею для выбора изображения. Выбранный файл сохраняется
  /// в переменную [_pickedImage], чтобы затем загрузить его в Firebase.
  Future<void> _pickImage() async {
    final picker = ImagePicker();
    final XFile? file = await picker.pickImage(source: ImageSource.gallery);
    if (file != null) {
      // Считываем байты изображения для корректного отображения в веб-приложении
      final bytes = await file.readAsBytes();
      setState(() {
        _pickedImage = file;
        _imageBytes = bytes;
      });
    }
  }

  // Метод загрузки в Firebase Storage удалён, так как изображения сохраняются в виде base64.

  @override
  void dispose() {
    for (var controller in _controllers.values) {
      controller.dispose();
    }
    super.dispose();
  }

  @override
  void initState() {
    super.initState();
    // После первой отрисовки загружаем данные, необходимые для работы формы
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      final warehouseProvider = Provider.of<WarehouseProvider>(context, listen: false);
      final supplierProvider = Provider.of<SupplierProvider>(context, listen: false);
      await Future.wait([
        warehouseProvider.fetchTmc(),
        supplierProvider.fetchSuppliers(),
      ]);
      final papers = warehouseProvider.getTmcByType('Бумага');
      final rolls = warehouseProvider.getTmcByType('Рулон');
      setState(() {
        _paperNames = papers.map((e) => e.description).toSet().toList();
        _rollItems = rolls;
      });
    });
    // Предварительно выбираем таблицу
    if (widget.existing != null) {
      _selectedTable = widget.existing!.type;
      _populateForEdit(widget.existing!);
      // Если запись содержит изображение в base64, подготавливаем байты для превью
      if (widget.existing!.imageBase64 != null) {
        try {
          final bytes = base64Decode(widget.existing!.imageBase64!);
          _imageBytes = bytes;
        } catch (_) {}
      }
      // сохраняем ссылку на url изображения (если использовался url)
      _existingImageUrl = widget.existing!.imageUrl;
    } else if (widget.initialTable != null) {
      _selectedTable = widget.initialTable;
    }
  }

  /// Заполняет поля формы данными существующей записи при редактировании.
  void _populateForEdit(TmcModel item) {
    // В режиме редактирования заполняем основные поля исходя из типа записи.
    switch (item.type) {
      case 'Бумага':
        _controllers['name']!.text = item.description;
        _controllers['length']!.text = item.quantity.toString();
        _controllers['format']!.text = item.format ?? '';
        _controllers['grammage']!.text = item.grammage ?? '';
        _controllers['weight']!.text = item.weight?.toString() ?? '';
        break;
      case 'Рулон':
        _controllers['name']!.text = item.description;
        _controllers['length']!.text = item.quantity.toString();
        // Попробуем извлечь ширину из описания, если формат соответствует "Материал Xм"
        final parts = item.description.split(' ');
        if (parts.length >= 2) {
          final widthPart = parts.last;
          final w = double.tryParse(widthPart.replaceAll(RegExp('[^0-9,\.]'), ''));
          if (w != null) {
            _controllers['width']!.text = w.toString();
          }
        }
        break;
      case 'Бобина':
        _controllers['name']!.text = item.description;
        _controllers['length']!.text = item.quantity.toString();
        break;
      case 'Краска':
        _controllers['name']!.text = item.description;
        _controllers['weight']!.text = item.quantity.toString();
        break;
      case 'Универсальное изделие':
        _controllers['name']!.text = item.description;
        _controllers['quantity']!.text = item.quantity.toString();
        break;
      case 'Готовое изделие':
        _controllers['name']!.text = item.description;
        _controllers['quantity']!.text = item.quantity.toString();
        break;
      case 'Канцелярия':
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
    // Сохраняем поставщика в качестве выбранного, если он есть
    _selectedSupplierId = item.supplier;
    _controllers['note']!.text = item.note ?? '';
  }

  Future<void> _submit() async {
    // Не продолжаем, если не выбрана таблица или форма не прошла валидацию
    if (_selectedTable == null) return;
    if (!_formKey.currentState!.validate()) return;

    // Получаем провайдеры для работы с данными
    final warehouseProvider = Provider.of<WarehouseProvider>(context, listen: false);

    // Если это режим редактирования существующей записи
    if (widget.existing != null) {
      final existing = widget.existing!;
      final id = existing.id;
      final type = existing.type;
      final note = _controllers['note']!.text.trim();
      switch (type) {
        case 'Бумага':
          final newLength = double.tryParse(_controllers['length']!.text.trim()) ?? existing.quantity;
          final newDesc = _controllers['name']!.text.trim().isNotEmpty
              ? _controllers['name']!.text.trim()
              : existing.description;
          await warehouseProvider.updateTmc(
            id: id,
            description: newDesc,
            unit: 'м',
            quantity: newLength,
            note: note.isNotEmpty ? note : existing.note,
            format: _controllers['format']!.text.trim().isNotEmpty ? _controllers['format']!.text.trim() : existing.format,
            grammage: _controllers['grammage']!.text.trim().isNotEmpty ? _controllers['grammage']!.text.trim() : existing.grammage,
            weight: double.tryParse(_controllers['weight']!.text.trim()) ?? existing.weight,
          );
          break;
        case 'Рулон':
          final newLength = double.tryParse(_controllers['length']!.text.trim()) ?? existing.quantity;
          final newDesc = _controllers['name']!.text.trim().isNotEmpty
              ? _controllers['name']!.text.trim()
              : existing.description;
          final newUnit = 'м';
          await warehouseProvider.updateTmc(id: id, description: newDesc, unit: newUnit, quantity: newLength, note: note.isNotEmpty ? note : existing.note);
          break;
        case 'Бобина':
          final newLength = double.tryParse(_controllers['length']!.text.trim()) ?? existing.quantity;
          final newDesc = _controllers['name']!.text.trim().isNotEmpty
              ? _controllers['name']!.text.trim()
              : existing.description;
          await warehouseProvider.updateTmc(id: id, description: newDesc, quantity: newLength, note: note.isNotEmpty ? note : existing.note);
          break;
        case 'Краска':
          final newWeight = double.tryParse(_controllers['weight']!.text.trim()) ?? existing.quantity;
          final newDesc = _controllers['name']!.text.trim().isNotEmpty
              ? _controllers['name']!.text.trim()
              : existing.description;
          // Поддержка изображений: сохраняем новое изображение в base64, если оно выбрано
          String? imageBase64 = existing.imageBase64;
          if (_imageBytes != null) {
            imageBase64 = base64Encode(_imageBytes!);
          }
          await warehouseProvider.updateTmc(
            id: id,
            description: newDesc,
            unit: 'кг',
            quantity: newWeight,
            note: note.isNotEmpty ? note : existing.note,
            imageBase64: imageBase64,
          );
          break;
        case 'Канцелярия':
        case 'Универсальное изделие':
        case 'Готовое изделие':
          final newQty = double.tryParse(_controllers['quantity']!.text.trim()) ?? existing.quantity;
          final newDesc = _controllers['name']!.text.trim().isNotEmpty
              ? _controllers['name']!.text.trim()
              : existing.description;
          final newUnit = existing.unit;
          await warehouseProvider.updateTmc(id: id, description: newDesc, unit: newUnit, quantity: newQty, note: note.isNotEmpty ? note : existing.note);
          break;
        case 'Списание':
          final newLength = double.tryParse(_controllers['length']!.text.trim()) ?? existing.quantity;
          final newDesc = _controllers['name']!.text.trim().isNotEmpty
              ? _controllers['name']!.text.trim()
              : existing.description;
          await warehouseProvider.updateTmc(id: id, description: newDesc, unit: existing.unit, quantity: newLength, note: note.isNotEmpty ? note : existing.note);
          break;
        default:
          final newQty = double.tryParse(_controllers['quantity']!.text.trim()) ?? existing.quantity;
          final newDesc = _controllers['name']!.text.trim().isNotEmpty
              ? _controllers['name']!.text.trim()
              : existing.description;
          await warehouseProvider.updateTmc(id: id, description: newDesc, quantity: newQty, note: note.isNotEmpty ? note : existing.note);
      }
      Navigator.of(context).pop();
      return;
    }

    // Если это создание новой записи
    final table = _selectedTable!;
    final note = _controllers['note']!.text.trim();
    // Обработка разных типов
    if (table == 'Бумага') {
      // Приход бумаги: выбор существующего или создание нового вида
      final lengthStr = _controllers['length']!.text.trim();
      final double length = double.tryParse(lengthStr) ?? 0;
      String description;
      if (_isNewPaper) {
        description = _controllers['name']!.text.trim();
      } else {
        description = _selectedPaper ?? '';
      }
      // Если выбрана существующая бумага, то обновляем количество, иначе создаём запись
      final existingList = warehouseProvider.getTmcByType('Бумага');
      TmcModel? existingItem;
      for (final item in existingList) {
        if (item.description == description) {
          existingItem = item;
          break;
        }
      }
      if (existingItem != null) {
        final newQty = existingItem.quantity + length;
        await warehouseProvider.updateTmcQuantity(id: existingItem.id, newQuantity: newQty);
        await warehouseProvider.updateTmc(
          id: existingItem.id,
          format: _controllers['format']!.text.trim().isEmpty
              ? existingItem.format
              : _controllers['format']!.text.trim(),
          grammage: _controllers['grammage']!.text.trim().isEmpty
              ? existingItem.grammage
              : _controllers['grammage']!.text.trim(),
          weight: double.tryParse(_controllers['weight']!.text.trim()) ?? existingItem.weight,
        );
      } else {
        await warehouseProvider.addTmc(
          type: 'Бумага',
          description: description,
          quantity: length,
          unit: 'м',
          note: note.isEmpty ? null : note,
          format: _controllers['format']!.text.trim().isEmpty
              ? null
              : _controllers['format']!.text.trim(),
          grammage: _controllers['grammage']!.text.trim().isEmpty
              ? null
              : _controllers['grammage']!.text.trim(),
          weight: double.tryParse(_controllers['weight']!.text.trim()),
        );
      }
      Navigator.of(context).pop();
      return;
    } else if (table == 'Канцелярия') {
      final name = _controllers['name']!.text.trim();
      final qtyStr = _controllers['quantity']!.text.trim();
      final double qty = double.tryParse(qtyStr) ?? 0;
      final unit = _selectedUnit ?? 'шт';
      await warehouseProvider.addTmc(
        type: 'Канцелярия',
        description: name,
        quantity: qty,
        unit: unit,
        note: note.isEmpty ? null : note,
      );
      Navigator.of(context).pop();
      return;
    } else if (table == 'Списание') {
      // Списание бумаги: уменьшение количества в таблице Бумага
      final selectedPaper = _selectedPaper ?? _controllers['name']!.text.trim();
      final lengthStr = _controllers['length']!.text.trim();
      final double length = double.tryParse(lengthStr) ?? 0;
      final comment = _controllers['comment']!.text.trim();
      final existingList = warehouseProvider.getTmcByType('Бумага');
      TmcModel? existingItem;
      for (final item in existingList) {
        if (item.description == selectedPaper) {
          existingItem = item;
          break;
        }
      }
      if (existingItem == null) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Такой вид бумаги отсутствует.')),
        );
        return;
      }
      if (existingItem.quantity < length) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Недостаточно бумаги для списания.')),
        );
        return;
      }
      final newQty = existingItem.quantity - length;
      await warehouseProvider.updateTmcQuantity(id: existingItem.id, newQuantity: newQty);
      await warehouseProvider.addTmc(
        supplier: comment.isEmpty ? null : comment,
        type: 'Списание',
        description: selectedPaper,
        quantity: length,
        unit: 'м',
        note: note.isEmpty ? null : note,
      );
      Navigator.of(context).pop();
      return;
    } else if (table == 'Рулон') {
      // Создание рулона
      final material = _selectedMaterial ?? _controllers['name']!.text.trim();
      final widthStr = _controllers['width']!.text.trim();
      final double width = double.tryParse(widthStr) ?? 0;
      final lengthStr = _controllers['length']!.text.trim();
      final double length = double.tryParse(lengthStr) ?? 0;
      final description = width > 0 ? '$material ${width}м' : material;
      await warehouseProvider.addTmc(
        supplier: _selectedSupplierId,
        type: 'Рулон',
        description: description,
        quantity: length,
        unit: 'м',
        note: note.isEmpty ? null : note,
      );
      Navigator.of(context).pop();
      return;
    } else if (table == 'Бобина') {
      // Создание бобины
      final roll = _selectedRollId;
      final material = _selectedMaterial ?? '';
      final widthStr = _controllers['width']!.text.trim();
      final double width = double.tryParse(widthStr) ?? 0;
      final lengthStr = _controllers['length']!.text.trim();
      final double length = double.tryParse(lengthStr) ?? 0;
      String description = '';
      if (roll != null) {
        final rollItem = _rollItems.firstWhere((r) => r.id == roll, orElse: () => TmcModel(
            id: roll,
            date: DateTime.now().toIso8601String(),
            supplier: null,
            type: 'Рулон',
            description: roll,
            quantity: 0,
            unit: 'м',
            note: null,
          ));
        description = '${material.isNotEmpty ? material + ' ' : ''}${width > 0 ? '$widthм ' : ''}(из ${rollItem.description})';
      } else {
        description = '${material.isNotEmpty ? material + ' ' : ''}${width > 0 ? '$widthм' : ''}';
      }
      await warehouseProvider.addTmc(
        type: 'Бобина',
        description: description.trim(),
        quantity: length,
        unit: 'м',
        note: note.isEmpty ? null : note,
      );
      Navigator.of(context).pop();
      return;
    } else if (table == 'Краска') {
      // Создание записи для краски, сохраняем изображение в base64 при наличии
      final name = _controllers['name']!.text.trim();
      final color = _selectedColor ?? '';
      final weightStr = _controllers['weight']!.text.trim();
      final double weight = double.tryParse(weightStr) ?? 0;
      final description = color.isNotEmpty ? '$name $color' : name;
      final id = const Uuid().v4();
      String? imageBase64;
      if (_imageBytes != null) {
        imageBase64 = base64Encode(_imageBytes!);
      }
      await warehouseProvider.addTmc(
        id: id,
        type: 'Краска',
        description: description,
        quantity: weight,
        unit: 'кг',
        note: note.isEmpty ? null : note,
        imageBase64: imageBase64,
      );
      Navigator.of(context).pop();
      return;
    } else if (table == 'Универсальное изделие') {
      final name = _controllers['name']!.text.trim();
      final qtyStr = _controllers['quantity']!.text.trim();
      final double qty = double.tryParse(qtyStr) ?? 0;
      final characteristics = _controllers['characteristics']!.text.trim();
      await warehouseProvider.addTmc(
        supplier: characteristics.isEmpty ? null : characteristics,
        type: 'Универсальное изделие',
        description: name,
        quantity: qty,
        unit: 'шт',
        note: note.isEmpty ? null : note,
      );
      Navigator.of(context).pop();
      return;
    } else if (table == 'Готовое изделие') {
      final productType = _selectedProductType ?? _controllers['name']!.text.trim();
      final qtyStr = _controllers['quantity']!.text.trim();
      final double qty = double.tryParse(qtyStr) ?? 0;
      final orderId = _controllers['orderId']!.text.trim();
      await warehouseProvider.addTmc(
        supplier: orderId.isEmpty ? null : orderId,
        type: 'Готовое изделие',
        description: productType,
        quantity: qty,
        unit: 'шт',
        note: note.isEmpty ? null : note,
      );
      Navigator.of(context).pop();
      return;
    } else {
      // Для всех остальных типов, которые не были явно обработаны
      final name = _controllers['name']!.text.trim();
      final qtyStr = _controllers['quantity']!.text.trim();
      final double qty = double.tryParse(qtyStr) ?? 0;
      await warehouseProvider.addTmc(
        type: table,
        description: name,
        quantity: qty,
        unit: 'шт',
        note: note.isEmpty ? null : note,
      );
      Navigator.of(context).pop();
      return;
    }
  }

  Widget _buildFields() {
    switch (_selectedTable) {
      case 'Бумага':
        return Column(
          children: [
            // Выбор существующей бумаги или добавление нового вида
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 6.0),
              child: DropdownButtonFormField<String>(
                decoration: const InputDecoration(
                  labelText: 'Вид бумаги',
                  border: OutlineInputBorder(),
                ),
                value: _isNewPaper ? 'new' : _selectedPaper,
                items: [
                  ..._paperNames.map((name) => DropdownMenuItem<String>(
                        value: name,
                        child: Text(name),
                      )),
                  const DropdownMenuItem<String>(
                    value: 'new',
                    child: Text('Добавить новый вид'),
                  ),
                ],
                onChanged: (value) {
                  setState(() {
                    if (value == 'new') {
                      _isNewPaper = true;
                      _selectedPaper = null;
                      _controllers['name']!.text = '';
                    } else {
                      _isNewPaper = false;
                      _selectedPaper = value;
                      _controllers['name']!.text = value ?? '';
                    }
                  });
                },
                validator: (val) => val == null ? 'Выберите или добавьте вид' : null,
              ),
            ),
            if (_isNewPaper)
              _buildField('name', 'Новый вид бумаги'),
            _buildField('format', 'Формат'),
            _buildField('grammage', 'Грамаж'),
            _buildField('weight', 'Вес (кг)'),
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 6.0),
              child: TextFormField(
                controller: _controllers['length'],
                decoration: const InputDecoration(
                  labelText: 'Количество метров (приход)',
                  border: OutlineInputBorder(),
                ),
                keyboardType: TextInputType.numberWithOptions(decimal: true),
                validator: (value) =>
                    (value == null || value.isEmpty) ? 'Обязательное поле' : null,
              ),
            ),
            _buildField('note', 'Заметки'),
          ],
        );
      case 'Канцелярия':
        return Column(
          children: [
            _buildField('name', 'Наименование'),
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 6.0),
              child: TextFormField(
                controller: _controllers['quantity'],
                decoration: const InputDecoration(
                  labelText: 'Количество (приход)',
                  border: OutlineInputBorder(),
                ),
                keyboardType: TextInputType.numberWithOptions(decimal: true),
                validator: (value) =>
                    (value == null || value.isEmpty) ? 'Обязательное поле' : null,
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
                    .map((u) => DropdownMenuItem<String>(
                          value: u,
                          child: Text(u),
                        ))
                    .toList(),
                onChanged: (val) => setState(() => _selectedUnit = val),
                validator: (val) => val == null ? 'Выберите единицу' : null,
              ),
            ),
            _buildField('note', 'Заметки'),
          ],
        );
      case 'Списание':
        // Списание: выбираем существующую бумагу из списка, указываем количество и комментарий
        return Column(
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 6.0),
              child: DropdownButtonFormField<String>(
                decoration: const InputDecoration(
                  labelText: 'Название из таблицы Бумага',
                  border: OutlineInputBorder(),
                ),
                value: _selectedPaper,
                items: _paperNames
                    .map((name) => DropdownMenuItem<String>(
                          value: name,
                          child: Text(name),
                        ))
                    .toList(),
                onChanged: (value) {
                  setState(() {
                    _selectedPaper = value;
                    // также обновляем текстовое поле name, чтобы его можно было использовать
                    _controllers['name']!.text = value ?? '';
                  });
                },
                validator: (val) => val == null ? 'Выберите бумагу' : null,
              ),
            ),
            _buildField('length', 'Количество метров (списание)'),
            _buildField('comment', 'Комментарий (причина)'),
            _buildField('note', 'Заметки'),
          ],
        );
      case 'Рулон':
        return Column(
          children: [
            // Выбор материала
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 6.0),
              child: DropdownButtonFormField<String>(
                decoration: const InputDecoration(
                  labelText: 'Материал',
                  border: OutlineInputBorder(),
                ),
                value: _selectedMaterial,
                items: _materials
                    .map((m) => DropdownMenuItem<String>(value: m, child: Text(m)))
                    .toList(),
                onChanged: (val) => setState(() => _selectedMaterial = val),
                validator: (val) => val == null ? 'Выберите материал' : null,
              ),
            ),
            // Выбор поставщика (необязательный)
            Consumer<SupplierProvider>(
              builder: (context, supplierProvider, _) {
                final suppliers = supplierProvider.suppliers;
                return Padding(
                  padding: const EdgeInsets.symmetric(vertical: 6.0),
                  child: DropdownButtonFormField<String>(
                    decoration: const InputDecoration(
                      labelText: 'Поставщик',
                      border: OutlineInputBorder(),
                    ),
                    value: _selectedSupplierId,
                    items: suppliers
                        .map((s) => DropdownMenuItem<String>(
                              value: s.id,
                              child: Text(s.name),
                            ))
                        .toList(),
                    onChanged: (val) => setState(() => _selectedSupplierId = val),
                  ),
                );
              },
            ),
            // Ширина
            _buildField('width', 'Ширина (м)'),
            // Длина
            _buildField('length', 'Длина (м)'),
            _buildField('note', 'Заметки'),
          ],
        );
      case 'Бобина':
        return Column(
          children: [
            // Выбор рулона-источника
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 6.0),
              child: DropdownButtonFormField<String>(
                decoration: const InputDecoration(
                  labelText: 'Рулон',
                  border: OutlineInputBorder(),
                ),
                value: _selectedRollId,
                items: _rollItems
                    .map((r) => DropdownMenuItem<String>(
                          value: r.id,
                          child: Text(r.description),
                        ))
                    .toList(),
                onChanged: (val) => setState(() => _selectedRollId = val),
                validator: (val) => val == null ? 'Выберите рулон' : null,
              ),
            ),
            // Материал
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 6.0),
              child: DropdownButtonFormField<String>(
                decoration: const InputDecoration(
                  labelText: 'Материал',
                  border: OutlineInputBorder(),
                ),
                value: _selectedMaterial,
                items: _materials
                    .map((m) => DropdownMenuItem<String>(value: m, child: Text(m)))
                    .toList(),
                onChanged: (val) => setState(() => _selectedMaterial = val),
              ),
            ),
            // Ширина
            _buildField('width', 'Ширина (м)'),
            // Длина
            _buildField('length', 'Длина (м)'),
            _buildField('note', 'Заметки'),
          ],
        );
      case 'Краска':
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Просмотр выбранного изображения или существующего URL
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
            // Кнопка выбора изображения
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 6.0),
              child: ElevatedButton.icon(
                onPressed: _pickImage,
                icon: const Icon(Icons.photo_library),
                label: Text(_pickedImage != null || _existingImageUrl != null
                    ? 'Изменить фото'
                    : 'Добавить фото'),
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
                    .map((c) => DropdownMenuItem<String>(value: c, child: Text(c)))
                    .toList(),
                onChanged: (val) => setState(() => _selectedColor = val),
                validator: (val) => val == null ? 'Выберите цвет' : null,
              ),
            ),
            _buildField('weight', 'Вес (кг)'),
            _buildField('note', 'Заметки'),
          ],
        );
      case 'Универсальное изделие':
        return Column(
          children: [
            _buildField('name', 'Наименование'),
            _buildField('characteristics', 'Характеристики'),
            _buildField('quantity', 'Количество (шт)'),
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
                    .map((p) => DropdownMenuItem<String>(value: p, child: Text(p)))
                    .toList(),
                onChanged: (val) => setState(() => _selectedProductType = val),
                validator: (val) => val == null ? 'Выберите тип изделия' : null,
              ),
            ),
            _buildField('orderId', 'ID заказа'),
            _buildField('quantity', 'Количество (шт)'),
            _buildField('note', 'Заметки'),
          ],
        );
      default:
        return Column(
          children: [
            _buildField('name', 'Название'),
            _buildField('quantity', 'Количество'),
            _buildField('note', 'Заметки'),
          ],
        );
    }
  }

  Widget _buildField(String key, String label) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6.0),
      child: TextFormField(
        controller: _controllers[key],
        decoration: InputDecoration(
          labelText: label,
          border: const OutlineInputBorder(),
        ),
        validator: (value) {
          if (key == 'note') return null;
          return (value == null || value.isEmpty) ? 'Обязательное поле' : null;
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.existing != null ? 'Редактировать запись' : 'Добавить запись'),
      content: Form(
        key: _formKey,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // Если initialTable не задан, позволяем пользователю выбрать таблицу;
              // иначе отображаем выбранную таблицу и блокируем выбор
              if (widget.initialTable == null) ...[
                DropdownButtonFormField<String>(
                  decoration: const InputDecoration(
                    labelText: 'Выберите таблицу',
                    border: OutlineInputBorder(),
                  ),
                  items: _tables.map((table) {
                    return DropdownMenuItem(
                      value: table,
                      child: Text(table),
                    );
                  }).toList(),
                  value: _selectedTable,
                  onChanged: (value) => setState(() => _selectedTable = value),
                  validator: (val) => val == null ? 'Выберите таблицу' : null,
                ),
                const SizedBox(height: 10),
              ] else ...[
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 6.0),
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: Text(
                      'Таблица: ${widget.initialTable}',
                      style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w500),
                    ),
                  ),
                ),
              ],
              if (_selectedTable != null) _buildFields(),
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
          onPressed: _submit,
          child: const Text('Сохранить'),
        ),
      ],
    );
  }
}
