import 'dart:io' show File, Platform;
import 'dart:typed_data';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:image_picker/image_picker.dart';
import 'package:file_picker/file_picker.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:uuid/uuid.dart';

import 'personnel_provider.dart';
import 'employee_model.dart';
import 'positions_picker.dart';
import '../../utils/media_viewer.dart';

/// === Supabase helpers ===

const String _bucket = 'employee_photos';

/// Пытаемся обеспечить сессию (анонимный логин должен быть включён в Supabase → Auth → Providers → Anonymous)
Future<void> ensureAuthed() async {
  final auth = Supabase.instance.client.auth;
  if (auth.currentUser == null) {
    try {
      await auth.signInAnonymously();
    } catch (_) {
      // если анонимный вход не разрешён — продолжим; ошибка всплывёт при uploadBinary и покажется пользователю
    }
  }
}

/// Экран для отображения и управления списком сотрудников.
class EmployeesScreen extends StatelessWidget {
  const EmployeesScreen({super.key});

  void _openAddDialog(BuildContext context) {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => const _EmployeeDialog(),
    );
  }

  void _openEditDialog(BuildContext context, EmployeeModel employee) {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => _EmployeeDialog(employee: employee),
    );
  }

  @override
  Widget build(BuildContext context) {
    final provider = Provider.of<PersonnelProvider>(context);
    final employees = provider.employees;
    final positionsById = {for (var p in provider.positions) p.id: p.name};
    return Scaffold(
      appBar: AppBar(
        title: const Text('Сотрудники'),
        actions: [
          IconButton(
            icon: const Icon(Icons.add),
            onPressed: () => _openAddDialog(context),
          ),
        ],
      ),
      body: employees.isEmpty
          ? const Center(child: Text('Список сотрудников пуст'))
          : ListView.separated(
              itemCount: employees.length,
              separatorBuilder: (_, __) => const SizedBox(height: 4),
              itemBuilder: (context, index) {
                final emp = employees[index];
                final fullName =
                    '${emp.lastName} ${emp.firstName} ${emp.patronymic}'.trim();
                final positionNames = emp.positionIds
                    .map((id) => positionsById[id] ?? '')
                    .where((s) => s.isNotEmpty)
                    .join(', ');
                final initials =
                    (emp.lastName.isNotEmpty ? emp.lastName[0] : '') +
                        (emp.firstName.isNotEmpty ? emp.firstName[0] : '');
                final photoUrl = emp.photoUrl ?? '';
                final displayName = fullName.isEmpty ? 'Сотрудник' : fullName;

                Widget avatar = CircleAvatar(
                  backgroundColor: Colors.blueGrey.shade100,
                  backgroundImage:
                      (photoUrl.isNotEmpty) ? NetworkImage(photoUrl) : null,
                  child: (photoUrl.isEmpty)
                      ? Text(
                          initials.toUpperCase(),
                          style: const TextStyle(
                              fontWeight: FontWeight.w600, fontSize: 16),
                        )
                      : null,
                );

                if (photoUrl.isNotEmpty) {
                  avatar = GestureDetector(
                    onTap: () => showImagePreview(
                      context,
                      imageUrl: photoUrl,
                      title: displayName,
                    ),
                    child: avatar,
                  );
                }

                return Card(
                  margin: const EdgeInsets.symmetric(horizontal: 12),
                  elevation: 1,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                    side: BorderSide(
                      color: emp.isFired
                          ? Colors.red.shade200
                          : Colors.grey.shade300,
                    ),
                  ),
                  child: ListTile(
                    onTap: () => _openEditDialog(context, emp),
                    leading: avatar,
                    title: Text(
                      displayName,
                      style: TextStyle(
                        fontWeight: FontWeight.w600,
                        color: emp.isFired ? Colors.grey : Colors.black,
                      ),
                    ),
                    subtitle: Text(
                      positionNames.isEmpty ? 'Нет должностей' : positionNames,
                      style: TextStyle(
                        fontStyle: positionNames.isEmpty
                            ? FontStyle.italic
                            : FontStyle.normal,
                        color: emp.isFired ? Colors.grey : Colors.black54,
                      ),
                    ),
                    trailing: emp.isFired
                        ? const Icon(Icons.block, color: Colors.red)
                        : const Icon(Icons.edit, color: Colors.grey),
                  ),
                );
              },
            ),
    );
  }
}

/// Диалог для добавления или редактирования сотрудника.
class _EmployeeDialog extends StatefulWidget {
  final EmployeeModel? employee;
  const _EmployeeDialog({this.employee});

  @override
  State<_EmployeeDialog> createState() => _EmployeeDialogState();
}

class _EmployeeDialogState extends State<_EmployeeDialog> {
  final _formKey = GlobalKey<FormState>();
  final TextEditingController _lastName = TextEditingController();
  final TextEditingController _firstName = TextEditingController();
  final TextEditingController _patronymic = TextEditingController();
  final TextEditingController _iin = TextEditingController();
  final TextEditingController _photoUrl = TextEditingController();
  final TextEditingController _comments = TextEditingController();
  final TextEditingController _login = TextEditingController();
  final TextEditingController _password = TextEditingController();
  bool _isFired = false;
  final Set<String> _selectedPositions = {};
  bool _isUploading = false;

  @override
  void initState() {
    super.initState();
    final emp = widget.employee;
    if (emp != null) {
      _lastName.text = emp.lastName;
      _firstName.text = emp.firstName;
      _patronymic.text = emp.patronymic;
      _iin.text = emp.iin;
      if (emp.photoUrl != null) _photoUrl.text = emp.photoUrl!;
      _comments.text = emp.comments;
      _isFired = emp.isFired;
      _selectedPositions.addAll(emp.positionIds);
      _login.text = emp.login;
      _password.text = emp.password;
    } else {
      _isFired = false;
    }
  }

  @override
  void dispose() {
    _lastName.dispose();
    _firstName.dispose();
    _patronymic.dispose();
    _iin.dispose();
    _photoUrl.dispose();
    _comments.dispose();
    _login.dispose();
    _password.dispose();
    super.dispose();
  }

  void _submit(BuildContext context) async {
    if (!_formKey.currentState!.validate()) return;
    final provider = Provider.of<PersonnelProvider>(context, listen: false);
    final photo = _photoUrl.text.trim().isEmpty ? null : _photoUrl.text.trim();

    if (widget.employee == null) {
      await provider.addEmployee(
        lastName: _lastName.text.trim(),
        firstName: _firstName.text.trim(),
        patronymic: _patronymic.text.trim(),
        iin: _iin.text.trim(),
        photoUrl: photo,
        positionIds: _selectedPositions.toList(),
        isFired: _isFired,
        comments: _comments.text.trim(),
        login: _login.text.trim(),
        password: _password.text.trim(),
      );
    } else {
      await provider.updateEmployee(
        id: widget.employee!.id,
        lastName: _lastName.text.trim(),
        firstName: _firstName.text.trim(),
        patronymic: _patronymic.text.trim(),
        iin: _iin.text.trim(),
        photoUrl: photo,
        positionIds: _selectedPositions.toList(),
        isFired: _isFired,
        comments: _comments.text.trim(),
        login: _login.text.trim(),
        password: _password.text.trim(),
      );
    }

    if (!mounted) return;
    Navigator.of(context).pop();
  }

  // ---------- Photo helpers ----------

  Future<void> _pickFromFilesOrGallery() async {
    try {
      setState(() => _isUploading = true);

      final res = await FilePicker.platform.pickFiles(
        type: FileType.image,
        allowMultiple: false,
        withData: true,
      );
      if (res == null || res.files.isEmpty) {
        setState(() => _isUploading = false);
        return;
      }
      final f = res.files.single;
      final Uint8List? bytes = f.bytes;
      if (bytes == null) {
        // Фоллбек: читаем с диска, если есть путь
        if (f.path == null) {
          setState(() => _isUploading = false);
          return;
        }
        final file = File(f.path!);
        final Uint8List b = await file.readAsBytes();
        await _uploadBytesAndSetUrl(b, f.name);
      } else {
        await _uploadBytesAndSetUrl(bytes, f.name);
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Ошибка выбора файла: $e')));
      }
    } finally {
      if (mounted) setState(() => _isUploading = false);
    }
  }

  Future<void> _takePhotoFromCamera() async {
    if (kIsWeb || !(Platform.isAndroid || Platform.isIOS)) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
            content: Text('Съёмка с камеры доступна на Android/iOS')),
      );
      return;
    }
    try {
      setState(() => _isUploading = true);
      final ImagePicker picker = ImagePicker();
      final XFile? x = await picker.pickImage(
        source: ImageSource.camera,
        preferredCameraDevice: CameraDevice.front,
        maxWidth: 2048,
        maxHeight: 2048,
        imageQuality: 85,
      );
      if (x == null) return;
      final Uint8List bytes = await x.readAsBytes();
      await _uploadBytesAndSetUrl(bytes, x.name);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Ошибка камеры: $e')));
      }
    } finally {
      if (mounted) setState(() => _isUploading = false);
    }
  }

  Future<void> _uploadBytesAndSetUrl(
    Uint8List bytes,
    String originalFileName,
  ) async {
    final client = Supabase.instance.client;

    // гарантируем сессию (если включён Anonymous provider)
    await ensureAuthed();

    final uuid = const Uuid().v4();
    final ext = _extOf(originalFileName);
    final fileName = '${DateTime.now().millisecondsSinceEpoch}_$uuid$ext';
    final objectPath = 'employees/$fileName';

    final fileOptions = FileOptions(
      cacheControl: '3600',
      upsert: true,
      contentType: _guessContentType(ext),
    );

    try {
      await client.storage
          .from(_bucket)
          .uploadBinary(objectPath, bytes, fileOptions: fileOptions);

      final url = client.storage.from(_bucket).getPublicUrl(objectPath);
      setState(() {
        _photoUrl.text = url;
      });

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Фото загружено')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              'Не удалось загрузить фото: $e\n'
              'Проверьте: вход выполнен (Auth) и политики Storage для бакета $_bucket.',
            ),
          ),
        );
      }
    }
  }

  String _extOf(String name) {
    final i = name.lastIndexOf('.');
    if (i < 0) return '.jpg';
    final ext = name.substring(i);
    if (ext.isEmpty) return '.jpg';
    return ext.toLowerCase();
  }

  String _guessContentType(String ext) {
    switch (ext.toLowerCase()) {
      case '.png':
        return 'image/png';
      case '.webp':
        return 'image/webp';
      case '.gif':
        return 'image/gif';
      case '.bmp':
        return 'image/bmp';
      case '.heic':
      case '.heif':
        return 'image/heic';
      default:
        return 'image/jpeg';
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.employee == null
          ? 'Добавить сотрудника'
          : 'Редактировать сотрудника'),
      content: SingleChildScrollView(
        child: Form(
          key: _formKey,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextFormField(
                controller: _lastName,
                decoration: const InputDecoration(
                  labelText: 'Фамилия',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 6),
              TextFormField(
                controller: _firstName,
                decoration: const InputDecoration(
                  labelText: 'Имя',
                  border: OutlineInputBorder(),
                ),
                validator: (value) {
                  if (value == null || value.trim().isEmpty) {
                    return 'Введите имя';
                  }
                  return null;
                },
              ),
              const SizedBox(height: 6),
              TextFormField(
                controller: _patronymic,
                decoration: const InputDecoration(
                  labelText: 'Отчество',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 6),
              TextFormField(
                controller: _iin,
                decoration: const InputDecoration(
                  labelText: 'ИИН',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 6),

              // --- Фото сотрудника ---
              Row(
                children: [
                  Expanded(
                    child: TextFormField(
                      controller: _photoUrl,
                      readOnly: true,
                      decoration: const InputDecoration(
                        labelText: 'Фото сотрудника',
                        hintText: 'Выберите файл или сделайте снимок',
                        border: OutlineInputBorder(),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Tooltip(
                    message: 'Выбрать из проводника/галереи',
                    child: IconButton(
                      icon: const Icon(Icons.folder_open),
                      onPressed: _isUploading ? null : _pickFromFilesOrGallery,
                    ),
                  ),
                  Tooltip(
                    message: 'Сделать фото (камера)',
                    child: IconButton(
                      icon: const Icon(Icons.photo_camera),
                      onPressed: _isUploading ? null : _takePhotoFromCamera,
                    ),
                  ),
                  if (_isUploading) ...[
                    const SizedBox(width: 8),
                    const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                  ]
                ],
              ),

              const SizedBox(height: 6),
              TextFormField(
                controller: _login,
                decoration: const InputDecoration(
                  labelText: 'Логин',
                  border: OutlineInputBorder(),
                ),
                validator: (value) {
                  if (value == null || value.trim().isEmpty) {
                    return 'Введите логин';
                  }
                  return null;
                },
              ),
              const SizedBox(height: 6),
              TextFormField(
                controller: _password,
                obscureText: true,
                decoration: const InputDecoration(
                  labelText: 'Пароль',
                  border: OutlineInputBorder(),
                ),
                validator: (value) {
                  if (value == null || value.trim().isEmpty) {
                    return 'Введите пароль';
                  }
                  return null;
                },
              ),
              const SizedBox(height: 6),

              // Выбор должностей
              Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  'Должности',
                  style: TextStyle(
                      fontWeight: FontWeight.w600, color: Colors.grey[700]),
                ),
              ),
              const SizedBox(height: 4),
              ManagerAwarePositionsPicker(
                value: _selectedPositions.toList(),
                onChanged: (ids) {
                  setState(() {
                    _selectedPositions
                      ..clear()
                      ..addAll(ids);
                  });
                },
              ),

              // Признак уволен
              SwitchListTile(
                value: _isFired,
                onChanged: (val) => setState(() => _isFired = val),
                title: const Text('Уволен'),
              ),

              TextFormField(
                controller: _comments,
                decoration: const InputDecoration(
                  labelText: 'Комментарии',
                  border: OutlineInputBorder(),
                ),
                minLines: 2,
                maxLines: 3,
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Отмена'),
        ),
        ElevatedButton(
          onPressed: () => _submit(context),
          child: const Text('Сохранить'),
        ),
      ],
    );
  }
}
