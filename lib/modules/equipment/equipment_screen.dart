import 'package:flutter/material.dart';

class EquipmentScreen extends StatelessWidget {
  const EquipmentScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Оборудование')),
      body: const Center(
        child: Text(
          'Здесь будет управление оборудованием',
          style: TextStyle(fontSize: 18),
        ),
      ),
    );
  }
}
