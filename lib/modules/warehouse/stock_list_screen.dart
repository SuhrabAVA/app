import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'warehouse_provider.dart';
import 'tmc_model.dart';

class StockListScreen extends StatefulWidget {
  const StockListScreen({super.key});

  @override
  State<StockListScreen> createState() => _StockListScreenState();
}

class _StockListScreenState extends State<StockListScreen> {
  String? _selectedType;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      Provider.of<WarehouseProvider>(context, listen: false).fetchTmc();
    });
  }

  @override
  Widget build(BuildContext context) {
    final provider = Provider.of<WarehouseProvider>(context);
    final allStocks = provider.allTmc;

    final filteredStocks = _selectedType == null
        ? allStocks
        : allStocks.where((e) => e.type == _selectedType).toList();

    final uniqueTypes = allStocks.map((e) => e.type).toSet().toList();

    return Scaffold(
      appBar: AppBar(
        title: const Text('Остатки на складе'),
        actions: [
          DropdownButton<String?>(
            value: _selectedType,
            hint: const Text('Фильтр по типу'),
            onChanged: (val) => setState(() => _selectedType = val),
            items: [
              const DropdownMenuItem<String?>(
                value: null,
                child: Text('Все'),
              ),
              ...uniqueTypes.map(
                (type) => DropdownMenuItem<String?>(
                  value: type,
                  child: Text(type),
                ),
              ),
            ],
          ),
        ],
      ),
      body: allStocks.isEmpty
          ? const Center(child: CircularProgressIndicator())
          : ListView.builder(
              itemCount: filteredStocks.length,
              itemBuilder: (_, index) {
                final tmc = filteredStocks[index];
                return Card(
                  margin:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                  child: ListTile(
                    title: Text('${tmc.type} — ${tmc.description}'),
                    subtitle:
                        Text('Количество: ${tmc.quantity} ${tmc.unit}'),
                    trailing: Text(
                      tmc.date.split('T').first,
                      style: const TextStyle(color: Colors.grey),
                    ),
                  ),
                );
              },
            ),
    );
  }
}
