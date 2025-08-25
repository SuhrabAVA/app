import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import 'order_model.dart';

/// Расширенный экран просмотра заказа. Показывает всю информацию,
/// доступную в модуле оформления заказа, с акцентом на заказчика.
class ViewOrderScreen extends StatelessWidget {
  final OrderModel order;

  const ViewOrderScreen({super.key, required this.order});

  String _formatDate(DateTime date) => DateFormat('dd.MM.yyyy').format(date);

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(order.customer),
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          _sectionTitle('Основная информация'),
          _infoTile('ID заказа', order.id, Icons.confirmation_number_outlined),
          _infoTile('Дата заказа', _formatDate(order.orderDate), Icons.event),
          _infoTile('Срок', _formatDate(order.dueDate), Icons.event_note),
          _infoTile('Статус', order.status, Icons.flag),
          const SizedBox(height: 16),

          _sectionTitle('Изделие'),
          _infoTile('Тип', order.product.type, Icons.widgets_outlined),
          _infoTile('Тираж', '${order.product.quantity}', Icons.layers),
          if (order.additionalParams.isNotEmpty)
            _infoTile('Доп. параметры', order.additionalParams.join(', '), Icons.list),
          const SizedBox(height: 16),

          _sectionTitle('Материалы'),
          _infoTile('Ручка', order.handle, Icons.pan_tool_outlined),
          _infoTile('Картон', order.cardboard, Icons.style_outlined),
          _infoTile('Материал', order.material?.name ?? '—', Icons.inventory_2_outlined),
          _infoTile('Макулатура', order.makeready.toString(), Icons.calculate_outlined),
          _infoTile('Стоимость', order.val.toString(), Icons.attach_money),
          const SizedBox(height: 16),

          _sectionTitle('Дополнительно'),
          _infoTile('Договор подписан', order.contractSigned ? 'Да' : 'Нет', Icons.assignment_turned_in_outlined),
          _infoTile('Оплата получена', order.paymentDone ? 'Да' : 'Нет', Icons.payment_outlined),
          if (order.pdfUrl != null)
            _infoTile('PDF', order.pdfUrl!, Icons.picture_as_pdf_outlined),
          if (order.comments.isNotEmpty)
            _infoTile('Комментарии', order.comments, Icons.comment_outlined),
        ],
      ),
    );
  }

  Widget _sectionTitle(String text) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Text(
        text,
        style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
      ),
    );
  }

  Widget _infoTile(String label, String value, IconData icon) {
    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: Icon(icon, color: Colors.blueGrey),
      title: Text(label, style: const TextStyle(fontSize: 14, color: Colors.black54)),
      subtitle: Text(value, style: const TextStyle(fontSize: 14, color: Colors.black)),
    );
  }
}