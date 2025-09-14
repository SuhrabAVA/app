
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

class EnterKeyBehavior extends StatelessWidget {
  final Widget child;
  final VoidCallback? onSubmit; // optional global submit (Ctrl+Enter)
  const EnterKeyBehavior({super.key, required this.child, this.onSubmit});

  @override
  Widget build(BuildContext context) {
    return Shortcuts(
      shortcuts: <LogicalKeySet, Intent>{
        // ENTER moves focus forward, SHIFT+ENTER moves back
        LogicalKeySet(LogicalKeyboardKey.enter):
            const NextFocusIntent(),
        LogicalKeySet(LogicalKeyboardKey.shift, LogicalKeyboardKey.enter):
            const PreviousFocusIntent(),
        // CTRL+ENTER triggers an Activate (e.g., default button) or custom submit
        LogicalKeySet(LogicalKeyboardKey.control, LogicalKeyboardKey.enter):
            const ActivateIntent(),
      },
      child: Actions(
        actions: <Type, Action<Intent>>{
          ActivateIntent: CallbackAction<ActivateIntent>(
            onInvoke: (intent) {
              if (onSubmit != null) onSubmit!();
              // Fallback to default if any focused control handles it
              return null;
            },
          ),
        },
        child: FocusTraversalGroup(
          policy: OrderedTraversalPolicy(),
          child: Focus(
            autofocus: true,
            child: child,
          ),
        ),
      ),
    );
  }
}
