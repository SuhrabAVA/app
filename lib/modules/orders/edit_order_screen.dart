import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:uuid/uuid.dart';

import 'orders_provider.dart';
import 'order_model.dart';
import 'product_model.dart';

/// Экран редактирования или создания заказа.
/// Если [order] передан, экран открывается для редактирования существующего заказа.
class EditOrderScreen extends StatefulWidget {
  final OrderModel? order;

  const EditOrderScreen({super.key, this.order});

  @override
  State<EditOrderScreen> createState() => _EditOrderScreenState();
}

class _EditOrderScreenState extends State<EditOrderScreen> {
  final _formKey = GlobalKey<FormState>();
  final _uuid = const Uuid();

  late TextEditingController _customerController;
  late TextEditingController _commentsController;
  DateTime? _orderDate;
  DateTime? _dueDate;
  bool _contractSigned = false;
  bool _paymentDone = false;
  late List<ProductModel> _products;

  @override
  void initState() {
    super.initState();
    final order = widget.order;
    _customerController = TextEditingController(text: order?.customer ?? '');
    _commentsController = TextEditingController(text: order?.comments ?? '');
    _orderDate = order?.orderDate;
    _dueDate = order?.dueDate;
    _contractSigned = order?.contractSigned ?? false;
    _paymentDone = order?.paymentDone ?? false;
    _products = order != null
        ? order.products.map((p) => ProductModel(
              id: p.id,
              type: p.type,
              quantity: p.quantity,
              width: p.width,
              height: p.height,
              depth: p.depth,
              parameters: p.parameters,
            )).toList()
        : [];
  }

  @override
  void dispose() {
    _customerController.dispose();
    _commentsController.dispose();
    super.dispose();
  }

  /// Создаёт новый продукт и добавляет его в список для редактирования.
  void _addProduct() {
    setState(() {
      _products.add(ProductModel(
        id: _uuid.v4(),
        type: 'П-пакет',
        quantity: 0,
        width: 0,
        height: 0,
        depth: 0,
        parameters: '',
      ));
    });
  }

  /// Удаляет продукт из списка.
  void _removeProduct(ProductModel p) {
    setState(() {
      _products.remove(p);
    });
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

  void _saveOrder() {
    if (!_formKey.currentState!.validate()) return;
    if (_orderDate == null || _dueDate == null) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('Укажите даты заказа и срока выполнения'),
      ));
      return;
    }
    final provider = Provider.of<OrdersProvider>(context, listen: false);
    if (widget.order == null) {
      // Создание нового заказа
      provider.createOrder(
        customer: _customerController.text.trim(),
        orderDate: _orderDate!,
        dueDate: _dueDate!,
        products: _products,
        contractSigned: _contractSigned,
        paymentDone: _paymentDone,
        comments: _commentsController.text.trim(),
      );
    } else {
      // Обновление
      final updated = OrderModel(
        id: widget.order!.id,
        customer: _customerController.text.trim(),
        orderDate: _orderDate!,
        dueDate: _dueDate!,
        products: _products,
        contractSigned: _contractSigned,
        paymentDone: _paymentDone,
        comments: _commentsController.text.trim(),
        status: widget.order!.status,
      );
      provider.updateOrder(updated);
    }
    Navigator.of(context).pop();
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
          // Кнопка удаления доступна только при редактировании существующего заказа
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
                if (confirmed) {
                  final provider = Provider.of<OrdersProvider>(context, listen: false);
                  provider.deleteOrder(widget.order!.id);
                  Navigator.of(context).pop();
                }
              },
            ),
          TextButton(
            onPressed: _saveOrder,
            child: const Text('Сохранить',
                style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
      body: Form(
        key: _formKey,
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            // Информация о заказе
            Text(
              'Информация о заказе',
              style: Theme.of(context).textTheme.titleMedium,
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
                          text: _orderDate != null ? _formatDate(_orderDate!) : '',
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
              onChanged: (val) => setState(() => _contractSigned = val ?? false),
              title: const Text('Договор подписан'),
            ),
            CheckboxListTile(
              value: _paymentDone,
              onChanged: (val) => setState(() => _paymentDone = val ?? false),
              title: const Text('Оплата произведена'),
            ),
            const SizedBox(height: 16),
            Text(
              'Продукты в заказе',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 8),
            Column(
              children: _products.map((product) {
                final index = _products.indexOf(product) + 1;
                return _buildProductCard(product, index);
              }).toList(),
            ),
            const SizedBox(height: 12),
            OutlinedButton.icon(
              onPressed: _addProduct,
              icon: const Icon(Icons.add),
              label: const Text('Добавить продукт'),
            ),
          ],
        ),
      ),
    );
  }

  /// Строит карточку формы одного продукта. Содержит поля для ввода типа
  /// изделия, тиража, размеров и параметров. Также есть кнопка удаления.
  Widget _buildProductCard(ProductModel product, int index) {
    return Card(
      margin: const EdgeInsets.symmetric(vertical: 8),
      elevation: 1,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  'Продукт $index',
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
                IconButton(
                  onPressed: () => _removeProduct(product),
                  icon: const Icon(Icons.delete_outline),
                ),
              ],
            ),
            const SizedBox(height: 4),
            // Тип изделия и тираж
            Row(
              children: [
                Expanded(
                  child: DropdownButtonFormField<String>(
                    value: product.type,
                    decoration: const InputDecoration(
                      labelText: 'Наименование изделия',
                      border: OutlineInputBorder(),
                    ),
                    items: const [
                      DropdownMenuItem(value: 'П-пакет', child: Text('П‑пакет')),
                      DropdownMenuItem(value: 'V-пакет', child: Text('V‑пакет')),
                      DropdownMenuItem(value: 'Листы', child: Text('Листы')),
                      DropdownMenuItem(value: 'Маффин', child: Text('Маффин')),
                      DropdownMenuItem(value: 'Тюльпан', child: Text('Тюльпан')),
                    ],
                    onChanged: (val) => setState(() => product.type = val ?? product.type),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: TextFormField(
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
                ),
              ],
            ),
            const SizedBox(height: 8),
            // Размеры
            Row(
              children: [
                Expanded(
                  child: TextFormField(
                    initialValue: product.width > 0 ? product.width.toString() : '',
                    decoration: const InputDecoration(
                      labelText: 'Ширина (мм)',
                      border: OutlineInputBorder(),
                    ),
                    keyboardType: TextInputType.number,
                    onChanged: (val) {
                      final d = double.tryParse(val) ?? 0;
                      product.width = d;
                    },
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: TextFormField(
                    initialValue: product.height > 0 ? product.height.toString() : '',
                    decoration: const InputDecoration(
                      labelText: 'Высота (мм)',
                      border: OutlineInputBorder(),
                    ),
                    keyboardType: TextInputType.number,
                    onChanged: (val) {
                      final d = double.tryParse(val) ?? 0;
                      product.height = d;
                    },
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: TextFormField(
                    initialValue: product.depth > 0 ? product.depth.toString() : '',
                    decoration: const InputDecoration(
                      labelText: 'Глубина (мм)',
                      border: OutlineInputBorder(),
                    ),
                    keyboardType: TextInputType.number,
                    onChanged: (val) {
                      final d = double.tryParse(val) ?? 0;
                      product.depth = d;
                    },
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
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

  String _formatDate(DateTime date) {
    return '${date.day.toString().padLeft(2, '0')}.${date.month.toString().padLeft(2, '0')}.${date.year}';
  }
}