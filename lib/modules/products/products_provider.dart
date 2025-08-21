import 'package:flutter/foundation.dart';

/// Простой провайдер для управления списком типов продукции.
class ProductsProvider with ChangeNotifier {
  final List<String> _products = [
    'П-пакет',
    'V-пакет',
    'Листы',
    'Маффин',
    'Тюльпан',
  ];

  /// Текущий список доступных изделий.
  List<String> get products => List.unmodifiable(_products);

  /// Добавляет новое изделие в список.
  void addProduct(String name) {
    _products.add(name);
    notifyListeners();
  }

  /// Обновляет наименование изделия по индексу.
  void updateProduct(int index, String name) {
    if (index < 0 || index >= _products.length) return;
    _products[index] = name;
    notifyListeners();
  }

  /// Удаляет изделие из списка.
  void removeProduct(int index) {
    if (index < 0 || index >= _products.length) return;
    _products.removeAt(index);
    notifyListeners();
  }
}
