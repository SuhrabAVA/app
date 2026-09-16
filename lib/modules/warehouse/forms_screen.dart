// lib/modules/warehouse/forms_screen.dart
// ignore_for_file: use_build_context_synchronously
import 'dart:async';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'warehouse_provider.dart';
import '../../services/realtime_sync_service.dart';
import '../../services/storage_service.dart' as storage;
import '../common/pdf_view_screen.dart';

String _cleanSizeLabel(String size) {
  final trimmed = size.trim();
  if (trimmed.isEmpty) return '';

  final parenthetical = RegExp(r'\(([^)]*)\)').allMatches(trimmed).toList();
  final base = trimmed.replaceAll(RegExp(r'\([^)]*\)'), '').trim();
  final extras = <String>[];

  for (final match in parenthetical) {
    final parts = (match.group(1) ?? '')
        .split(',')
        .map((p) => p.trim())
        .where((p) => p.isNotEmpty)
        .toList();

    for (final part in parts) {
      final lower = part.toLowerCase();
      if (lower.startsWith('б') ||
          lower.startsWith('кол-во') ||
          lower.startsWith('l')) {
        continue;
      }
      extras.add(part);
    }
  }

  if (extras.isEmpty) return base;
  if (base.isEmpty) return extras.join(', ');
  return '$base (${extras.join(', ')})';
}

enum FormsSort {
  numberDesc,
  numberAsc,
  seriesAsc,
  seriesDesc,
}

class FormsScreen extends StatefulWidget {
  const FormsScreen({Key? key}) : super(key: key);

  @override
  State<FormsScreen> createState() => _FormsScreenState();
}

class _FormsScreenState extends State<FormsScreen> {
  // Чтобы не ловить LateInitializationError
  late Future<List<Map<String, dynamic>>> _future;
  final TextEditingController _searchCtl = TextEditingController();
  FormsSort _sort = FormsSort.numberDesc;

  @override
  void initState() {
    super.initState();
    // Заглушка до первой загрузки
    _future =
        Future<List<Map<String, dynamic>>>(() => <Map<String, dynamic>>[]);
    RealtimeSyncService.instance.registerRefreshHandler(
      owner: this,
      resource: RealtimeResource.forms,
      handler: _refreshFromRealtime,
    );
    // После первого кадра — реальная загрузка
    WidgetsBinding.instance.addPostFrameCallback((_) => _reload());
  }

  @override
  void dispose() {
    RealtimeSyncService.instance.unregisterOwner(this);
    _searchCtl.dispose();
    super.dispose();
  }

  Future<void> _refreshFromRealtime() async {
    final search = _searchCtl.text.trim();
    await _reload(search: search.isEmpty ? null : search);
  }

  Future<void> _reload({String? search}) async {
    if (!mounted) return;
    final wp = context.read<WarehouseProvider>();
    final future = wp.searchForms(query: search, limit: 1000);
    setState(() {
      _future = future;
    });
    await future;
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
    final extraInfoCtl =
        TextEditingController(text: (row?['description'] ?? '').toString());
    sizeCtl.text = ([
      if ((row?['size'] ?? '').toString().isNotEmpty)
        (row?['size'] ?? '').toString(),
      if ((row?['product_type'] ?? '').toString().isNotEmpty)
        (" / " + (row?['product_type'] ?? '').toString())
    ].join('').toString());
    colorsCtl.text = (row?['colors'] ?? '').toString();
    // PDF staging: выбранные, но ещё не загруженные файлы.
    List<PlatformFile> pickedPdfs = [];
    // Уже сохранённые PDF этой формы (режим редактирования).
    List<Map<String, dynamic>> savedPdfs = [];
    bool numberManuallyEdited = isEditing;

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
      if (numberManuallyEdited) return;
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

    // Загружаем уже сохранённые PDF формы (режим редактирования).
    if (isEditing) {
      final formId = row?['id']?.toString() ?? '';
      if (formId.isNotEmpty) {
        try {
          savedPdfs = await storage.listFormFiles(formId);
        } catch (_) {}
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
                      onChanged: (v) {
                        if (!isEditing && !numberManuallyEdited) {
                          _updateNumber();
                        }
                      },
                    ),
                    const SizedBox(height: 8),
                    TextField(
                      controller: numberCtl,
                      decoration: const InputDecoration(
                        labelText: 'Нумерация',
                        border: OutlineInputBorder(),
                      ),
                      onChanged: (_) {
                        numberManuallyEdited = true;
                      },
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
                    TextField(
                      controller: extraInfoCtl,
                      decoration: const InputDecoration(
                        labelText: 'Доп. информация',
                        hintText: 'Необязательно',
                        border: OutlineInputBorder(),
                      ),
                    ),
                    const SizedBox(height: 8),

                    // ── Уже сохранённые PDF (только в режиме редактирования) ──
                    if (isEditing) ...[
                      const Divider(height: 20),
                      const Align(
                        alignment: Alignment.centerLeft,
                        child: Text(
                          'Файлы формы',
                          style: TextStyle(fontWeight: FontWeight.w600),
                        ),
                      ),
                      const SizedBox(height: 4),
                      if (savedPdfs.isEmpty)
                        const Text(
                          'PDF не загружены',
                          style: TextStyle(color: Colors.grey),
                        )
                      else
                        ...savedPdfs.map((f) {
                          final fname =
                              (f['filename'] ?? f['name'] ?? 'Файл.pdf')
                                  .toString();
                          final source = (f['source'] ?? 'form').toString();
                          final objectPath = (f['objectPath'] ?? '').toString();
                          return Padding(
                            padding: const EdgeInsets.symmetric(vertical: 2),
                            child: Row(
                              children: [
                                Icon(
                                  Icons.picture_as_pdf,
                                  size: 16,
                                  color: source == 'order'
                                      ? Colors.grey
                                      : Colors.red,
                                ),
                                const SizedBox(width: 6),
                                Expanded(
                                  child: Text(
                                    fname,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(fontSize: 13),
                                  ),
                                ),
                                if (source == 'order')
                                  const Padding(
                                    padding:
                                        EdgeInsets.symmetric(horizontal: 4),
                                    child: Text(
                                      'из заказа',
                                      style: TextStyle(
                                          fontSize: 11, color: Colors.grey),
                                    ),
                                  ),
                                IconButton(
                                  tooltip: 'Открыть',
                                  icon: const Icon(Icons.open_in_new, size: 16),
                                  padding: EdgeInsets.zero,
                                  constraints: const BoxConstraints(),
                                  onPressed: objectPath.isEmpty
                                      ? null
                                      : () async {
                                          final url = await storage
                                              .getSignedUrl(objectPath);
                                          if (!context.mounted) return;
                                          await Navigator.of(context).push(
                                            MaterialPageRoute(
                                              builder: (_) => PdfViewScreen(
                                                url: url,
                                                title: fname,
                                              ),
                                            ),
                                          );
                                        },
                                ),
                                IconButton(
                                  tooltip: 'Удалить',
                                  icon: const Icon(Icons.delete_outline,
                                      size: 16, color: Colors.red),
                                  padding: EdgeInsets.zero,
                                  constraints: const BoxConstraints(),
                                  onPressed: () async {
                                    final confirmed = await showDialog<bool>(
                                      context: context,
                                      builder: (dCtx) => AlertDialog(
                                        title: const Text('Удалить файл?'),
                                        content: Text(
                                          source == 'order'
                                              ? 'Файл "$fname" будет отвязан от формы (сам файл заказа останется).'
                                              : 'Файл "$fname" будет удалён безвозвратно.',
                                        ),
                                        actions: [
                                          TextButton(
                                            onPressed: () =>
                                                Navigator.pop(dCtx, false),
                                            child: const Text('Отмена'),
                                          ),
                                          ElevatedButton(
                                            style: ElevatedButton.styleFrom(
                                                backgroundColor: Colors.red),
                                            onPressed: () =>
                                                Navigator.pop(dCtx, true),
                                            child: const Text('Удалить'),
                                          ),
                                        ],
                                      ),
                                    );
                                    if (confirmed != true) return;
                                    await storage.deleteFormFile(f);
                                    setDialogState(() {
                                      savedPdfs.remove(f);
                                    });
                                  },
                                ),
                              ],
                            ),
                          );
                        }),
                      const Divider(height: 20),
                    ],

                    // ── Staging: выбранные PDF ещё не загружены ──
                    if (pickedPdfs.isNotEmpty) ...[
                      const Align(
                        alignment: Alignment.centerLeft,
                        child: Text(
                          'Новые PDF (будут загружены при сохранении):',
                          style: TextStyle(fontSize: 12, color: Colors.grey),
                        ),
                      ),
                      const SizedBox(height: 4),
                      ...pickedPdfs.asMap().entries.map((entry) {
                        final idx = entry.key;
                        final file = entry.value;
                        return Padding(
                          padding: const EdgeInsets.symmetric(vertical: 2),
                          child: Row(
                            children: [
                              const Icon(Icons.picture_as_pdf,
                                  size: 16, color: Colors.red),
                              const SizedBox(width: 6),
                              Expanded(
                                child: Text(
                                  file.name,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(fontSize: 13),
                                ),
                              ),
                              IconButton(
                                tooltip: 'Убрать',
                                icon: const Icon(Icons.close,
                                    size: 16, color: Colors.red),
                                padding: EdgeInsets.zero,
                                constraints: const BoxConstraints(),
                                onPressed: () {
                                  setDialogState(() {
                                    pickedPdfs.removeAt(idx);
                                  });
                                },
                              ),
                            ],
                          ),
                        );
                      }),
                      const SizedBox(height: 4),
                    ],

                    // ── Кнопка выбора PDF ──
                    ElevatedButton.icon(
                      onPressed: () async {
                        final result = await FilePicker.platform.pickFiles(
                          type: FileType.custom,
                          allowedExtensions: const ['pdf'],
                          allowMultiple: true,
                          withData: true,
                        );
                        if (result != null && result.files.isNotEmpty) {
                          setDialogState(() {
                            pickedPdfs.addAll(result.files);
                          });
                        }
                      },
                      icon: const Icon(Icons.upload_file),
                      label: const Text('Добавить PDF'),
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
                    final extraInfo = extraInfoCtl.text.trim();
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
                    String formId = '';
                    if (isEditing) {
                      formId = row?['id']?.toString() ?? '';
                      if (formId.isNotEmpty) {
                        await wp.updateForm(
                          id: formId,
                          series: name,
                          number: number,
                          formSize: size.isNotEmpty ? size : null,
                          formProductType: typeVal.isNotEmpty ? typeVal : null,
                          formColors: colors.isNotEmpty ? colors : null,
                          description: extraInfo.isNotEmpty ? extraInfo : '',
                        );
                      }
                    } else {
                      final created = await wp.createFormAndReturn(
                        series: name,
                        number: number,
                        formSize: size.isNotEmpty ? size : null,
                        formProductType: typeVal.isNotEmpty ? typeVal : null,
                        formColors: colors.isNotEmpty ? colors : null,
                        description: extraInfo.isNotEmpty ? extraInfo : '',
                      );
                      formId = (created['id'] ?? '').toString();
                    }
                    // Загрузка выбранных PDF после сохранения формы.
                    if (formId.isNotEmpty && pickedPdfs.isNotEmpty) {
                      for (final pdf in pickedPdfs) {
                        try {
                          await storage.uploadPickedFormPdf(
                              formId: formId, file: pdf);
                        } catch (e) {
                          if (mounted) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(
                                  content:
                                      Text('Ошибка загрузки ${pdf.name}: $e')),
                            );
                          }
                        }
                      }
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

  Future<String?> _promptDisableComment({
    required String formName,
    String? initialComment,
  }) async {
    final controller = TextEditingController(text: initialComment ?? '');
    String? errorText;

    final result = await showDialog<String?>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (context, setDialogState) {
            return AlertDialog(
              title: const Text('Форма отключена'),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Укажите причину отключения формы $formName'),
                  const SizedBox(height: 12),
                  TextField(
                    controller: controller,
                    autofocus: true,
                    maxLines: 3,
                    decoration: InputDecoration(
                      labelText: 'Комментарий',
                      border: const OutlineInputBorder(),
                      errorText: errorText,
                    ),
                  ),
                ],
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(ctx, null),
                  child: const Text('Отмена'),
                ),
                ElevatedButton(
                  onPressed: () {
                    final value = controller.text.trim();
                    if (value.isEmpty) {
                      setDialogState(() {
                        errorText = 'Комментарий обязателен';
                      });
                      return;
                    }
                    Navigator.pop(ctx, value);
                  },
                  child: const Text('Сохранить'),
                ),
              ],
            );
          },
        );
      },
    );

    controller.dispose();
    return result;
  }

  Future<void> _handleToggleForm(
    Map<String, dynamic> row,
    bool newValue,
    String formLabel,
  ) async {
    final previousEnabledRaw = row['is_enabled'];
    bool previousEnabled;
    if (previousEnabledRaw is bool) {
      previousEnabled = previousEnabledRaw;
    } else {
      final status = (row['status'] ?? '').toString();
      previousEnabled = status != 'disabled';
    }
    final previousComment =
        (row['disabled_comment'] ?? row['disable_comment'] ?? '').toString();
    final previousStatus = (row['status'] ?? '').toString();
    final id = (row['id'] ?? '').toString();

    if (id.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('Не удалось определить форму для изменения статуса'),
      ));
      setState(() {
        row['is_enabled'] = previousEnabled;
        row['disabled_comment'] = previousComment;
        row['status'] = previousStatus;
      });
      return;
    }

    final wp = context.read<WarehouseProvider>();

    if (!newValue) {
      final comment = await _promptDisableComment(
        formName: formLabel,
        initialComment: previousComment,
      );

      if (!mounted) return;

      if (comment == null) {
        setState(() {
          row['is_enabled'] = previousEnabled;
          row['disabled_comment'] = previousComment;
          row['status'] = previousStatus;
        });
        return;
      }

      try {
        await wp.updateForm(
          id: id,
          isEnabled: false,
          disabledComment: comment,
          status: 'disabled',
        );
        if (!mounted) return;
        setState(() {
          row['is_enabled'] = false;
          row['disabled_comment'] = comment;
          row['status'] = 'disabled';
        });
        final search = _searchCtl.text.trim();
        _reload(search: search.isEmpty ? null : search);
      } catch (e) {
        if (!mounted) return;
        setState(() {
          row['is_enabled'] = previousEnabled;
          row['disabled_comment'] = previousComment;
          row['status'] = previousStatus;
        });
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('Не удалось отключить форму: $e'),
        ));
      }
    } else {
      try {
        final nextStatus =
            previousStatus == 'disabled' || previousStatus.isEmpty
                ? 'in_stock'
                : previousStatus;
        await wp.updateForm(
          id: id,
          isEnabled: true,
          disabledComment: null,
          status: nextStatus,
        );
        if (!mounted) return;
        setState(() {
          row['is_enabled'] = true;
          row['disabled_comment'] = null;
          row['status'] = nextStatus;
        });
        final search = _searchCtl.text.trim();
        _reload(search: search.isEmpty ? null : search);
      } catch (e) {
        if (!mounted) return;
        setState(() {
          row['is_enabled'] = previousEnabled;
          row['disabled_comment'] = previousComment;
          row['status'] = previousStatus;
        });
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('Не удалось включить форму: $e'),
        ));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Формы — склад')),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
            child: Column(
              children: [
                TextField(
                  controller: _searchCtl,
                  decoration: const InputDecoration(
                    hintText: 'Поиск формы (название, номер, доп. инфо)',
                    prefixIcon: Icon(Icons.search),
                    border: OutlineInputBorder(),
                  ),
                  onChanged: (v) =>
                      _reload(search: v.trim().isEmpty ? null : v.trim()),
                ),
                const SizedBox(height: 8),
                DropdownButtonFormField<FormsSort>(
                  value: _sort,
                  decoration: const InputDecoration(
                    labelText: 'Сортировка',
                    border: OutlineInputBorder(),
                  ),
                  items: const [
                    DropdownMenuItem(
                        value: FormsSort.numberDesc,
                        child: Text('Нумерация: с конца')),
                    DropdownMenuItem(
                        value: FormsSort.numberAsc,
                        child: Text('Нумерация: с начала')),
                    DropdownMenuItem(
                        value: FormsSort.seriesAsc,
                        child: Text('Алфавит: А → Я')),
                    DropdownMenuItem(
                        value: FormsSort.seriesDesc,
                        child: Text('Алфавит: Я → А')),
                  ],
                  onChanged: (value) {
                    if (value == null) return;
                    setState(() {
                      _sort = value;
                    });
                  },
                ),
              ],
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

                int compareSeries(
                    Map<String, dynamic> a, Map<String, dynamic> b) {
                  final sa = (a['series'] ?? '').toString();
                  final sb = (b['series'] ?? '').toString();
                  return sa.compareTo(sb);
                }

                int compareNumber(
                    Map<String, dynamic> a, Map<String, dynamic> b) {
                  final na = (a['number'] as num?)?.toInt() ?? 0;
                  final nb = (b['number'] as num?)?.toInt() ?? 0;
                  return na.compareTo(nb);
                }

                switch (_sort) {
                  case FormsSort.numberDesc:
                    // Нумерация с конца: глобальная сортировка по номеру от большего к
                    // меньшему.
                    data.sort((a, b) => compareNumber(b, a));
                    break;
                  case FormsSort.numberAsc:
                    // Нумерация с начала: глобальная сортировка по номеру от 1 вверх.
                    data.sort(compareNumber);
                    break;
                  case FormsSort.seriesAsc:
                    // Алфавит: А → Я, при совпадении названия — по номеру.
                    data.sort((a, b) {
                      final seriesCmp = compareSeries(a, b);
                      if (seriesCmp != 0) return seriesCmp;
                      return compareNumber(a, b);
                    });
                    break;
                  case FormsSort.seriesDesc:
                    // Алфавит: Я → А, при совпадении названия — по номеру.
                    data.sort((a, b) {
                      final seriesCmp = compareSeries(b, a);
                      if (seriesCmp != 0) return seriesCmp;
                      return compareNumber(b, a);
                    });
                    break;
                }

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

                    final sizeStr =
                        _cleanSizeLabel((row['size'] ?? '').toString());
                    final typeStr = (row['product_type'] ?? '').toString();
                    final colorsStr = (row['colors'] ?? '').toString();
                    final extraInfoStr = (row['description'] ?? '').toString();
                    final subtitleParts = <String>[];
                    if (sizeStr.isNotEmpty)
                      subtitleParts.add('Размер: $sizeStr');
                    if (typeStr.isNotEmpty) subtitleParts.add('Тип: $typeStr');
                    if (colorsStr.isNotEmpty)
                      subtitleParts.add('Цвета: $colorsStr');
                    if (extraInfoStr.isNotEmpty) {
                      subtitleParts.add('Доп. инфо: $extraInfoStr');
                    }
                    final subtitleText = subtitleParts.isEmpty
                        ? null
                        : subtitleParts.join('  |  ');

                    final status = (row['status'] ?? '').toString();
                    final bool isEnabled = row['is_enabled'] is bool
                        ? row['is_enabled'] as bool
                        : status != 'disabled';
                    final disabledComment = (row['disabled_comment'] ??
                            row['disable_comment'] ??
                            '')
                        .toString()
                        .trim();

                    return ListTile(
                      onTap: () => _showFormDialog(row: row),
                      tileColor:
                          isEnabled ? null : Colors.red.withOpacity(0.12),
                      isThreeLine: !isEnabled &&
                          disabledComment.isNotEmpty &&
                          subtitleText != null,
                      leading: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          // Визуальный порядковый номер строки: пересчитывается
                          // при поиске и смене сортировки (не путать с полем
                          // «Нумерация» самой формы).
                          SizedBox(
                            width: 32,
                            child: Text(
                              '${i + 1}',
                              textAlign: TextAlign.right,
                              style: TextStyle(
                                fontSize: 12,
                                color: Colors.grey.shade600,
                              ),
                            ),
                          ),
                          const SizedBox(width: 8),
                          CircleAvatar(
                            child: Text(
                              series.isEmpty ? '?' : series.substring(0, 1),
                            ),
                          ),
                        ],
                      ),
                      title: Text(
                        nameNumber,
                        style: isEnabled
                            ? null
                            : TextStyle(
                                color: Colors.red.shade700,
                                fontWeight: FontWeight.w600,
                              ),
                      ),
                      subtitle: (subtitleText == null &&
                              (isEnabled || disabledComment.isEmpty))
                          ? null
                          : Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                if (subtitleText != null)
                                  Text(
                                    subtitleText,
                                    style: isEnabled
                                        ? null
                                        : TextStyle(
                                            color: Colors.red.shade700,
                                          ),
                                  ),
                                if (!isEnabled && disabledComment.isNotEmpty)
                                  Align(
                                    alignment: Alignment.centerRight,
                                    child: Text(
                                      disabledComment,
                                      textAlign: TextAlign.end,
                                      style: TextStyle(
                                        color: Colors.red.shade700,
                                        fontSize: 12,
                                      ),
                                      maxLines: 3,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                  ),
                              ],
                            ),
                      trailing: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          IconButton(
                            tooltip: 'Изменить',
                            icon: const Icon(Icons.edit_outlined),
                            onPressed: () => _showFormDialog(row: row),
                          ),
                          const SizedBox(width: 8),
                          Switch(
                            value: isEnabled,
                            onChanged: (value) => unawaited(
                              _handleToggleForm(row, value, nameNumber),
                            ),
                          ),
                        ],
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
