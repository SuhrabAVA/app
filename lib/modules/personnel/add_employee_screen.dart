import 'dart:io';
import 'package:flutter/material.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:image_picker/image_picker.dart';

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
  List<String> _positionIds = [];

  File? _selectedImage;
  bool _isSaving = false;

  Future<void> _pickImage() async {
    final picker = ImagePicker();
    final picked = await picker.pickImage(source: ImageSource.gallery);
    if (picked != null) {
      setState(() {
        _selectedImage = File(picked.path);
      });
    }
  }

  Future<void> _saveEmployee() async {
    final lastName = _lastNameController.text.trim();
    final firstName = _firstNameController.text.trim();
    final patronymic = _patronymicController.text.trim();
    final iin = _iinController.text.trim();
    final comments = _commentsController.text.trim();

    if (lastName.isEmpty || firstName.isEmpty || iin.isEmpty || _selectedImage == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Заполните все обязательные поля и выберите фото')),
      );
      return;
    }

    setState(() {
      _isSaving = true;
    });

    try {
      final photoRef = FirebaseStorage.instance
          .ref('employee_photos')
          .child('${DateTime.now().millisecondsSinceEpoch}.jpg');

      await photoRef.putFile(_selectedImage!);
      final photoUrl = await photoRef.getDownloadURL();

      final dbRef = FirebaseDatabase.instance.ref('employees').push();

      await dbRef.set({
        'lastName': lastName,
        'firstName': firstName,
        'patronymic': patronymic,
        'iin': iin,
        'photoUrl': photoUrl,
        'positionIds': _positionIds,
        'isFired': false,
        'comments': comments,
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
              onTap: _pickImage,
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
