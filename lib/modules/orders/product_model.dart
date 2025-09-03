/// Модель продукта внутри заказа.
class ProductModel {
  final String id;
  String type; // наименование изделия (код/название)
  int quantity; // тираж
  double width;
  double height;
  double depth;
  String parameters; // параметры продукта (строка)

  ProductModel({
    required this.id,
    required this.type,
    required this.quantity,
    required this.width,
    required this.height,
    required this.depth,
    this.parameters = '',
  });
}