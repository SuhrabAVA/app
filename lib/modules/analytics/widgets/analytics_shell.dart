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

/// Группа фильтра `.filter-group`: подпись сверху, контрол снизу.
class AnalyticsFilterGroup extends StatelessWidget {
  const AnalyticsFilterGroup({
    super.key,
    required this.label,
    required this.child,
    this.minWidth = 220,
  });

  final String label;
  final Widget child;
  final double minWidth;

  @override
  Widget build(BuildContext context) {
    return ConstrainedBox(
      constraints: BoxConstraints(minWidth: minWidth),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label,
              style: const TextStyle(
                  color: AnalyticsColors.muted, fontSize: 12)),
          const SizedBox(height: 8),
          child,
        ],
      ),
    );
  }
}

/// Поле-обёртка для контролов (`input`/`select`) из эталона: тёмный фон,
/// скругление 14, граница line, высота 42.
class AnalyticsInputShell extends StatelessWidget {
  const AnalyticsInputShell({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 42,
      padding: const EdgeInsets.symmetric(horizontal: 13),
      decoration: BoxDecoration(
        color: const Color(0xB3020617),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AnalyticsColors.line),
      ),
      alignment: Alignment.centerLeft,
      child: child,
    );
  }
}

/// Шапка карточки `.card-header`: заголовок + сабтайтл слева, действия справа.
class AnalyticsCardHeader extends StatelessWidget {
  const AnalyticsCardHeader({
    super.key,
    required this.title,
    this.subtitle,
    this.trailing,
  });

  final String title;
  final String? subtitle;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(18, 16, 14, 14),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title,
                    style: const TextStyle(
                      color: AnalyticsColors.text,
                      fontWeight: FontWeight.w900,
                      fontSize: 18,
                    )),
                if (subtitle != null) ...[
                  const SizedBox(height: 5),
                  Text(subtitle!,
                      style: const TextStyle(
                        color: AnalyticsColors.muted,
                        fontSize: 13,
                      )),
                ],
              ],
            ),
          ),
          if (trailing != null) ...[
            const SizedBox(width: 14),
            trailing!,
          ],
        ],
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

/// Двухколоночный detail-layout из эталона: `grid-template-columns: 1fr 360px`.
/// На узких окнах (< [breakpoint]) сворачивается в один столбец, а боковая
/// панель уезжает вниз — как `@media (max-width: 1180px)` в CSS.
class AnalyticsDetailLayout extends StatelessWidget {
  const AnalyticsDetailLayout({
    super.key,
    required this.main,
    this.side,
    this.sideWidth = 360,
    this.gap = 18,
    this.breakpoint = 1120,
  });

  final Widget main;
  final Widget? side;
  final double sideWidth;
  final double gap;
  final double breakpoint;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final wide =
            side != null && constraints.maxWidth >= breakpoint;
        if (!wide) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              main,
              if (side != null) ...[SizedBox(height: gap), side!],
            ],
          );
        }
        return Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(child: main),
            SizedBox(width: gap),
            SizedBox(width: sideWidth, child: side),
          ],
        );
      },
    );
  }
}

/// Карточка сводки (`.summary-card` / `.detail-card`). При [green] получает
/// зелёную подсветку как `.green-summary` в эталоне.
class AnalyticsSummaryCard extends StatelessWidget {
  const AnalyticsSummaryCard({
    super.key,
    required this.title,
    required this.children,
    this.subtitle,
    this.green = false,
    this.padding = const EdgeInsets.all(18),
  });

  final String title;
  final String? subtitle;
  final List<Widget> children;
  final bool green;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: padding,
      decoration: BoxDecoration(
        color: AnalyticsColors.card,
        borderRadius: BorderRadius.circular(22),
        border: Border.all(
          color: green
              ? const Color(0x5222C55E)
              : AnalyticsColors.line,
        ),
        gradient: green
            ? const LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [Color(0x2E22C55E), Color(0x1438BDF8)],
              )
            : null,
        boxShadow: const [
          BoxShadow(
            color: Color(0x29000000),
            blurRadius: 42,
            offset: Offset(0, 12),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(title,
              style: const TextStyle(
                color: AnalyticsColors.text,
                fontWeight: FontWeight.w900,
                fontSize: 18,
              )),
          if (subtitle != null) ...[
            const SizedBox(height: 6),
            Text(subtitle!,
                style: const TextStyle(
                    color: AnalyticsColors.muted, fontSize: 12)),
          ],
          const SizedBox(height: 14),
          ...children,
        ],
      ),
    );
  }
}

/// Строка `.stat-row`: подпись слева, значение справа.
class AnalyticsStatRow extends StatelessWidget {
  const AnalyticsStatRow({super.key, required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Text(label,
                style:
                    const TextStyle(color: AnalyticsColors.muted, fontSize: 13)),
          ),
          const SizedBox(width: 12),
          Text(value,
              textAlign: TextAlign.right,
              style: const TextStyle(
                color: AnalyticsColors.text,
                fontWeight: FontWeight.w800,
                fontSize: 13,
              )),
        ],
      ),
    );
  }
}

/// Зелёный итоговый блок `.total-box`.
class AnalyticsTotalBox extends StatelessWidget {
  const AnalyticsTotalBox({
    super.key,
    required this.label,
    required this.value,
    this.note,
  });

  final String label;
  final String value;
  final String? note;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(top: 14),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(20),
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFF86EFAC), Color(0xFF22C55E)],
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label,
              style: const TextStyle(
                color: Color(0xFF052E16),
                fontWeight: FontWeight.w800,
                fontSize: 13,
              )),
          const SizedBox(height: 7),
          Text(value,
              style: const TextStyle(
                color: Color(0xFF052E16),
                fontWeight: FontWeight.w900,
                fontSize: 30,
                letterSpacing: -1,
              )),
          if (note != null) ...[
            const SizedBox(height: 5),
            Text(note!,
                style: const TextStyle(
                  color: Color(0xC7052E16),
                  fontSize: 11,
                )),
          ],
        ],
      ),
    );
  }
}

/// «← Назад» в стиле `.back-link` (синяя плоская ссылка).
class AnalyticsBackLink extends StatelessWidget {
  const AnalyticsBackLink({super.key, required this.label, required this.onTap});

  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return TextButton(
      onPressed: onTap,
      style: TextButton.styleFrom(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
        minimumSize: Size.zero,
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        foregroundColor: AnalyticsColors.blue,
      ),
      child: Text('← $label',
          style: const TextStyle(
            color: AnalyticsColors.blue,
            fontWeight: FontWeight.w800,
            fontSize: 13,
          )),
    );
  }
}

/// Зелёная кнопка экспорта PDF (`.pdf-button` из эталона).
class AnalyticsPdfButton extends StatelessWidget {
  const AnalyticsPdfButton({
    super.key,
    required this.loading,
    required this.onPressed,
  });

  final bool loading;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return TextButton.icon(
      onPressed: loading ? null : onPressed,
      style: TextButton.styleFrom(
        minimumSize: const Size(0, 42),
        padding: const EdgeInsets.symmetric(horizontal: 18),
        foregroundColor: const Color(0xFFBBF7D0),
        backgroundColor: const Color(0x1F22C55E),
        side: const BorderSide(color: Color(0x5922C55E)),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(999),
        ),
      ),
      icon: loading
          ? const SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                color: Color(0xFFBBF7D0),
              ),
            )
          : const Icon(Icons.picture_as_pdf_outlined, size: 18),
      label: Text(loading ? 'Создаём PDF…' : 'Скачать PDF'),
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
            children: [
              Row(
                children: [
                  if (icon != null) ...[
                    Icon(icon, size: 16, color: AnalyticsColors.blue),
                    const SizedBox(width: 6),
                  ],
                  Text(label,
                      style: const TextStyle(
                          color: AnalyticsColors.muted, fontSize: 13)),
                ],
              ),
              const SizedBox(height: 8),
              Text(value,
                  style: const TextStyle(
                    color: AnalyticsColors.text,
                    fontWeight: FontWeight.w900,
                    fontSize: 26,
                  )),
              if (sub != null) ...[
                const SizedBox(height: 4),
                Text(sub!,
                    style: const TextStyle(
                        color: AnalyticsColors.muted2, fontSize: 12)),
              ],
            ],
          ),
        ],
      ),
    );
  }
}
