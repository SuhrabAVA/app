import 'package:flutter/material.dart';

/// Visual tokens used only by the employee workspace and task screens.
///
/// The application intentionally keeps a very small global [ThemeData]. These
/// tokens therefore live next to the feature instead of changing the look of
/// unrelated administration, warehouse, and planning screens.
abstract final class WorkspaceColors {
  static const background = Color(0xFFF2F2F7);
  static const surface = Colors.white;
  static const foreground = Color(0xFF111118);
  static const mutedForeground = Color(0xFF717182);
  static const border = Color(0x1A000000);
  static const primary = Color(0xFF6A6CF7);
  static const disabledForeground = Color(0xFFA6A6B2);

  static const setup = Color(0xFF5856D6);
  static const setupBackground = Color(0xFFF0EEFF);
  static const success = Color(0xFF34C759);
  static const successBackground = Color(0xFFE8FAF0);
  static const blue = Color(0xFF007AFF);
  static const blueBackground = Color(0xFFE8F4FF);
  static const warning = Color(0xFFFF9500);
  static const warningBackground = Color(0xFFFFF8E1);
  static const danger = Color(0xFFFF3B30);
  static const secondaryBackground = Color(0xFFF2F2F7);
}

abstract final class WorkspaceMetrics {
  static const outerPadding = 16.0;
  static const columnGap = 12.0;
  static const cardRadius = 16.0;
  static const controlGap = 8.0;
  static const headerActionSize = 48.0;
}

BoxDecoration workspaceCardDecoration({
  Color color = WorkspaceColors.surface,
  double radius = WorkspaceMetrics.cardRadius,
  bool withBorder = true,
}) {
  return BoxDecoration(
    color: color,
    borderRadius: BorderRadius.circular(radius),
    border: withBorder ? Border.all(color: WorkspaceColors.border) : null,
    boxShadow: const [
      BoxShadow(
        color: Color(0x12000000),
        blurRadius: 10,
        offset: Offset(0, 2),
      ),
    ],
  );
}

class WorkspaceHeaderAction extends StatelessWidget {
  const WorkspaceHeaderAction({
    super.key,
    required this.icon,
    required this.tooltip,
    required this.onPressed,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: Material(
        color: WorkspaceColors.surface,
        borderRadius: BorderRadius.circular(13),
        elevation: 0,
        child: InkWell(
          onTap: onPressed,
          borderRadius: BorderRadius.circular(13),
          hoverColor: WorkspaceColors.primary.withValues(alpha: 0.06),
          focusColor: WorkspaceColors.primary.withValues(alpha: 0.08),
          child: Container(
            width: WorkspaceMetrics.headerActionSize,
            height: WorkspaceMetrics.headerActionSize,
            decoration: workspaceCardDecoration(radius: 13),
            alignment: Alignment.center,
            child: Icon(icon, size: 25, color: WorkspaceColors.foreground),
          ),
        ),
      ),
    );
  }
}

class WorkspaceActionButton extends StatelessWidget {
  const WorkspaceActionButton({
    super.key,
    required this.icon,
    required this.label,
    required this.accentColor,
    required this.backgroundColor,
    required this.onPressed,
    this.primary = false,
  });

  final IconData icon;
  final String label;
  final Color accentColor;
  final Color backgroundColor;
  final VoidCallback? onPressed;
  final bool primary;

  @override
  Widget build(BuildContext context) {
    final enabled = onPressed != null;
    final foreground =
        enabled ? accentColor : WorkspaceColors.disabledForeground;
    final fill = enabled
        ? backgroundColor
        : Color.alphaBlend(
            Colors.white.withValues(alpha: 0.42),
            backgroundColor,
          );

    return Semantics(
      button: true,
      enabled: enabled,
      label: label,
      child: Material(
        color: fill,
        borderRadius: BorderRadius.circular(13),
        child: InkWell(
          onTap: onPressed,
          borderRadius: BorderRadius.circular(13),
          hoverColor: accentColor.withValues(alpha: 0.07),
          focusColor: accentColor.withValues(alpha: 0.1),
          child: SizedBox(
            height: primary ? 88 : 50,
            child: primary
                ? Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(icon, size: 25, color: foreground),
                      const SizedBox(height: 6),
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 6),
                        child: Text(
                          label,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            color: foreground,
                            fontSize: 14,
                            height: 1.08,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    ],
                  )
                : Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(icon, size: 20, color: foreground),
                      const SizedBox(width: 8),
                      Flexible(
                        child: Text(
                          label,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: enabled
                                ? WorkspaceColors.foreground
                                : WorkspaceColors.disabledForeground,
                            fontSize: 14,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ),
                    ],
                  ),
          ),
        ),
      ),
    );
  }
}

class WorkspaceSectionHeading extends StatelessWidget {
  const WorkspaceSectionHeading({
    super.key,
    required this.title,
    required this.icon,
    required this.accentColor,
    required this.iconBackground,
  });

  final String title;
  final IconData icon;
  final Color accentColor;
  final Color iconBackground;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Container(
          width: 22,
          height: 22,
          decoration: BoxDecoration(
            color: iconBackground,
            borderRadius: BorderRadius.circular(6),
          ),
          alignment: Alignment.center,
          child: Icon(icon, size: 13, color: accentColor),
        ),
        const SizedBox(width: 7),
        Expanded(
          child: Text(
            title.toUpperCase(),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: accentColor,
              fontSize: 9.5,
              height: 1.1,
              fontWeight: FontWeight.w700,
              letterSpacing: 1.35,
            ),
          ),
        ),
      ],
    );
  }
}

class WorkspaceEmptyState extends StatelessWidget {
  const WorkspaceEmptyState({
    super.key,
    required this.icon,
    required this.title,
    required this.message,
  });

  final IconData icon;
  final String title;
  final String message;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 48, color: WorkspaceColors.mutedForeground),
            const SizedBox(height: 12),
            Text(
              title,
              textAlign: TextAlign.center,
              style: const TextStyle(
                color: WorkspaceColors.foreground,
                fontSize: 16,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              message,
              textAlign: TextAlign.center,
              style: const TextStyle(
                color: WorkspaceColors.mutedForeground,
                fontSize: 13,
                height: 1.35,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
