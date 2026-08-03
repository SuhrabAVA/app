import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

/// Регресс на краш «Пауза»:
/// `[ZONE] Null check operator used on a null value` →
/// `Provider.of (provider.dart:327)` → `onPause ... <asynchronous suspension>`.
///
/// Тест воспроизводит паттерн обработчика из `buildControlsFor`
/// (`tasks_screen.dart`): строка кнопок размонтируется, пока открыт диалог
/// причины паузы. Сам `TasksScreen` поднять в тесте нельзя — его провайдеры
/// в конструкторах обращаются к `Supabase.instance`, поэтому здесь
/// зафиксирован именно паттерн, который был причиной падения.
class FakeTaskProvider extends ChangeNotifier {
  int calls = 0;

  void addCommentAutoUser() => calls += 1;
}

Future<String?> _askComment(BuildContext context) {
  return showDialog<String>(
    context: context,
    builder: (ctx) => AlertDialog(
      content: const Text('Причина паузы'),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(ctx).pop('устал'),
          child: const Text('OK'),
        ),
      ],
    ),
  );
}

/// Как было: `context.read` живёт ЗА первым `await`, проверки `mounted` нет.
///
/// Важная деталь: обработчик замыкает контекст ВЛОЖЕННОГО `Builder`, ровно как
/// `buildControlsFor` в `tasks_screen.dart`. Именно defunct-элемент `Builder`
/// давал в проде `Null check operator used on a null value` внутри
/// `Provider.of` — контекст самого `State` бросил бы другую ошибку.
class BrokenRow extends StatefulWidget {
  const BrokenRow({super.key, required this.onError});

  final void Function(Object error) onError;

  @override
  State<BrokenRow> createState() => _BrokenRowState();
}

class _BrokenRowState extends State<BrokenRow> {
  @override
  Widget build(BuildContext _) {
    return Builder(
      builder: (context) {
        Future<void> onPause() async {
          try {
            await _askComment(context);
            context.read<FakeTaskProvider>().addCommentAutoUser();
          } catch (error) {
            widget.onError(error);
          }
        }

        return ElevatedButton(
            onPressed: onPause, child: const Text('Пауза'));
      },
    );
  }
}

/// Как стало: провайдер захвачен ДО первого `await`, после диалога — `mounted`.
class FixedRow extends StatefulWidget {
  const FixedRow({super.key, required this.onError});

  final void Function(Object error) onError;

  @override
  State<FixedRow> createState() => _FixedRowState();
}

class _FixedRowState extends State<FixedRow> {
  @override
  Widget build(BuildContext _) {
    return Builder(
      builder: (context) {
        final tp = context.read<FakeTaskProvider>();

        Future<void> onPause() async {
          try {
            final comment = await _askComment(context);
            if (!mounted) return;
            if (comment == null) return;
            tp.addCommentAutoUser();
          } catch (error) {
            widget.onError(error);
          }
        }

        return ElevatedButton(
            onPressed: onPause, child: const Text('Пауза'));
      },
    );
  }
}

void main() {
  late FakeTaskProvider provider;
  late List<Object> errors;
  late StateSetter setHostState;
  var showRow = true;

  Future<void> pumpHost(WidgetTester tester, Widget Function() rowBuilder) {
    showRow = true;
    return tester.pumpWidget(
      ChangeNotifierProvider<FakeTaskProvider>.value(
        value: provider,
        child: MaterialApp(
          home: Scaffold(
            body: StatefulBuilder(
              builder: (context, setState) {
                setHostState = setState;
                return Column(
                  children: [if (showRow) rowBuilder()],
                );
              },
            ),
          ),
        ),
      ),
    );
  }

  setUp(() {
    provider = FakeTaskProvider();
    errors = <Object>[];
    showRow = true;
  });

  testWidgets(
      'старый паттерн: размонтирование во время диалога роняет context.read',
      (tester) async {
    await pumpHost(tester, () => BrokenRow(onError: errors.add));

    await tester.tap(find.text('Пауза'));
    await tester.pumpAndSettle();
    expect(find.text('Причина паузы'), findsOneWidget);

    // Экран пересобрался (realtime / поллинг очередей) и строка исчезла.
    setHostState(() => showRow = false);
    await tester.pump();
    expect(find.byType(BrokenRow), findsNothing);

    await tester.tap(find.text('OK'));
    await tester.pumpAndSettle();

    expect(errors, hasLength(1),
        reason: 'без фикса обращение к context после await падает');
    // Текст различается по режиму сборки: в debug первым срабатывает assert
    // Flutter «Looking up a deactivated widget's ancestor is unsafe», в release
    // (планшет) assert вырезан и падает `!` внутри Provider.of —
    // «Null check operator used on a null value» из журнала. Причина одна и та
    // же, поэтому проверяем факт исключения, а не формулировку.
    expect(
      errors.single.toString(),
      anyOf(
        contains('deactivated widget'),
        contains('Null check operator'),
      ),
    );
    expect(provider.calls, 0);
  });

  testWidgets(
      'новый паттерн: обработчик завершается без исключения и не трогает провайдер',
      (tester) async {
    await pumpHost(tester, () => FixedRow(onError: errors.add));

    await tester.tap(find.text('Пауза'));
    await tester.pumpAndSettle();
    expect(find.text('Причина паузы'), findsOneWidget);

    setHostState(() => showRow = false);
    await tester.pump();
    expect(find.byType(FixedRow), findsNothing);

    await tester.tap(find.text('OK'));
    await tester.pumpAndSettle();

    expect(errors, isEmpty);
    expect(provider.calls, 0,
        reason: 'после размонтирования запись делать не нужно');
  });

  testWidgets('новый паттерн: без размонтирования запись выполняется',
      (tester) async {
    await pumpHost(tester, () => FixedRow(onError: errors.add));

    await tester.tap(find.text('Пауза'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('OK'));
    await tester.pumpAndSettle();

    expect(errors, isEmpty);
    expect(provider.calls, 1);
  });
}
