// lib/modules/warehouse/forms_screen.dart
// ignore_for_file: use_build_context_synchronously
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:image_picker/image_picker.dart';
import 'dart:typed_data';
import 'warehouse_provider.dart';
import '../../utils/media_viewer.dart';

class FormsScreen extends StatefulWidget {
  const FormsScreen({Key? key}) : super(key: key);

  @override
  State<FormsScreen> createState() => _FormsScreenState();
}

class _FormsScreenState extends State<FormsScreen> {
  // Чтобы не ловить LateInitializationError
  late Future<List<Map<String, dynamic>>> _future;
  final TextEditingController _searchCtl = TextEditingController();

  @override
  void initState() {
    super.initState();
    // Заглушка до первой загрузки
    _future =
        Future<List<Map<String, dynamic>>>(() => <Map<String, dynamic>>[]);
    // После первого кадра — реальная загрузка
    WidgetsBinding.instance.addPostFrameCallback((_) => _reload());
  }

  @override
  void dispose() {
    _searchCtl.dispose();
    super.dispose();
  }

  void _reload({String? search}) {
    final wp = context.read<WarehouseProvider>();
    setState(() {
      _future = wp.searchForms(query: search, limit: 1000);
    });
  }

  /// Открывает диалог создания или редактирования формы.
  ///
  /// Если [row] передан, поля будут предзаполнены для редактирования. В
  /// противном случае будет создана новая форма. При создании номер будет
  /// вычислен автоматически для выбранной номенклатуры при вводе.
  Future<void> _showFormDialog({Map<String, dynamic>? row}) async {
    final isEditing = row != null;
    final wp = context.read<WarehouseProvider>();
    final seriesCtl =
        TextEditingController(text: row?['series']?.toString() ?? '');
    final numberCtl =
        TextEditingController(text: row?['number']?.toString() ?? '');
    final sizeCtl =
        TextEditingController(text: row?['title']?.toString() ?? '');
    final colorsCtl = TextEditingController(
        text: (row?['colors'] ?? row?['description'] ?? '').toString());
// Существующее изображение (для режима редактирования)
    final String? existingImageUrl = (row?['image_url'] as String?);
    sizeCtl.text = ([
      if ((row?['size'] ?? '').toString().isNotEmpty)
        (row?['size'] ?? '').toString(),
      if ((row?['product_type'] ?? '').toString().isNotEmpty)
        (" / " + (row?['product_type'] ?? '').toString())
    ].join('').toString());
    colorsCtl.text =
        ((row?['colors'] ?? row?['description'] ?? '')?.toString() ?? '');
    Uint8List? pickedImageBytes;

    // Prefill default number: global max(number)+1
    if (!isEditing) {
      try {
        final rowsAll = await wp.searchForms(limit: 2000);
        int maxN = 0;
        for (final r in rowsAll) {
          final num? nn = r['number'] as num?;
          final int nInt = nn?.toInt() ?? 0;
          if (nInt > maxN) maxN = nInt;
        }
        numberCtl.text = (maxN + 1).toString();
      } catch (_) {}
    }
    // При вводе названия номенклатуры вычисляем следующий номер
    Future<void> _updateNumber() async {
      final name = seriesCtl.text.trim();
      if (name.isEmpty) {
        if (!isEditing) numberCtl.text = '';
        return;
      }
      if (!isEditing) {
        try {
          final next = await wp.getNextFormNumber(series: name);
          numberCtl.text = next.toString();
        } catch (e) {
          // Fallback: локально считаем +1 от максимума по этой серии
          try {
            final rows = await wp.searchForms(query: name, limit: 500);
            int maxN = 0;
            for (final r in rows) {
              final srs = (r['series'] ?? '').toString();
              if (srs == name) {
                final num? nn = r['number'] as num?;
                final int nInt = nn?.toInt() ?? 0;
                if (nInt > maxN) maxN = nInt;
              }
            }
            numberCtl.text = (maxN + 1).toString();
          } catch (_) {
            // если вообще ничего не получилось — не трогаем поле
          }
        }
      }
    }

    await showDialog<void>(
      context: context,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (context, setDialogState) {
            return AlertDialog(
              title: Text(isEditing ? 'Изменить форму' : 'Новая форма'),
              content: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    TextField(
                      controller: seriesCtl,
                      decoration: const InputDecoration(
                        labelText: 'Название',
                        hintText: 'Введите название номенклатуры',
                        border: OutlineInputBorder(),
                      ),
                      onChanged: (v) {},
                    ),
                    const SizedBox(height: 8),
                    TextField(
                      controller: numberCtl,
                      decoration: const InputDecoration(
                        labelText: 'Нумерация',
                        border: OutlineInputBorder(),
                      ),
                      readOnly: !isEditing,
                    ),
                    const SizedBox(height: 8),
                    TextField(
                      controller: sizeCtl,
                      decoration: const InputDecoration(
                        labelText: 'Размер, Тип продукта',
                        hintText: 'Например, 42*32 / Листы',
                        border: OutlineInputBorder(),
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text('Цвета'),
                    TextField(
                      controller: colorsCtl,
                      decoration: const InputDecoration(
                        labelText: 'Цвета',
                        hintText: 'Черный, 192Д',
                        border: OutlineInputBorder(),
                      ),
                    ),
                    const SizedBox(height: 8),

                    const SizedBox(height: 8),
                    // Предпросмотр изображения: если есть выбранное — показываем его; иначе для редактирования показываем существующее
                    if (pickedImageBytes != null)
                      Image.memory(pickedImageBytes!, height: 100)
                    else if (isEditing &&
                        existingImageUrl != null &&
                        existingImageUrl.isNotEmpty)
                      Image.network(existingImageUrl, height: 100),
                    const SizedBox(height: 8),
                    ElevatedButton.icon(
                      onPressed: () async {
                        final picker = ImagePicker();
                        final XFile? file =
                            await picker.pickImage(source: ImageSource.gallery);
                        if (file != null) {
                          final bytes = await file.readAsBytes();
                          setDialogState(() {
                            pickedImageBytes = bytes;
                          });
                        }
                      },
                      icon: const Icon(Icons.photo_library),
                      label: const Text('Выбрать фото (не обязательно)'),
                    ),
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(ctx),
                  child: const Text('Отмена'),
                ),
                ElevatedButton(
                  onPressed: () async {
                    final name = seriesCtl.text.trim();
                    final numberText = numberCtl.text.trim();
                    final sizeCombined = sizeCtl.text.trim();
                    String? _sizeOnly;
                    String? _typeOnly;
                    if (sizeCombined.isNotEmpty) {
                      final parts = sizeCombined.split('/');
                      _sizeOnly = parts.isNotEmpty ? parts[0].trim() : null;
                      _typeOnly = parts.length > 1
                          ? parts.sublist(1).join('/').trim()
                          : null;
                    }
                    final size = _sizeOnly ?? '';
                    final typeVal = _typeOnly ?? '';
                    final colors = colorsCtl.text.trim();
                    if (name.isEmpty || numberText.isEmpty) {
                      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
                          content: Text(
                              'Название и нумерация обязательны для заполнения')));
                      return;
                    }
                    final number = int.tryParse(numberText);
                    if (number == null) {
                      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
                          content: Text('Неверный формат номера')));
                      return;
                    }
                    if (isEditing) {
                      final id = row!['id']?.toString();
                      if (id != null && id.isNotEmpty) {
                        await wp.updateForm(
                          id: id,
                          series: name,
                          number: number,
                          formSize: size.isNotEmpty ? size : null,
                          formProductType: typeVal.isNotEmpty ? typeVal : null,
                          formColors: colors.isNotEmpty ? colors : null,
                          imageBytes: pickedImageBytes,
                        );
                      }
                    } else {
                      await wp.createFormAndReturn(
                        series: name,
                        number: number,
                        formSize: size.isNotEmpty ? size : null,
                        formProductType: typeVal.isNotEmpty ? typeVal : null,
                        formColors: colors.isNotEmpty ? colors : null,
                        imageBytes: pickedImageBytes,
                      );
                    }
                    if (mounted) {
                      Navigator.pop(ctx);
                      _reload(
                          search: _searchCtl.text.trim().isEmpty
                              ? null
                              : _searchCtl.text.trim());
                    }
                  },
                  child: Text(isEditing ? 'Сохранить' : 'Создать'),
                )
              ],
            );
          },
        );
      },
    );
  }

  Future<void> _createForm() async {
    await _showFormDialog();
  }

  Future<bool> _confirmDeleteDialog(BuildContext ctx, String code) async {
    return await showDialog<bool>(
          context: ctx,
          builder: (dCtx) => AlertDialog(
            title: const Text('Удалить форму?'),
            content: Text('Удалить форму $code безвозвратно?'),
            actions: [
              TextButton(
                  onPressed: () => Navigator.pop(dCtx, false),
                  child: const Text('Отмена')),
              ElevatedButton(
                  onPressed: () => Navigator.pop(dCtx, true),
                  child: const Text('Удалить')),
            ],
          ),
        ) ??
        false;
  }

  Future<void> _deleteRow(Map<String, dynamic> row) async {
    final wp = context.read<WarehouseProvider>();
    final id = (row['id'] ?? '').toString();
    final series = (row['series'] ?? '').toString();
    final number = (row['number'] as num?)?.toInt();

    if (id.isNotEmpty) {
      await wp.deleteForm(id: id);
    } else if (series.isNotEmpty && number != null) {
      await wp.deleteForm(series: series, number: number);
    } else {
      throw Exception('Не могу определить форму для удаления');
    }

    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Форма удалена')),
    );
    _reload(
        search: _searchCtl.text.trim().isEmpty ? null : _searchCtl.text.trim());
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Формы — склад')),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
            child: TextField(
              controller: _searchCtl,
              decoration: const InputDecoration(
                hintText: 'Поиск формы (название или номер)',
                prefixIcon: Icon(Icons.search),
                border: OutlineInputBorder(),
              ),
              onChanged: (v) =>
                  _reload(search: v.trim().isEmpty ? null : v.trim()),
            ),
          ),
          Expanded(
            child: FutureBuilder<List<Map<String, dynamic>>>(
              future: _future,
              builder: (context, snap) {
                if (snap.connectionState != ConnectionState.done) {
                  return const Center(child: CircularProgressIndicator());
                }
                if (snap.hasError) {
                  return Center(child: Text('Ошибка: ${snap.error}'));
                }
                final data = (snap.data ?? const [])
                    .map((e) => Map<String, dynamic>.from(e))
                    .toList();
                if (data.isEmpty) {
                  return const Center(child: Text('Формы не найдены'));
                }

                // сортируем по серии, затем по номеру
                data.sort((a, b) {
                  final sa = (a['series'] ?? '').toString();
                  final sb = (b['series'] ?? '').toString();
                  final na = (a['number'] as num?)?.toInt() ?? 0;
                  final nb = (b['number'] as num?)?.toInt() ?? 0;
                  final sc = sa.compareTo(sb);
                  if (sc != 0) return sc;
                  return na.compareTo(nb);
                });

                return ListView.separated(
                  itemCount: data.length,
                  separatorBuilder: (_, __) => const Divider(height: 1),
                  itemBuilder: (context, i) {
                    final row = data[i];
                    final series = (row['series'] ?? '').toString();
                    final n = (row['number'] as num?)?.toInt() ?? 0;
                    final nameNumber = series.isNotEmpty
                        ? '$series №${n > 0 ? n.toString() : ''}'
                        : (n > 0 ? '№' + n.toString() : '?');

                    final sizeStr = (row['size'] ?? '').toString();
                    final typeStr = (row['product_type'] ?? '').toString();
                    final colorsStr = (row['colors'] ?? '').toString();
                    final subtitle = <String>[];
                    if (sizeStr.isNotEmpty) subtitle.add('Размер: $sizeStr');
                    if (typeStr.isNotEmpty) subtitle.add('Тип: $typeStr');
                    if (colorsStr.isNotEmpty) subtitle.add('Цвета: $colorsStr');

                    final imageUrl = (row['image_url'] ?? '').toString();

                    return Dismissible(
                      key: ValueKey('form_${row['id'] ?? '$series/$n'}'),
                      direction: DismissDirection.endToStart,
                      background: Container(
                        color: Colors.red.withOpacity(0.1),
                        alignment: Alignment.centerRight,
                        padding: const EdgeInsets.symmetric(horizontal: 16),
                        child: const Icon(Icons.delete_outline),
                      ),
                      confirmDismiss: (_) =>
                          _confirmDeleteDialog(context, nameNumber),
                      onDismissed: (_) => _deleteRow(row),
                      child: ListTile(
                        onTap: () => _showFormDialog(row: row),
                        leading: imageUrl.isNotEmpty
                            ? GestureDetector(
                                onTap: () => showImagePreview(
                                  context,
                                  imageUrl: imageUrl,
                                  title: nameNumber,
                                ),
                                child: ClipRRect(
                                  borderRadius: BorderRadius.circular(20),
                                  child: Image.network(
                                    imageUrl,
                                    width: 40,
                                    height: 40,
                                    fit: BoxFit.cover,
                                    errorBuilder: (_, __, ___) =>
                                        const Icon(Icons.image_not_supported),
                                  ),
                                ),
                              )
                            : CircleAvatar(
                                child: Text(
                                  series.isEmpty
                                      ? '?'
                                      : series.substring(0, 1),
                                ),
                              ),
                        title: Text(nameNumber),
                        subtitle: subtitle.isEmpty
                            ? null
                            : Text(subtitle.join('  |  ')),
                        trailing: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            IconButton(
                              tooltip: 'Изменить',
                              icon: const Icon(Icons.edit_outlined),
                              onPressed: () => _showFormDialog(row: row),
                            ),
                            IconButton(
                              tooltip: 'Удалить',
                              icon: const Icon(Icons.delete_outline),
                              onPressed: () async {
                                final ok = await _confirmDeleteDialog(
                                    context, nameNumber);
                                if (ok) await _deleteRow(row);
                              },
                            ),
                          ],
                        ),
                      ),
                    );
                  },
                );
              },
            ),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: _createForm,
        child: const Icon(Icons.add),
      ),
    );
  }
}
