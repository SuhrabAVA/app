import 'package:flutter/material.dart';
import 'templates_screen.dart';

/// Placeholder screen for Production Planning.
/// This simple screen forwards to TemplatesScreen for now.
class ProductionPlanningScreen extends StatelessWidget {
  const ProductionPlanningScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return const TemplatesScreen();
  }
}