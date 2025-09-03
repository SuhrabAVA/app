import 'package:flutter/material.dart';
import 'paper_table.dart';
import 'stationery_table.dart';
import 'writeoff_table.dart';
import 'suppliers_screen.dart';
import 'stock_tables.dart';
import 'add_entry_dialog.dart';
import 'stocks_screen.dart';

class WarehouseDashboard extends StatelessWidget {
  const WarehouseDashboard({super.key});

  void _openTable(BuildContext context, Widget screen) {
    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => screen),
    );
  }

  void _openAddDialog(BuildContext context) {
    showDialog(
      context: context,
      builder: (_) => const AddEntryDialog(),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Склад'),
        actions: [
          IconButton(
            icon: const Icon(Icons.add),
            onPressed: () => _openAddDialog(context),
          ),
        ],
      ),
      body: Padding(
        padding: const EdgeInsets.all(8.0),
        child: GridView.count(
          // Устанавливаем 3 колонки, чтобы разместить 6 карточек в две строки
          crossAxisCount: 3,
          crossAxisSpacing: 8,
          mainAxisSpacing: 8,
          childAspectRatio: 1,
          children: [
            _buildCard(context, '📄\nБумага', const PaperTable()),
            _buildCard(context, '✏️\nКанцелярия', const StationeryTable()),
            _buildCard(context, '🗑️\nСписание', const WriteOffTable()),
            _buildCard(context, '📦\nКатегории', const StockTables()),
            _buildCard(context, '📊\nЗапасы', const StocksScreen()),
            _buildCard(context, '🏷️\nПоставщики', const SuppliersScreen()),
          ],
        ),
      ),
    );
  }

  Widget _buildCard(BuildContext context, String title, Widget page) {
    return GestureDetector(
      onTap: () => _openTable(context, page),
      child: Container(
        decoration: BoxDecoration(
          color: Colors.lightBlue.shade50,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: Colors.blueGrey.shade100),
        ),
        padding: const EdgeInsets.all(4),
        child: Center(
          child: Text(
            title,
            textAlign: TextAlign.center,
            style: const TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              height: 1.3,
            ),
          ),
        ),
      ),
    );
  }
}
