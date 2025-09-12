import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:uuid/uuid.dart';
import 'package:file_picker/file_picker.dart';
import 'package:open_filex/open_filex.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../services/storage_service.dart';
import 'orders_provider.dart';
import 'order_model.dart';
import 'product_model.dart';
import 'material_model.dart';
import '../products/products_provider.dart';
import '../production_planning/template_provider.dart';
import '../warehouse/warehouse_provider.dart';
import '../warehouse/tmc_model.dart';
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
  final _formKey = GlobalKey<FormState>();
  final _uuid = const Uuid();

  late TextEditingController _managerController;
  late TextEditingController _customerController;
  late TextEditingController _commentsController;
  DateTime? _orderDate;
  DateTime? _dueDate;
  bool _contractSigned = false;
  bool _paymentDone = false;

  late ProductModel _product;
  List<String> _selectedParams = [];
  String _selectedHandle = '-';
  String _selectedCardboard = 'нет';
  double _makeready = 0;
  double _val = 0;
  String? _stageTemplateId;

  MaterialModel? _selectedMaterial;
  TmcModel? _selectedMaterialTmc;

  TmcModel? _stockExtraItem;
  double? _stockExtra;

  PlatformFile? _pickedPdf;
  bool _lengthExceeded = false;

  // Краски (мультисекция)
  final List<_PaintEntry> _paints = <_PaintEntry>[];

  @override
  void initState() {
    super.initState();
    // order передан при редактировании, initialOrder — при создании на основе шаблона
    final template = widget.order ?? widget.initialOrder;

    _managerController = TextEditingController(
        text: template is OrderModel ? (template as OrderModel).manager : '');
    _customerController = TextEditingController(text: template?.customer ?? '');
    _commentsController = TextEditingController(text: template?.comments ?? '');
    _orderDate = template?.orderDate;
    _dueDate = template?.dueDate;
    _contractSigned = template?.contractSigned ?? false;
    _paymentDone = template?.paymentDone ?? false;
    _selectedParams = List<String>.from(template?.additionalParams ?? const []);
    _selectedHandle = template?.handle ?? '-';
    _selectedCardboard = template?.cardboard ?? 'нет';
    _makeready = template?.makeready ?? 0;
    _val = template?.val ?? 0;
    _stageTemplateId = template?.stageTemplateId;
    _selectedMaterial = template?.material;

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

    // ensure at least one paint row
    if (_paints.isEmpty) _paints.add(_PaintEntry());

    WidgetsBinding.instance.addPostFrameCallback((_) => _updateStockExtra());
  }

  @override
  void dispose() {
    _customerController.removeListener(_updateStockExtra);
    _managerController.dispose();
    _customerController.dispose();
    _commentsController.dispose();
    super.dispose();
  }

  void _updateStockExtra() {
    final warehouse = Provider.of<WarehouseProvider>(context, listen: false);
    final customer = _customerController.text.trim();
    final type = _product.type;
    final items = warehouse.allTmc.where((t) =>
        t.type == 'Готовая продукция' &&
        t.description == type &&
        (t.supplier ?? '') == customer);
    if (items.isNotEmpty) {
      setState(() {
        _stockExtraItem = items.first;
        _stockExtra = items.first.quantity;
      });
    } else {
      setState(() {
        _stockExtraItem = null;
        _stockExtra = null;
      });
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
        // Если дата выполнения меньше даты заказа — корректируем
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

  Future<void> _saveOrder() async {
    if (!_formKey.currentState!.validate()) return;
    if (_orderDate == null || _dueDate == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Укажите даты заказа и срока выполнения')),
      );
      return;
    }
    if (_lengthExceeded) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Недостаточно материала на складе')),
      );
      return;
    }

    final provider = Provider.of<OrdersProvider>(context, listen: false);
    final warehouse = Provider.of<WarehouseProvider>(context, listen: false);

    OrderModel? createdOrUpdatedOrder;

    if (widget.order == null) {
      // создаём новый заказ
      createdOrUpdatedOrder = await provider.createOrder(
        manager: _managerController.text.trim(),
        customer: _customerController.text.trim(),
        orderDate: _orderDate!,
        dueDate: _dueDate!,
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
    } else {
      // обновляем существующий заказ, сохраняя assignmentId/assignmentCreated
      final updated = OrderModel(
        id: widget.order!.id,
        manager: _managerController.text.trim(),
        customer: _customerController.text.trim(),
        orderDate: _orderDate!,
        dueDate: _dueDate!,
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

    // если заказ не сохранился — не продолжаем
    if (createdOrUpdatedOrder == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Не удалось сохранить заказ')),
      );
      return;
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

    // если выбран шаблон и задания ещё не создавались — создаём их (ОДИН РАЗ)
    if (_stageTemplateId != null &&
        _stageTemplateId!.isNotEmpty &&
        !createdOrUpdatedOrder.assignmentCreated) {
      final supabase = Supabase.instance.client;

      // убеждаемся, что заказ уже есть в БД (для FK)
      final exists = await supabase
          .from('orders')
          .select('id')
          .eq('id', createdOrUpdatedOrder.id)
          .maybeSingle();
      if (exists == null) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Заказ ещё не появился в БД')),
        );
        return;
      }

      // тянем этапы из шаблона
      final tpl = await supabase
          .from('plan_templates')
          .select('stages')
          .eq('id', _stageTemplateId!)
          .maybeSingle();

      if (tpl != null) {
        final stagesData = tpl['stages'];
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

        // сохраняем план этапов для отображения в модуле производства
        await supabase.from('production_plans').upsert({
          'order_id': createdOrUpdatedOrder.id,
          'stages': stageMaps,
        }, onConflict: 'order_id');

        // удалим прежние задачи этого заказа, чтобы не было дублей
        await supabase
            .from('tasks')
            .delete()
            .eq('orderid', createdOrUpdatedOrder.id);

        // создаём задачи под каждый этап
        for (final sm in stageMaps) {
          final stageId =
              (sm['stageId'] as String?) ?? (sm['stageid'] as String?);
          if (stageId == null || stageId.isEmpty) continue;
          final taskId = _uuid.v4();
          await supabase.from('tasks').insert({
            'id': taskId,
            'orderid': createdOrUpdatedOrder.id, // имена колонок БД
            'stageid': stageId, // имена колонок БД
            'status': 'waiting',
            'createdat':
                DateTime.now().millisecondsSinceEpoch, // имена колонок БД
          });
        }

        // переводим заказ в работу и проставляем assignment
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
          status: OrderStatus.inWork.name, // "inWork"
          assignmentId: provider.generateAssignmentId(),
          assignmentCreated: true,
        );
        await provider.updateOrder(withAssignment);
        await provider.refresh();
        await context.read<TaskProvider>().refresh();
        createdOrUpdatedOrder = withAssignment;
      }
    }

    // Списание материалов/готовой продукции
    if (_selectedMaterialTmc != null && (_product.length ?? 0) > 0) {
      final newQty = _selectedMaterialTmc!.quantity - (_product.length ?? 0);
      await warehouse.updateTmcQuantity(
          id: _selectedMaterialTmc!.id, newQuantity: newQty);
    }
    if (_stockExtraItem != null && _stockExtra != null && _stockExtra! > 0) {
      final used = (_product.quantity.toDouble() < _stockExtra!)
          ? _product.quantity.toDouble()
          : _stockExtra!;
      final newQty = _stockExtraItem!.quantity - used;
      await warehouse.updateTmcQuantity(
          id: _stockExtraItem!.id, newQuantity: newQty);
    }

    // Списание красок (если указано несколько)
    if (_paints.isNotEmpty) {
      final infos = <String>[];
      for (final row in _paints) {
        if (row.tmc != null && row.qty != null && row.qty! > 0) {
          final newQty = row.tmc!.quantity - row.qty!;
          await warehouse.updateTmcQuantity(
              id: row.tmc!.id, newQuantity: newQty);
          final info =
              'Краска: ${row.tmc!.description} ${row.qty!.toStringAsFixed(2)} кг'
              '${row.memo.isNotEmpty ? ' (${row.memo})' : ''}';
          infos.add(info);
        }
      }
      if (infos.isNotEmpty) {
        final joined = infos.join('; ');
        if (_product.parameters.isNotEmpty) {
          _product.parameters = '${_product.parameters}; $joined';
        } else {
          _product.parameters = joined;
        }
      }
    }

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
            ? 'Редактирование заказа ${widget.order!.id}'
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
            // Manager
            TextFormField(
              controller: _managerController,
              decoration: const InputDecoration(
                labelText: 'Менеджер',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 8),
            // Customer
            TextFormField(
              controller: _customerController,
              decoration: const InputDecoration(
                labelText: 'Заказчик',
                border: OutlineInputBorder(),
              ),
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
            Consumer<ProductsProvider>(
              builder: (context, provider, _) {
                final uniqueHandles = <String>{}
                  ..addAll(provider.handles.where((h) => h != '-'));
                final handles = ['-'] + uniqueHandles.toList();
                return DropdownButtonFormField<String>(
                  value:
                      handles.contains(_selectedHandle) ? _selectedHandle : '-',
                  decoration: const InputDecoration(
                    labelText: 'Ручки',
                    border: OutlineInputBorder(),
                  ),
                  items: handles
                      .map((h) => DropdownMenuItem(value: h, child: Text(h)))
                      .toList(),
                  onChanged: (val) =>
                      setState(() => _selectedHandle = val ?? '-'),
                );
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
                DropdownMenuItem(value: 'офсет', child: Text('офсет')),
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
                    onChanged: (v) => _makeready = double.tryParse(v) ?? 0,
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
                    onChanged: (v) => _val = double.tryParse(v) ?? 0,
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
                      final items = <String>{...provider.products}.toList();
                      final value =
                          items.contains(product.type) ? product.type : null;
                      return DropdownButtonFormField<String>(
                        value: value,
                        decoration: const InputDecoration(
                          labelText: 'Наименование изделия',
                          border: OutlineInputBorder(),
                        ),
                        items: items
                            .map((p) =>
                                DropdownMenuItem(value: p, child: Text(p)))
                            .toList(),
                        onChanged: (val) {
                          setState(() => product.type = val ?? product.type);
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
                    onChanged: (val) =>
                        product.width = double.tryParse(val) ?? 0,
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
                    onChanged: (val) =>
                        product.height = double.tryParse(val) ?? 0,
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
                    onChanged: (val) =>
                        product.depth = double.tryParse(val) ?? 0,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),

            // === Материал ===
            Row(
              children: [
                Expanded(
                  child: Autocomplete<TmcModel>(
                    optionsBuilder: (TextEditingValue text) {
                      final provider = Provider.of<WarehouseProvider>(context,
                          listen: false);
                      // подстрой при необходимости строку типа под свои TMC
                      final list = provider.getTmcByType('Материал');
                      final query = text.text.toLowerCase();
                      if (query.isEmpty) return list;
                      return list.where(
                          (t) => t.description.toLowerCase().contains(query));
                    },
                    displayStringForOption: (tmc) => tmc.description,
                    optionsViewBuilder: (context, onSelected, options) {
                      return Align(
                        alignment: Alignment.topLeft,
                        child: Material(
                          elevation: 4,
                          child: SizedBox(
                            height: 240,
                            child: ListView(
                              padding: EdgeInsets.zero,
                              children: options
                                  .map((tmc) => ListTile(
                                        title: Text(tmc.description),
                                        subtitle: Text(
                                            'Кол-во: ${tmc.quantity.toString()}'),
                                        onTap: () => onSelected(tmc),
                                      ))
                                  .toList(),
                            ),
                          ),
                        ),
                      );
                    },
                    fieldViewBuilder:
                        (context, controller, focusNode, onFieldSubmitted) {
                      if (_selectedMaterialTmc != null) {
                        controller.text = _selectedMaterialTmc!.description;
                      }
                      return TextFormField(
                        controller: controller,
                        focusNode: focusNode,
                        decoration: const InputDecoration(
                          labelText: 'Материал',
                          border: OutlineInputBorder(),
                        ),
                      );
                    },
                    onSelected: _selectMaterial,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: TextFormField(
                    readOnly: true,
                    decoration: const InputDecoration(
                      labelText: 'Плотность',
                      border: OutlineInputBorder(),
                    ),
                    controller: TextEditingController(
                        text: _selectedMaterial?.grammage ?? ''),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),

            // Лишнее на складе (готовая продукция)
            TextFormField(
              readOnly: true,
              decoration: const InputDecoration(
                labelText: 'Лишнее на складе',
                border: OutlineInputBorder(),
              ),
              controller: TextEditingController(
                  text: _stockExtra != null ? _stockExtra.toString() : '-'),
            ),
            const SizedBox(height: 8),

            // Ролл / ширина b / длина L
            Row(
              children: [
                Expanded(
                  child: TextFormField(
                    initialValue: product.roll?.toString() ?? '',
                    decoration: const InputDecoration(
                      labelText: 'Ролл',
                      border: OutlineInputBorder(),
                    ),
                    keyboardType: TextInputType.number,
                    onChanged: (val) => product.roll = double.tryParse(val),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: TextFormField(
                    initialValue: product.widthB?.toString() ?? '',
                    decoration: const InputDecoration(
                      labelText: 'Ширина b',
                      border: OutlineInputBorder(),
                    ),
                    keyboardType: TextInputType.number,
                    onChanged: (val) => product.widthB = double.tryParse(val),
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
                      final d = double.tryParse(val);
                      setState(() {
                        product.length = d;
                        if (_selectedMaterialTmc != null && d != null) {
                          _lengthExceeded = d > _selectedMaterialTmc!.quantity;
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
                      if (row.tmc != null) {
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
                    decoration: InputDecoration(
                      labelText: 'Кол-во (кг)',
                      border: const OutlineInputBorder(),
                      errorText: row.exceeded ? 'Недостаточно' : null,
                    ),
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

  String _formatDate(DateTime date) {
    return '${date.day.toString().padLeft(2, '0')}.${date.month.toString().padLeft(2, '0')}.${date.year}';
  }
}
