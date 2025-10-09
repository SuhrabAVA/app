import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'warehouse_provider.dart';
import 'tmc_model.dart';
import '../../utils/kostanay_time.dart';

class StockListScreen extends StatefulWidget {
  const StockListScreen({super.key});

  @override
  State<StockListScreen> createState() => _StockListScreenState();
}

class _StockListScreenState extends State<StockListScreen> {
  String? _selectedType;

  /// Возвращает цвет индикатора в зависимости от текущего количества и пороговых значений.
  /// Возвращает null, если пороги не заданы или количество выше порога.
  Color? _statusColor(TmcModel tmc) {
    final double qty = tmc.quantity;
    final double? critical = tmc.criticalThreshold;
    final double? low = tmc.lowThreshold;
    if (critical != null && qty <= critical) {
      return Colors.red;
    }
    if (low != null && qty <= low) {
      return Colors.orange;
    }
    return null;
  }

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
                final TmcModel tmc = filteredStocks[index];
                final Color? statusColor = _statusColor(tmc);
                // Формируем строки для отображения порогов и времени
                final String thresholds =
                    'Пороги: ${tmc.lowThreshold?.toString() ?? '-'} / ${tmc.criticalThreshold?.toString() ?? '-'}';
                final String dateStr = tmc.createdAt ?? tmc.date;
                final formatted = formatKostanayTimestamp(dateStr);
                final dateDisplay = () {
                  if (formatted == '—') return formatted;
                  final dateParts = formatted.split(' ').first.split('-');
                  if (dateParts.length == 3) {
                    return '${dateParts[2]}.${dateParts[1]}.${dateParts[0]}';
                  }
                  return formatted.split(' ').first;
                }();
                return Card(
                  margin:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                  child: ListTile(
                    leading: statusColor == null
                        ? null
                        : Container(
                            width: 12,
                            height: 12,
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              color: statusColor,
                            ),
                          ),
                    title: Text('${tmc.type} — ${tmc.description}'),
                    subtitle: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('Количество: ${tmc.quantity} ${tmc.unit}'),
                        if (tmc.format != null && tmc.format!.trim().isNotEmpty)
                          Text('Формат: ${tmc.format}'),
                        if (tmc.grammage != null &&
                            tmc.grammage!.trim().isNotEmpty)
                          Text('Граммаж: ${tmc.grammage}'),
                        if (tmc.weight != null) Text('Вес: ${tmc.weight} кг'),
                        if (tmc.note != null && tmc.note!.trim().isNotEmpty)
                          Text('Заметки: ${tmc.note}'),
                        Text(thresholds),
                      ],
                    ),
                    trailing: Text(
                      dateDisplay,
                      style: const TextStyle(color: Colors.grey),
                    ),
                  ),
                );
              },
            ),
    );
  }
}
