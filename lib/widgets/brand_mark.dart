import 'package:flutter/material.dart';

/// Логотип «Easy Pack Pro» на экранах приложения.
///
/// Круглый знак — тот же файл, из которого собраны иконки Windows и Android
/// (`scripts/generate_app_icons.ps1`), поэтому иконка на рабочем столе и
/// логотип на экранах запуска и входа не могут разъехаться. Надпись рядом
/// набирается текстом, а не картинкой: на разных размерах и плотностях
/// экрана она остаётся резкой.
abstract final class BrandColors {
  /// Синий логотипа (взят пипеткой из самого файла).
  static const primary = Color(0xFF0057FF);

  /// Тёмно-синий надписи «Easy Pack».
  static const wordmark = Color(0xFF0E1B3D);

  static const muted = Color(0xFF717182);
}

const String kBrandName = 'Easy Pack Pro';
const String kBrandLogoAsset = 'assets/branding/app_icon.png';

/// Круглый знак заданного размера.
class BrandMark extends StatelessWidget {
  const BrandMark({super.key, this.size = 64});

  final double size;

  @override
  Widget build(BuildContext context) {
    return Image.asset(
      kBrandLogoAsset,
      width: size,
      height: size,
      // Исходник 256×256; на экране запуска знак крупнее, поэтому просим
      // фильтрацию — без неё края логотипа выглядят ступенчатыми.
      filterQuality: FilterQuality.high,
      fit: BoxFit.contain,
    );
  }
}

/// Полный логотип: «Easy Pack» + плашка «PRO» + круглый знак.
///
/// [height] задаёт размер круглого знака, остальное считается от него —
/// блок нельзя рассинхронизировать по пропорциям. На узких экранах
/// ужимается целиком, а не переносится по словам.
class BrandLockup extends StatelessWidget {
  const BrandLockup({super.key, this.height = 64});

  final double height;

  @override
  Widget build(BuildContext context) {
    final nameSize = height * 0.58;

    return FittedBox(
      fit: BoxFit.scaleDown,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Text(
            'Easy Pack',
            style: TextStyle(
              fontSize: nameSize,
              height: 1.0,
              fontWeight: FontWeight.w800,
              letterSpacing: -nameSize * 0.02,
              color: BrandColors.wordmark,
            ),
          ),
          SizedBox(width: height * 0.11),
          Container(
            padding: EdgeInsets.symmetric(
              horizontal: height * 0.13,
              vertical: height * 0.055,
            ),
            decoration: BoxDecoration(
              color: BrandColors.primary,
              borderRadius: BorderRadius.circular(height * 0.16),
            ),
            child: Text(
              'PRO',
              style: TextStyle(
                fontSize: nameSize * 0.52,
                height: 1.0,
                fontWeight: FontWeight.w800,
                letterSpacing: nameSize * 0.01,
                color: Colors.white,
              ),
            ),
          ),
          SizedBox(width: height * 0.22),
          BrandMark(size: height),
        ],
      ),
    );
  }
}

/// Логотип с появлением — для экрана запуска: всплывает и слегка
/// увеличивается. Индикатора загрузки рядом намеренно нет.
class AnimatedBrandLockup extends StatefulWidget {
  const AnimatedBrandLockup({super.key, this.height = 96});

  final double height;

  @override
  State<AnimatedBrandLockup> createState() => _AnimatedBrandLockupState();
}

class _AnimatedBrandLockupState extends State<AnimatedBrandLockup>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 700),
  )..forward();

  late final Animation<double> _scale = CurvedAnimation(
    parent: _controller,
    curve: Curves.easeOutBack,
  );
  late final Animation<double> _fade = CurvedAnimation(
    parent: _controller,
    curve: const Interval(0, 0.6, curve: Curves.easeOut),
  );

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FadeTransition(
      opacity: _fade,
      child: ScaleTransition(
        scale: Tween<double>(begin: 0.88, end: 1).animate(_scale),
        child: BrandLockup(height: widget.height),
      ),
    );
  }
}
