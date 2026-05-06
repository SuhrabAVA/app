import 'package:flutter_test/flutter_test.dart';
import 'package:sheet_clone/modules/orders/edit_order_screen.dart';
import 'package:sheet_clone/modules/orders/stage_queue_builder.dart';

void main() {
  group('supportsCardboardForTesting', () {
    test('returns false for sheet and V-type products', () {
      expect(supportsCardboardForTesting(kSheetProductTypeId), isFalse);

      for (final productTypeId in kVTypeProducts) {
        expect(
          supportsCardboardForTesting(productTypeId),
          isFalse,
          reason: 'V-type product $productTypeId should not support cardboard',
        );
      }
    });

    test('returns true for P-type and two-sheet package products', () {
      expect(supportsCardboardForTesting(kPTypePackageProduct), isTrue);
      expect(supportsCardboardForTesting(kTwoSheetPackageProductTypeId), isTrue);
    });
  });
}
