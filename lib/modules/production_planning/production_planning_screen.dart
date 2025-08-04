import 'package:flutter/material.dart';

class ProductionPlanningScreen extends StatelessWidget {
  const ProductionPlanningScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Планирование производства')),
      body: const Center(
        child: Text(
          'Здесь будет модуль планирования производства',
          style: TextStyle(fontSize: 18),
        ),
      ),
    );
  }
}
