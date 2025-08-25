import 'package:flutter/material.dart';

/// A simple screen showing archived orders. This placeholder implementation
/// displays a message that the archive is empty. In the future you can
/// populate this screen with a list of archived orders and actions.
class ArchiveOrdersScreen extends StatelessWidget {
  const ArchiveOrdersScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Архив заказов'),
      ),
      body: const Center(
        child: Text('Архив заказов пока пуст'),
      ),
    );
  }
}