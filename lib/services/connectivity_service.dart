import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart' show AppLifecycleState;
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:http/http.dart' as http;

/// Признак «связи нет» для всего приложения.
///
/// «Интернет» здесь — это доступность бэкенда, а не наличие Wi-Fi: цеховая
/// точка доступа может отвечать, пока сам Supabase недостижим, и для
/// сотрудника это ровно то же самое — ничего не сохраняется. Поэтому проба
/// бьёт по адресу проекта из `.env`, а не по системному флагу сети. По той же
/// причине здесь нет пакета connectivity_plus: он отвечает на вопрос «есть ли
/// интерфейс», а не «доходит ли запрос».
///
/// Ответ засчитывается ЛЮБОЙ: 200, 401, 404 — всё это значит, что запрос дошёл
/// до сервера и вернулся. Оффлайном считается только обрыв: таймаут,
/// SocketException, сбой DNS или TLS.
class ConnectivityService extends ChangeNotifier {
  ConnectivityService._();

  static final ConnectivityService instance = ConnectivityService._();

  /// Как часто проверяем связь, когда всё хорошо.
  static const Duration onlineInterval = Duration(seconds: 10);

  /// В оффлайне проверяем чаще: индикатор должен погаснуть сразу, как только
  /// сеть вернулась, иначе сотрудник видит мигание уже поверх рабочего
  /// приложения.
  static const Duration offlineInterval = Duration(seconds: 3);

  /// Дольше ждать нет смысла: цеховой Wi-Fi либо отвечает за секунду, либо
  /// не отвечает вовсе.
  static const Duration probeTimeout = Duration(seconds: 6);

  /// Сколько проб подряд должны провалиться, прежде чем показать индикатор.
  ///
  /// Одиночный обрыв — обычное дело при роуминге между точками доступа, и
  /// мигать на каждый такой чих значит приучить не обращать внимания.
  static const int failuresBeforeOffline = 2;

  bool _online = true;
  bool _probing = false;
  int _failures = 0;
  Timer? _timer;
  Uri? _probeUri;

  /// Есть ли связь. До первой пробы считаем, что есть: показывать «нет сети»
  /// на старте, ещё не проверив, — ложная тревога.
  bool get isOnline => _online;

  bool get isOffline => !_online;

  void start() {
    if (_timer != null) return;
    _probeUri ??= _buildProbeUri();
    if (_probeUri == null) return;
    _schedule(const Duration(seconds: 1));
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
  }

  /// Возврат из фона — момент, когда связь чаще всего уже другая
  /// (планшет унесли из зоны точки доступа и принесли обратно).
  void handleLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      unawaited(checkNow());
    } else if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached) {
      stop();
    }
  }

  /// Внеочередная проба — например, после сетевой ошибки запроса.
  Future<void> checkNow() async {
    _probeUri ??= _buildProbeUri();
    if (_probeUri == null) return;
    await _probe();
    if (_timer != null || _probing) {
      _schedule(_online ? onlineInterval : offlineInterval);
    }
  }

  void _schedule(Duration delay) {
    _timer?.cancel();
    _timer = Timer(delay, () async {
      await _probe();
      if (_timer == null) return;
      _schedule(_online ? onlineInterval : offlineInterval);
    });
  }

  Future<void> _probe() async {
    final uri = _probeUri;
    if (uri == null || _probing) return;
    _probing = true;
    try {
      // Кэш-бастер: между пробой и пробой ответ не должен браться из кэша
      // прокси, иначе оффлайн остаётся незамеченным.
      final target = uri.replace(queryParameters: {
        ...uri.queryParameters,
        't': DateTime.now().millisecondsSinceEpoch.toString(),
      });
      await http.get(target, headers: _probeHeaders()).timeout(probeTimeout);
      _setOnline(true);
    } catch (_) {
      // Любой обрыв — таймаут, SocketException, сбой DNS или TLS.
      _failures++;
      if (_failures >= failuresBeforeOffline) {
        _setOnline(false);
      }
    } finally {
      _probing = false;
    }
  }

  void _setOnline(bool value) {
    if (value) _failures = 0;
    if (_online == value) return;
    _online = value;
    notifyListeners();
  }

  /// Без публичного ключа health отвечает 401. Для пробы это всё равно «связь
  /// есть», но каждая проба (раз в 10 с на каждом устройстве) ложилась в логи
  /// Supabase ошибкой и прятала настоящие отказы доступа.
  static Map<String, String> _probeHeaders() {
    try {
      final key = (dotenv.env['SUPABASE_ANON_KEY'] ?? '').trim();
      return key.isEmpty ? const {} : {'apikey': key};
    } catch (_) {
      return const {};
    }
  }

  static Uri? _buildProbeUri() {
    String base;
    try {
      base = (dotenv.env['SUPABASE_URL'] ?? '').trim();
    } catch (_) {
      // dotenv не загружен (тесты, ранний старт) — проб не делаем.
      return null;
    }
    if (base.isEmpty) return null;
    while (base.endsWith('/')) {
      base = base.substring(0, base.length - 1);
    }
    return Uri.tryParse('$base/auth/v1/health');
  }

  @visibleForTesting
  void debugSetOnline(bool value) {
    _failures = value ? 0 : failuresBeforeOffline;
    _setOnline(value);
  }
}
