import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sheet_clone/widgets/brand_mark.dart';

/// Логотип показывается через Image.asset, а иконки ОС режутся из того же
/// файла. Если файл переименуют или забудут внести в pubspec, приложение
/// упадёт картинкой-ошибкой уже на экране запуска — здесь это ловится сразу.
void main() {
  test('файл логотипа лежит там, где его ждёт приложение', () {
    final file = File(kBrandLogoAsset);
    expect(file.existsSync(), isTrue, reason: 'нет файла $kBrandLogoAsset');
    expect(file.lengthSync(), greaterThan(1024), reason: 'файл подозрительно мал');
  });

  test('логотип объявлен в pubspec как ассет', () {
    final pubspec = File('pubspec.yaml').readAsStringSync();
    expect(
      pubspec.contains(kBrandLogoAsset),
      isTrue,
      reason: 'добавьте $kBrandLogoAsset в flutter/assets',
    );
  });

  test('иконки ОС собраны из логотипа', () {
    final icons = <String>[
      'windows/runner/resources/app_icon.ico',
      'android/app/src/main/res/mipmap-mdpi/ic_launcher.png',
      'android/app/src/main/res/mipmap-hdpi/ic_launcher.png',
      'android/app/src/main/res/mipmap-xhdpi/ic_launcher.png',
      'android/app/src/main/res/mipmap-xxhdpi/ic_launcher.png',
      'android/app/src/main/res/mipmap-xxxhdpi/ic_launcher.png',
    ];
    for (final path in icons) {
      expect(File(path).existsSync(), isTrue, reason: 'нет $path');
    }
  });

  test('приложение больше не называется sheet_clone', () {
    final manifest =
        File('android/app/src/main/AndroidManifest.xml').readAsStringSync();
    expect(manifest.contains('android:label="$kBrandName"'), isTrue);

    final mainCpp = File('windows/runner/main.cpp').readAsStringSync();
    expect(mainCpp.contains('L"$kBrandName"'), isTrue);
    expect(mainCpp.contains('sheet_clone'), isFalse);
  });
}
