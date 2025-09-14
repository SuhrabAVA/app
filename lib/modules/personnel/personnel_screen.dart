import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'personnel_provider.dart';
import 'positions_screen.dart';
import 'employees_screen.dart';
import 'workplaces_screen.dart';
import 'terminals_screen.dart';

class PersonnelScreen extends StatelessWidget {
  const PersonnelScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Управление персоналом')),
      body: Padding(
        padding: const EdgeInsets.all(12.0),
        child: GridView.count(
          crossAxisCount: 2,
          crossAxisSpacing: 12,
          mainAxisSpacing: 12,
          childAspectRatio: 1.1,
          children: [
            _buildModuleCard(
              context,
              title: 'Сотрудники',
              page: const EmployeesScreen(),
              color: const Color(0xFFFFF59D),
              icon: Icons.people,
            ),
            _buildModuleCard(
              context,
              title: 'Должности',
              page: const PositionsScreen(),
              color: const Color(0xFFC5E1A5),
              icon: Icons.badge,
            ),
            _buildModuleCard(
              context,
              title: 'Рабочие места',
              page: const WorkplacesScreen(),
              color: const Color(0xFFB39DDB),
              icon: Icons.home_work_outlined,
            ),
            _buildModuleCard(
              context,
              title: 'Терминалы',
              page: const TerminalsScreen(),
              color: const Color(0xFF81D4FA),
              icon: Icons.computer_outlined,
            ),
          ],
        ),
      ),
    );
  }

  /// Строит карточку для перехода к модулю. Каждая карточка имеет
  /// собственный цвет фона и иконку, чтобы сделать интерфейс
  /// разнообразнее и приятнее.
  Widget _buildModuleCard(
    BuildContext context, {
    required String title,
    required Widget page,
    required Color color,
    required IconData icon,
  }) {
    return Material(
      color: Colors.transparent,
      borderRadius: BorderRadius.circular(16),
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: () {
          // Просто открываем соответствующий экран. Провайдер доступен глобально.
          Navigator.push(
            context,
            MaterialPageRoute(builder: (_) => page),
          );
        },
        child: Container(
          decoration: BoxDecoration(
            color: color.withOpacity(0.3),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: color.withOpacity(0.6)),
            boxShadow: [
              BoxShadow(
                color: color.withOpacity(0.2),
                blurRadius: 6,
                offset: const Offset(0, 3),
              ),
            ],
          ),
          padding: const EdgeInsets.all(12),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(icon, size: 40, color: color.darken(0.3)),
              const SizedBox(height: 8),
              Text(
                title,
                textAlign: TextAlign.center,
                style: const TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

extension on Color {
  /// Возвращает более тёмный оттенок цвета. Используется для
  /// иконок на цветных карточках.
  Color darken([double amount = .1]) {
    assert(amount >= 0 && amount <= 1);
    final hsl = HSLColor.fromColor(this);
    final darkened = hsl.withLightness((hsl.lightness - amount).clamp(0.0, 1.0));
    return darkened.toColor();
  }
}
