import 'package:flutter/material.dart';

class ProductionScreen extends StatelessWidget {
  const ProductionScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Производство')),
      body: const Center(
        child: Text(
          'Здесь будет модуль производства',
          style: TextStyle(fontSize: 18),
        ),
      ),
    );
  }
}
