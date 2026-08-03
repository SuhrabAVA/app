import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:open_filex/open_filex.dart';

import '../services/error_log_service.dart';

/// Глобальный ключ навигатора приложения — нужен оверлею,
/// чтобы открывать экран ошибок поверх любого экрана.
final GlobalKey<NavigatorState> appNavigatorKey = GlobalKey<NavigatorState>();

/// Обёртка для MaterialApp.builder: рисует поверх приложения
/// плавающую кнопку со счётчиком ошибок (только при kShowErrorOverlay).
class ErrorOverlayHost extends StatelessWidget {
  const ErrorOverlayHost({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    if (!kShowErrorOverlay) {
      return child;
    }
    return Stack(
      textDirection: TextDirection.ltr,
      children: [
        child,
        const _ErrorOverlayButton(),
      ],
    );
  }
}

class _ErrorOverlayButton extends StatefulWidget {
  const _ErrorOverlayButton();

  @override
  State<_ErrorOverlayButton> createState() => _ErrorOverlayButtonState();
}

class _ErrorOverlayButtonState extends State<_ErrorOverlayButton> {
  static const double _size = 46;
  Offset? _offset;
  bool _screenOpen = false;

  Offset _clamp(Offset raw, Size screen) {
    return Offset(
      raw.dx.clamp(0.0, screen.width - _size),
      raw.dy.clamp(0.0, screen.height - _size),
    );
  }

  void _openLogScreen() {
    if (_screenOpen) {
      return;
    }
    final nav = appNavigatorKey.currentState;
    if (nav == null) {
      return;
    }
    _screenOpen = true;
    ErrorLogService.instance.markAllSeen();
    nav
        .push(MaterialPageRoute<void>(
          builder: (_) => const ErrorLogScreen(),
          settings: const RouteSettings(name: '/debug-error-log'),
        ))
        .whenComplete(() => _screenOpen = false);
  }

  @override
  Widget build(BuildContext context) {
    final screen = MediaQuery.of(context).size;
    final service = ErrorLogService.instance;
    final offset = _clamp(
      _offset ?? Offset(screen.width - _size - 8, screen.height * 0.6),
      screen,
    );

    return Positioned(
      left: offset.dx,
      top: offset.dy,
      child: AnimatedBuilder(
        animation: Listenable.merge([service.revision, service.unseenCount]),
        builder: (context, _) {
          final total = service.entries.length;
          final hasNew = service.unseenCount.value > 0;
          return GestureDetector(
            onPanUpdate: (details) {
              setState(() {
                _offset = _clamp(offset + details.delta, screen);
              });
            },
            child: Material(
              type: MaterialType.circle,
              elevation: 4,
              color: hasNew
                  ? Colors.red.shade600
                  : Colors.blueGrey.withValues(alpha: 0.7),
              child: InkWell(
                customBorder: const CircleBorder(),
                onTap: _openLogScreen,
                child: SizedBox(
                  width: _size,
                  height: _size,
                  child: Stack(
                    alignment: Alignment.center,
                    children: [
                      const Icon(Icons.bug_report,
                          color: Colors.white, size: 22),
                      if (total > 0)
                        Positioned(
                          right: 4,
                          top: 4,
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 4, vertical: 1),
                            decoration: BoxDecoration(
                              color: Colors.white,
                              borderRadius: BorderRadius.circular(8),
                            ),
                            child: Text(
                              total > 99 ? '99+' : '$total',
                              style: TextStyle(
                                fontSize: 9,
                                fontWeight: FontWeight.bold,
                                color: hasNew
                                    ? Colors.red.shade700
                                    : Colors.blueGrey.shade800,
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}

/// Экран со списком всех ошибок за сессию.
class ErrorLogScreen extends StatelessWidget {
  const ErrorLogScreen({super.key});

  static String _time(DateTime t) {
    String two(int v) => v.toString().padLeft(2, '0');
    return '${two(t.hour)}:${two(t.minute)}:${two(t.second)}';
  }

  void _snack(BuildContext context, String message) {
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _copyAll(BuildContext context) async {
    final service = ErrorLogService.instance;
    await Clipboard.setData(ClipboardData(text: service.formatAll()));
    if (context.mounted) {
      _snack(context, 'Скопировано: ${service.entries.length} ошибок');
    }
  }

  void _showLogFileDialog(BuildContext context) {
    final path = ErrorLogService.instance.logFilePath;
    showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Файл лога ошибок'),
        content: SelectableText(
          path ?? 'Файл ещё не инициализирован.',
          style: const TextStyle(fontSize: 13),
        ),
        actions: [
          if (path != null)
            TextButton(
              onPressed: () async {
                await Clipboard.setData(ClipboardData(text: path));
                if (dialogContext.mounted) {
                  Navigator.of(dialogContext).pop();
                  _snack(context, 'Путь скопирован');
                }
              },
              child: const Text('Копировать путь'),
            ),
          if (path != null)
            TextButton(
              onPressed: () async {
                Navigator.of(dialogContext).pop();
                final result = await OpenFilex.open(path);
                if (result.type != ResultType.done && context.mounted) {
                  _snack(context, 'Не удалось открыть: ${result.message}');
                }
              },
              child: const Text('Открыть файл'),
            ),
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('Закрыть'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final service = ErrorLogService.instance;
    return AnimatedBuilder(
      animation: service.revision,
      builder: (context, _) {
        final items = service.entries.reversed.toList();
        return Scaffold(
          appBar: AppBar(
            title: Text('Ошибки за сессию (${items.length})'),
            actions: [
              IconButton(
                tooltip: 'Копировать всё',
                icon: const Icon(Icons.copy_all),
                onPressed:
                    items.isEmpty ? null : () => _copyAll(context),
              ),
              IconButton(
                tooltip: 'Файл лога',
                icon: const Icon(Icons.description_outlined),
                onPressed: () => _showLogFileDialog(context),
              ),
              IconButton(
                tooltip: 'Очистить список',
                icon: const Icon(Icons.delete_outline),
                onPressed: items.isEmpty ? null : service.clear,
              ),
            ],
          ),
          body: items.isEmpty
              ? const Center(child: Text('Ошибок за сессию нет'))
              : ListView.separated(
                  itemCount: items.length,
                  separatorBuilder: (_, __) => const Divider(height: 1),
                  itemBuilder: (context, index) =>
                      _ErrorEntryTile(entry: items[index]),
                ),
        );
      },
    );
  }
}

class _ErrorEntryTile extends StatelessWidget {
  const _ErrorEntryTile({required this.entry});

  final AppErrorEntry entry;

  @override
  Widget build(BuildContext context) {
    final ctx = entry.context;
    return ExpansionTile(
      dense: true,
      tilePadding: const EdgeInsets.symmetric(horizontal: 12),
      childrenPadding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
      title: Text(
        entry.message,
        maxLines: 3,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(fontSize: 13),
      ),
      subtitle: Text(
        '${ErrorLogScreen._time(entry.time)}  •  ${entry.source}'
        '${ctx != null && ctx.isNotEmpty ? '  •  $ctx' : ''}',
        style: TextStyle(fontSize: 11, color: Colors.grey.shade600),
      ),
      children: [
        Align(
          alignment: Alignment.centerLeft,
          child: SelectableText(
            entry.format(),
            style: const TextStyle(fontSize: 11, fontFamily: 'monospace'),
          ),
        ),
        Align(
          alignment: Alignment.centerRight,
          child: TextButton.icon(
            icon: const Icon(Icons.copy, size: 16),
            label: const Text('Копировать'),
            onPressed: () async {
              await Clipboard.setData(ClipboardData(text: entry.format()));
              if (context.mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('Ошибка скопирована')),
                );
              }
            },
          ),
        ),
      ],
    );
  }
}
