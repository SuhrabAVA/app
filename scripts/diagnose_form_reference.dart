// Read-only reproduction of the string fallback in edit_order_screen.dart.
void main() {
  const label = 'Rommi  doner 1,5 1671';
  final number = int.tryParse(RegExp(r'\d+').firstMatch(label)!.group(0)!);
  final series = RegExp(r'^[A-Za-zА-Яа-я]+').firstMatch(label)!.group(0);
  if (number != 1 || series != 'Rommi') {
    throw StateError('Unexpected fallback result: $number / $series');
  }
  print('Input: $label');
  print('Current fallback: number=$number, series=$series');
  print('Warehouse record: number=1671, series=Rommi  doner 1,5');
  print('Confirmed: digits in the name replace the actual form number.');
}
