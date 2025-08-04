import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'personnel_provider.dart';
import 'position_model.dart';
import 'employee_model.dart';

/// Экран для отображения и управления списком сотрудников.
class EmployeesScreen extends StatelessWidget {
  const EmployeesScreen({super.key});

  void _openAddDialog(BuildContext context) {
    showDialog(
      context: context,
      builder: (_) => const _AddEmployeeDialog(),
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
                final fullName = '${emp.lastName} ${emp.firstName} ${emp.patronymic}'.trim();
                final positionNames = emp.positionIds
                    .map((id) => positionsById[id] ?? '')
                    .where((s) => s.isNotEmpty)
                    .join(', ');
                // Вычислить инициалы для аватара
                final initials = (emp.lastName.isNotEmpty
                        ? emp.lastName[0]
                        : '') +
                    (emp.firstName.isNotEmpty ? emp.firstName[0] : '');
                return Card(
                  margin: const EdgeInsets.symmetric(horizontal: 12),
                  elevation: 1,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                    side: BorderSide(color: emp.isFired ? Colors.red.shade200 : Colors.grey.shade300),
                  ),
                  child: ListTile(
                    leading: CircleAvatar(
                      backgroundColor: Colors.blueGrey.shade100,
                      backgroundImage:
                          emp.photoUrl != null && emp.photoUrl!.isNotEmpty ? NetworkImage(emp.photoUrl!) : null,
                      child: (emp.photoUrl == null || emp.photoUrl!.isEmpty)
                          ? Text(
                              initials.toUpperCase(),
                              style: const TextStyle(fontSize: 12, color: Colors.black87),
                            )
                          : null,
                    ),
                    title: Text(
                      fullName.isEmpty ? 'Без имени' : fullName,
                      style: TextStyle(
                        fontWeight: FontWeight.w600,
                        color: emp.isFired ? Colors.grey : Colors.black,
                      ),
                    ),
                    subtitle: Text(
                      positionNames.isEmpty ? 'Нет должностей' : positionNames,
                      style: TextStyle(
                        fontStyle: positionNames.isEmpty ? FontStyle.italic : FontStyle.normal,
                        color: emp.isFired ? Colors.grey : Colors.black54,
                      ),
                    ),
                    trailing: emp.isFired
                        ? const Icon(Icons.block, color: Colors.red)
                        : null,
                  ),
                );
              },
            ),
    );
  }
}

/// Диалог для добавления нового сотрудника.
class _AddEmployeeDialog extends StatefulWidget {
  const _AddEmployeeDialog();

  @override
  State<_AddEmployeeDialog> createState() => _AddEmployeeDialogState();
}

class _AddEmployeeDialogState extends State<_AddEmployeeDialog> {
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

  void _togglePosition(String id, bool selected) {
    setState(() {
      if (selected) {
        _selectedPositions.add(id);
      } else {
        _selectedPositions.remove(id);
      }
    });
  }

  void _submit(BuildContext context) {
    if (!_formKey.currentState!.validate()) return;
    final provider = Provider.of<PersonnelProvider>(context, listen: false);
    provider.addEmployee(
      lastName: _lastName.text.trim(),
      firstName: _firstName.text.trim(),
      patronymic: _patronymic.text.trim(),
      iin: _iin.text.trim(),
      photoUrl: _photoUrl.text.trim().isEmpty ? null : _photoUrl.text.trim(),
      positionIds: _selectedPositions.toList(),
      isFired: _isFired,
      comments: _comments.text.trim(),
      login: _login.text.trim(),
      password: _password.text.trim(),
    );
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final provider = Provider.of<PersonnelProvider>(context);
    final positions = provider.positions;
    return AlertDialog(
      title: const Text('Добавить сотрудника'),
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
                validator: (value) {
                  if (value == null || value.trim().isEmpty) {
                    return 'Введите фамилию';
                  }
                  return null;
                },
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
                keyboardType: TextInputType.number,
                validator: (value) {
                  if (value == null || value.trim().isEmpty) {
                    return 'Введите ИИН';
                  }
                  return null;
                },
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
              // Поле для URL фотографии
              TextFormField(
                controller: _photoUrl,
                decoration: const InputDecoration(
                  labelText: 'Ссылка на фото (URL)',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 6),
              // Выбор должностей
              Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  'Должности',
                  style: TextStyle(fontWeight: FontWeight.w600, color: Colors.grey[700]),
                ),
              ),
              const SizedBox(height: 4),
              Wrap(
                spacing: 4,
                runSpacing: 4,
                children: positions.map((pos) {
                  final selected = _selectedPositions.contains(pos.id);
                  return FilterChip(
                    label: Text(pos.name),
                    selected: selected,
                    onSelected: (val) => _togglePosition(pos.id, val),
                    selectedColor: Theme.of(context).colorScheme.primary.withOpacity(0.2),
                  );
                }).toList(),
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
                minLines: 1,
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