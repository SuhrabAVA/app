import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../orders/orders_provider.dart';
import 'form_editor_screen.dart';
import 'template_editor_screen.dart';

class ProductionPlanningScreen extends StatelessWidget {
  const ProductionPlanningScreen({super.key});

  void _open(BuildContext context, Widget page) {
    Navigator.push(context, MaterialPageRoute(builder: (_) => page));
  }

  @override
  Widget build(BuildContext context) {
    final orders = context.watch<OrdersProvider>().orders;
    return Scaffold(
      appBar: AppBar(title: const Text('Планирование производства')),
      floatingActionButton: FloatingActionButton(
        onPressed: () => _open(context, const TemplateEditorScreen()),
        child: const Icon(Icons.add),
        tooltip: 'Создать шаблон',
      ),
      body: orders.isEmpty
          ? const Center(child: Text('Заказы отсутствуют'))
          : ListView.builder(
              itemCount: orders.length,
              itemBuilder: (context, index) {
                final order = orders[index];
                return Card(
                margin:
                  const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                  child: ListTile(
                    leading: Image.network(
                      Supabase.instance.client.storage
                          .from('order_photos')
                          .getPublicUrl('${order.id}.jpg'),
                      width: 56,
                      height: 56,
                      fit: BoxFit.cover,
                      errorBuilder: (_, __, ___) =>
                          const Icon(Icons.photo, color: Colors.grey),
                    ),
                    title: Text(order.id),
                    subtitle: Text(order.customer),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () => _open(
                      context,
                      FormEditorScreen(order: order),
                    ),
                  ),
                );
              },
            ),
    );
  }
}
