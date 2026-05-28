import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../utils/analytics_colors.dart';

/// Базовая оболочка экрана аналитики: тёмный фон с градиентом
/// и контейнер с максимальной шириной (1600px), как в HTML-прототипе.
///
/// ВАЖНО: дочернему виджету передаются tight-constraints
/// (заданная высота из `constraints.maxHeight`), иначе вложенный Scaffold
/// или Column с Expanded не смогут провести layout.
class AnalyticsShell extends StatelessWidget {
  const AnalyticsShell({
    super.key,
    required this.child,
    this.appBar,
    this.endDrawer,
    this.scaffoldKey,
  });

  final Widget child;
  final PreferredSizeWidget? appBar;
  final Widget? endDrawer;
  final Key? scaffoldKey;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      key: scaffoldKey,
      backgroundColor: AnalyticsColors.bg,
      appBar: appBar,
      endDrawer: endDrawer,
      body: Container(
        decoration: const BoxDecoration(gradient: AnalyticsColors.appBgGradient),
        child: SafeArea(
          child: LayoutBuilder(
            builder: (context, constraints) {
              final maxW = constraints.maxWidth.isFinite
                  ? math.min(constraints.maxWidth, 1600.0)
                  : 1600.0;
              final h = constraints.maxHeight.isFinite
                  ? constraints.maxHeight
                  : MediaQuery.of(context).size.height;
              return Align(
                alignment: Alignment.topCenter,
                child: SizedBox(
                  width: maxW,
                  height: h,
                  child: child,
                ),
              );
            },
          ),
        ),
      ),
    );
  }
}

class AnalyticsCard extends StatelessWidget {
  const AnalyticsCard({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(18),
    this.title,
    this.subtitle,
    this.trailing,
  });

  final Widget child;
  final EdgeInsetsGeometry padding;
  final String? title;
  final String? subtitle;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: AnalyticsColors.card,
        borderRadius: BorderRadius.circular(22),
        border: Border.all(color: AnalyticsColors.line),
        boxShadow: const [
          BoxShadow(
            color: Color(0x52000000),
            blurRadius: 42,
            offset: Offset(0, 12),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (title != null || trailing != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(18, 16, 12, 14),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        if (title != null)
                          Text(title!,
                              style: const TextStyle(
                                color: AnalyticsColors.text,
                                fontWeight: FontWeight.w800,
                                fontSize: 18,
                              )),
                        if (subtitle != null) ...[
                          const SizedBox(height: 4),
                          Text(subtitle!,
                              style: const TextStyle(
                                color: AnalyticsColors.muted,
                                fontSize: 12,
                              )),
                        ],
                      ],
                    ),
                  ),
                  if (trailing != null) trailing!,
                ],
              ),
            ),
          if (title != null || trailing != null)
            const Divider(height: 1, color: AnalyticsColors.line),
          Padding(padding: padding, child: child),
        ],
      ),
    );
  }
}

class AnalyticsKpiCard extends StatelessWidget {
  const AnalyticsKpiCard({
    super.key,
    required this.label,
    required this.value,
    this.sub,
    this.icon,
  });

  final String label;
  final String value;
  final String? sub;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: AnalyticsColors.card,
        borderRadius: BorderRadius.circular(22),
        border: Border.all(color: AnalyticsColors.line),
      ),
      child: Stack(
        children: [
          Positioned(
            right: -20,
            bottom: -35,
            child: Container(
              width: 90,
              height: 90,
              decoration: const BoxDecoration(
                shape: BoxShape.circle,
                color: Color(0x2238BDF8),
              ),
            ),
          ),
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  if (icon != null) ...[
                    Icon(icon, size: 16, color: AnalyticsColors.blue),
                    const SizedBox(width: 6),
                  ],
                  Expanded(
                    child: Text(
                      label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                          color: AnalyticsColors.muted, fontSize: 13),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Text(
                value,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: AnalyticsColors.text,
                  fontWeight: FontWeight.w900,
                  fontSize: 26,
                ),
              ),
              if (sub != null) ...[
                const SizedBox(height: 4),
                Text(
                  sub!,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                      color: AnalyticsColors.muted2, fontSize: 12),
                ),
              ],
            ],
          ),
        ],
      ),
    );
  }
}
