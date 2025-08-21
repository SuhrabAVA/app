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

  /// Дополнительные параметры для изделий (чекбоксы в заказе).
  final List<String> _parameters = [];

  /// Список возможных ручек.
  final List<String> _handles = [];

  /// Текущий список доступных изделий.
  List<String> get products => List.unmodifiable(_products);

  /// Список дополнительных параметров.
  List<String> get parameters => List.unmodifiable(_parameters);

  /// Список доступных ручек.
  List<String> get handles => List.unmodifiable(_handles);

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

  // ----- Дополнительные параметры -----

  void addParameter(String name) {
    _parameters.add(name);
    notifyListeners();
  }

  void updateParameter(int index, String name) {
    if (index < 0 || index >= _parameters.length) return;
    _parameters[index] = name;
    notifyListeners();
  }

  void removeParameter(int index) {
    if (index < 0 || index >= _parameters.length) return;
    _parameters.removeAt(index);
    notifyListeners();
  }

  // ----- Ручки -----

  void addHandle(String name) {
    _handles.add(name);
    notifyListeners();
  }

  void updateHandle(int index, String name) {
    if (index < 0 || index >= _handles.length) return;
    _handles[index] = name;
    notifyListeners();
  }

  void removeHandle(int index) {
    if (index < 0 || index >= _handles.length) return;
    _handles.removeAt(index);
    notifyListeners();
  }
}
