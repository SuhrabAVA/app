// Бэкофилл миниатюр фото красок: для каждого paints.image_url скачивает
// оригинал из Storage (bucket `tmc`), делает миниатюру шириной 200px
// (JPEG q80) и кладёт её рядом с оригиналом как `<имя>_thumb.jpg`.
// Колонки в БД не трогает — приложение выводит URL миниатюры из image_url
// (TmcModel.thumbUrl).
//
// Запуск из корня проекта:
//   dart run scripts/backfill_paint_thumbs.dart --limit 8 --save-dir <папка>
//   dart run scripts/backfill_paint_thumbs.dart          # все фото
// Флаги:
//   --limit N     обработать не больше N фото
//   --offset N    пропустить первые N (по алфавиту description)
//   --force       перезаписывать уже существующие миниатюры
//   --save-dir P  дополнительно сохранить миниатюры локально в папку P
//   --dry-run     только скачать/сжать и показать размеры, БЕЗ загрузки в Storage

import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:image/image.dart' as img;

Map<String, String> readEnv(String path) {
  final env = <String, String>{};
  for (final line in File(path).readAsLinesSync()) {
    final trimmed = line.trim();
    if (trimmed.isEmpty || trimmed.startsWith('#')) continue;
    final eq = trimmed.indexOf('=');
    if (eq <= 0) continue;
    env[trimmed.substring(0, eq)] = trimmed.substring(eq + 1);
  }
  return env;
}

Future<void> main(List<String> args) async {
  int? limit;
  int offset = 0;
  bool force = false;
  bool dryRun = false;
  String? saveDir;
  for (var i = 0; i < args.length; i++) {
    switch (args[i]) {
      case '--limit':
        limit = int.parse(args[++i]);
      case '--offset':
        offset = int.parse(args[++i]);
      case '--force':
        force = true;
      case '--dry-run':
        dryRun = true;
      case '--save-dir':
        saveDir = args[++i];
    }
  }

  final env = readEnv('.env');
  final baseUrl = env['SUPABASE_URL']!;
  final key = env['SUPABASE_SERVICE_ROLE_KEY']!;
  final headers = {
    'apikey': key,
    'Authorization': 'Bearer $key',
  };

  if (saveDir != null) Directory(saveDir).createSync(recursive: true);

  // Все краски с фото, стабильный порядок по названию.
  final listResp = await http.get(
    Uri.parse(
        '$baseUrl/rest/v1/paints?select=id,description,image_url&image_url=not.is.null&order=description'),
    headers: headers,
  );
  if (listResp.statusCode != 200) {
    stderr.writeln('Не удалось получить список красок: ${listResp.statusCode} ${listResp.body}');
    exit(1);
  }
  var rows = (jsonDecode(listResp.body) as List).cast<Map<String, dynamic>>();
  rows = rows.skip(offset).take(limit ?? rows.length).toList();
  stdout.writeln('К обработке: ${rows.length} фото'
      '${dryRun ? ' (dry-run, без загрузки)' : ''}');

  const marker = '/storage/v1/object/public/tmc/';
  var ok = 0, skipped = 0, failed = 0;
  var totalOrigBytes = 0, totalThumbBytes = 0, totalMs = 0;

  for (final row in rows) {
    final desc = (row['description'] ?? '').toString();
    final imageUrl = (row['image_url'] ?? '').toString();
    final idx = imageUrl.indexOf(marker);
    if (idx == -1) {
      stderr.writeln('SKIP  «$desc»: нестандартный image_url: $imageUrl');
      skipped++;
      continue;
    }
    final objectPath = imageUrl.substring(idx + marker.length); // tmc/<id>/<ts>.jpeg
    final dot = objectPath.lastIndexOf('.');
    final slash = objectPath.lastIndexOf('/');
    final thumbPath = dot > slash
        ? '${objectPath.substring(0, dot)}_thumb.jpg'
        : '${objectPath}_thumb.jpg';
    final thumbUrl = '$baseUrl/storage/v1/object/public/tmc/$thumbPath';

    final sw = Stopwatch()..start();
    try {
      if (!force) {
        final probe = await http.head(Uri.parse(thumbUrl));
        if (probe.statusCode == 200) {
          stdout.writeln('SKIP  «$desc»: миниатюра уже есть');
          skipped++;
          continue;
        }
      }

      final orig = await http.get(Uri.parse(imageUrl));
      if (orig.statusCode != 200) {
        stderr.writeln('FAIL  «$desc»: оригинал ${orig.statusCode}');
        failed++;
        continue;
      }
      var decoded = img.decodeImage(orig.bodyBytes);
      if (decoded == null) {
        stderr.writeln('FAIL  «$desc»: не декодируется');
        failed++;
        continue;
      }
      // Ориентация из EXIF запекается в пиксели, дальше метаданные не нужны.
      decoded = img.bakeOrientation(decoded);
      final resized = decoded.width <= 200
          ? decoded
          : img.copyResize(decoded, width: 200, interpolation: img.Interpolation.average);
      // EXIF и ICC не переносим: один ICC телефонных фото весит ~47 КБ.
      resized.exif = img.ExifData();
      resized.iccProfile = null;
      final thumb = img.encodeJpg(resized, quality: 80);

      if (saveDir != null) {
        final safe = desc.replaceAll(RegExp(r'[^\wа-яА-ЯёЁ .-]'), '_');
        File('$saveDir/${safe}_thumb.jpg').writeAsBytesSync(thumb);
      }

      if (!dryRun) {
        final up = await http.post(
          Uri.parse('$baseUrl/storage/v1/object/tmc/$thumbPath'),
          headers: {
            ...headers,
            'Content-Type': 'image/jpeg',
            'x-upsert': 'true',
          },
          body: thumb,
        );
        if (up.statusCode != 200) {
          stderr.writeln('FAIL  «$desc»: upload ${up.statusCode} ${up.body}');
          failed++;
          continue;
        }
      }
      sw.stop();
      ok++;
      totalOrigBytes += orig.bodyBytes.length;
      totalThumbBytes += thumb.length;
      totalMs += sw.elapsedMilliseconds;
      stdout.writeln(
          'OK    «$desc»: ${(orig.bodyBytes.length / 1024).toStringAsFixed(0)} КБ '
          '→ ${(thumb.length / 1024).toStringAsFixed(1)} КБ '
          '(${decoded.width}x${decoded.height} → ${resized.width}x${resized.height}), '
          '${sw.elapsedMilliseconds} мс');
    } catch (e) {
      stderr.writeln('FAIL  «$desc»: $e');
      failed++;
    }
  }

  stdout.writeln('---');
  stdout.writeln('Готово: ok=$ok, skip=$skipped, fail=$failed');
  if (ok > 0) {
    stdout.writeln(
        'Средний размер: оригинал ${(totalOrigBytes / ok / 1024).toStringAsFixed(0)} КБ '
        '→ миниатюра ${(totalThumbBytes / ok / 1024).toStringAsFixed(1)} КБ; '
        'среднее время ${(totalMs / ok).toStringAsFixed(0)} мс/фото');
  }
  exit(failed > 0 ? 2 : 0);
}
