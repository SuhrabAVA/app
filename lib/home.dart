import 'package:flutter/material.dart';
import 'modules/warehouse/warehouse_screen.dart';
import 'modules/warehouse/shipment_form.dart';
import 'modules/warehouse/return_form.dart';
import 'modules/warehouse/stock_list_screen.dart';

class HomePage extends StatelessWidget {
  const HomePage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Складская система'),
      ),
      body: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            ElevatedButton(
              onPressed: () => Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => const WarehouseDashboard()),
              ),
              child: const Text('Приход ТМЦ'),
            ),
            const SizedBox(height: 10),
            ElevatedButton(
              onPressed: () => Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => const ShipmentForm()),
              ),
              child: const Text('Отгрузка'),
            ),
            const SizedBox(height: 10),
            ElevatedButton(
              onPressed: () => Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => const ReturnForm()),
              ),
              child: const Text('Возврат'),
            ),
            const SizedBox(height: 10),
            ElevatedButton(
              onPressed: () => Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => const StockListScreen()),
              ),
              child: const Text('Остатки на складе'),
            ),
          ],
        ),
      ),
    );
  }
}
