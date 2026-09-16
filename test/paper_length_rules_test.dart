import 'package:flutter_test/flutter_test.dart';
import 'package:sheet_clone/modules/orders/paper_length_rules.dart';

void main() {
  test('правка «Длины L» побеждает сохранённое количество', () {
    // Регрессия: заказ сохранили с 3900 м, потом исправили поле на 740 —
    // и он продолжал требовать 3900, потому что сохранённое значение было
    // приоритетнее поля.
    expect(
      persistedPaperQuantity(editedLength: 740, storedQuantity: 3900),
      740,
    );
  });

  test('пустое поле оставляет то, что уже сохранено', () {
    expect(
      persistedPaperQuantity(editedLength: 0, storedQuantity: 3900),
      3900,
    );
  });

  test('без поля и без сохранённого берётся общая длина заказа', () {
    expect(
      persistedPaperQuantity(
        editedLength: 0,
        storedQuantity: 0,
        fallback: 1200,
      ),
      1200,
    );
  });

  test('когда нечего взять — ноль, а не мусор', () {
    expect(persistedPaperQuantity(editedLength: 0, storedQuantity: 0), 0);
    expect(
      persistedPaperQuantity(
        editedLength: 0,
        storedQuantity: 0,
        fallback: -5,
      ),
      0,
    );
  });

  test('правка вниз применяется так же, как правка вверх', () {
    expect(
      persistedPaperQuantity(
        editedLength: 100,
        storedQuantity: 5000,
        fallback: 9000,
      ),
      100,
    );
    expect(
      persistedPaperQuantity(
        editedLength: 9000,
        storedQuantity: 100,
        fallback: 50,
      ),
      9000,
    );
  });
}
