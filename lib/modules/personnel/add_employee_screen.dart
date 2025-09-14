import 'dart:io';
import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:uuid/uuid.dart';
import 'package:image_picker/image_picker.dart';
import 'package:file_picker/file_picker.dart';
import '../../services/doc_db.dart';

class AddEmployeeScreen extends StatefulWidget {
  const AddEmployeeScreen({super.key});

  @override
  State<AddEmployeeScreen> createState() => _AddEmployeeScreenState();
}

class _AddEmployeeScreenState extends State<AddEmployeeScreen> {
  final _lastNameController = TextEditingController();
  final _firstNameController = TextEditingController();
  final _patronymicController = TextEditingController();
  final _iinController = TextEditingController();
  final _commentsController = TextEditingController();
  final _loginController = TextEditingController();
  final _passwordController = TextEditingController();
  List<String> _positionIds = [];

  File? _selectedImage;
  bool _isSaving = false;
  
  /// Показывает выбор источника изображения: камера, галерея или файл.
  Future<void> _showImageSourceDialog() async {
    await showModalBottomSheet(
      context: context,
      builder: (context) {
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                leading: const Icon(Icons.camera_alt),
                title: const Text('Сделать фото'),
                onTap: () {
                  Navigator.pop(context);
                  _pickFromCamera();
                },
              ),
              ListTile(
                leading: const Icon(Icons.photo),
                title: const Text('Выбрать из галереи'),
                onTap: () {
                  Navigator.pop(context);
                  _pickFromGallery();
                },
              ),
              ListTile(
                leading: const Icon(Icons.insert_drive_file),
                title: const Text('Выбрать файл'),
                onTap: () {
                  Navigator.pop(context);
                  _pickFromFiles();
                },
              ),
            ],
          ),
        );
      },
    );
  }

  Future<void> _pickFromCamera() async {
    final picker = ImagePicker();
    final picked = await picker.pickImage(source: ImageSource.camera);
    if (picked != null) {
      setState(() {
        _selectedImage = File(picked.path);
      });
    }
  }

  Future<void> _pickFromGallery() async {
    final picker = ImagePicker();
    final picked = await picker.pickImage(source: ImageSource.gallery);
    if (picked != null) {
      setState(() {
        _selectedImage = File(picked.path);
      });
    }
  }

  Future<void> _pickFromFiles() async {
    final result = await FilePicker.platform.pickFiles(type: FileType.image);
    if (result != null && result.files.single.path != null) {
      setState(() {
        _selectedImage = File(result.files.single.path!);
      });
    }
  }

  Future<void> _saveEmployee() async {
    final lastName = _lastNameController.text.trim();
    final firstName = _firstNameController.text.trim();
    final patronymic = _patronymicController.text.trim();
    final iin = _iinController.text.trim();
    final comments = _commentsController.text.trim();
    final login = _loginController.text.trim();
    final password = _passwordController.text.trim();

    if (lastName.isEmpty ||
        firstName.isEmpty ||
        iin.isEmpty ||
        login.isEmpty ||
        password.isEmpty ||
        _selectedImage == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Заполните все обязательные поля, логин/пароль и выберите фото')),
      );
      return;
    }

    setState(() {
      _isSaving = true;
    });

    try {
      final client = Supabase.instance.client;
      final id = const Uuid().v4();

      final filePath = 'employee_photos/$id.jpg';
      await client.storage
          .from('employee_photos')
          .upload(filePath, _selectedImage!);
      final photoUrl =
          client.storage.from('employee_photos').getPublicUrl(filePath);

      final docDb = DocDB();
      await docDb.insert(
        'employees',
        {
          'lastName': lastName,
          'firstName': firstName,
          'patronymic': patronymic,
          'iin': iin,
          'photoUrl': photoUrl,
          'positionIds': _positionIds,
          'isFired': false,
          'comments': comments,
          'login': login,
          'password': password,
        },
        explicitId: id,
      );
      await docDb.insert('workspaces', {
        'employee_id': id,
        'tasks': [],
      });

      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Сотрудник успешно добавлен')),
      );
      Navigator.pop(context);
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Ошибка при сохранении: $e')),
      );
    } finally {
      setState(() {
        _isSaving = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Добавить сотрудника')),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            GestureDetector(
              onTap: _showImageSourceDialog,
              child: _selectedImage != null
                  ? CircleAvatar(radius: 50, backgroundImage: FileImage(_selectedImage!))
                  : const CircleAvatar(radius: 50, child: Icon(Icons.camera_alt)),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _lastNameController,
              decoration: const InputDecoration(labelText: 'Фамилия *'),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: _firstNameController,
              decoration: const InputDecoration(labelText: 'Имя *'),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: _patronymicController,
              decoration: const InputDecoration(labelText: 'Отчество'),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: _iinController,
              decoration: const InputDecoration(labelText: 'ИИН *'),
              keyboardType: TextInputType.number,
            ),
            const SizedBox(height: 10),
            TextField(
              controller: _loginController,
              decoration: const InputDecoration(labelText: 'Логин *'),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: _passwordController,
              decoration: const InputDecoration(labelText: 'Пароль *'),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: _commentsController,
              decoration: const InputDecoration(labelText: 'Комментарии'),
            ),
            const SizedBox(height: 20),
            _isSaving
                ? const CircularProgressIndicator()
                : ElevatedButton(
                    onPressed: _saveEmployee,
                    child: const Text('Сохранить'),
                  ),
          ],
        ),
      ),
    );
  }
}
