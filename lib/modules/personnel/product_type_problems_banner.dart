import 'package:flutter/material.dart';

/// Красная полоса со структурными проблемами версии настроек.
///
/// Показывается после каждой правки, а не при публикации: иначе техлид узнаёт
/// о проблеме через десять действий и уже не помнит, какое из них виновато.
/// Текст приходит от validate_product_type_config — формулировки живут в
/// функции, чтобы совпадать с отказом публикации слово в слово.
class ProductTypeProblemsBanner extends StatelessWidget {
  const ProductTypeProblemsBanner({super.key, required this.problems});

  final List<String> problems;

  @override
  Widget build(BuildContext context) {
    if (problems.isEmpty) return const SizedBox.shrink();
    return Container(
      width: double.infinity,
      color: const Color(0xFFFFEBEE),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Маршрут нельзя опубликовать:',
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: Colors.red.shade900,
            ),
          ),
          for (final problem in problems)
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Text('• $problem',
                  style: TextStyle(fontSize: 12, color: Colors.red.shade900)),
            ),
        ],
      ),
    );
  }
}
