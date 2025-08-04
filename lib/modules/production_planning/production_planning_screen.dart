import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../orders/orders_provider.dart';
import 'form_editor_screen.dart';

import 'stage_editor_screen.dart';

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
       body: Column(

        children: [
          Padding(
            padding: const EdgeInsets.all(16),
            child: SizedBox(
              width: double.infinity,
              child: ElevatedButton(
                onPressed: () => _open(context, const StageEditorScreen()),
                child: const Text('Создать этап'),
              ),
            ),

            
            ),
             const Divider(height: 1),

          Expanded(
            child: ListView.builder(
              itemCount: orders.length,
              itemBuilder: (context, index) {
                final order = orders[index];
                return ListTile(
                  title: Text(order.id),
                  subtitle: Text(order.customer),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => _open(
                    context,
                    FormEditorScreen(order: order),
                  ),
                );
              },

            )
          ),
        ],
      ),
    );
  }
}
