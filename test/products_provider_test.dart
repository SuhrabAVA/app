import 'package:flutter_test/flutter_test.dart';
import 'package:sheet_clone/modules/products/products_provider.dart';

void main() {
  test('manage parameters and handles', () {
    final provider = ProductsProvider();
    provider.addParameter('ламинат');
    provider.addHandle('верёвочная');
    expect(provider.parameters, contains('ламинат'));
    expect(provider.handles, contains('верёвочная'));
    provider.updateParameter(0, 'тиснение');
    provider.updateHandle(0, 'пластиковая');
    expect(provider.parameters.first, 'тиснение');
    expect(provider.handles.first, 'пластиковая');
    provider.removeParameter(0);
    provider.removeHandle(0);
    expect(provider.parameters, isEmpty);
    expect(provider.handles, isEmpty);
  });
}
