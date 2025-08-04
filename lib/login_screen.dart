import 'package:flutter/material.dart';
import 'package:firebase_database/firebase_database.dart';
import 'admin_panel.dart';
import 'modules/personnel/employee_workspace_screen.dart';

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _loginController = TextEditingController();
  final _passwordController = TextEditingController();
  String? _error;

  Future<void> _attemptLogin() async {
    const correctLogin = 'Расул';
    const correctPassword = '123123';
    if (_loginController.text == correctLogin &&
        _passwordController.text == correctPassword) {
      Navigator.pushReplacement(
        context,
        MaterialPageRoute(builder: (_) => const AdminPanelScreen()),
      );
      return;
    }

    final snapshot = await FirebaseDatabase.instance.ref('employees').get();
    if (snapshot.exists) {
      final employees =
          Map<String, dynamic>.from(snapshot.value as Map<dynamic, dynamic>);
      for (final entry in employees.entries) {
        final data = Map<String, dynamic>.from(entry.value as Map);
        if (data['login'] == _loginController.text &&
            data['password'] == _passwordController.text) {
          Navigator.pushReplacement(
            context,
            MaterialPageRoute(
              builder: (_) => EmployeeWorkspaceScreen(employeeId: entry.key),
            ),
          );
          return;
        }
      }
    }

    setState(() {
      _error = 'Неверный логин или пароль';
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: _loginController,
                decoration: const InputDecoration(labelText: 'Логин'),
              ),
              TextField(
                controller: _passwordController,
                decoration: const InputDecoration(labelText: 'Пароль'),
                obscureText: true,
              ),
              const SizedBox(height: 20),
              ElevatedButton(
                onPressed: _attemptLogin,
                child: const Text('Войти'),
              ),
              if (_error != null) ...[
                const SizedBox(height: 20),
                Text(
                  _error!,
                  style: const TextStyle(color: Colors.red),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}