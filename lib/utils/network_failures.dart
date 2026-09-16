/// Распознавание временных сбоев связи с Supabase.
///
/// Цеховой Wi-Fi регулярно роняет запросы: DNS не резолвится, сокет
/// закрывается посреди ответа, TLS-handshake не успевает завершиться.
/// Такие ошибки не значат ни отсутствия прав, ни отсутствия данных —
/// их нельзя ни трактовать как «нет доступа», ни кэшировать как «пусто».
library;

const List<String> _transientMarkers = <String>[
  'socketexception',
  'clientexception',
  'handshakeexception',
  'connection terminated during handshake',
  'connection closed',
  'connection reset',
  'connection refused',
  'connection abort',
  'failed host lookup',
  'no address associated with hostname',
  'network is unreachable',
  'timed out',
  'timeout',
  // Обновление токена по сети: supabase оборачивает сетевой сбой в свой тип,
  // но по смыслу это тот же обрыв связи, а не отказ авторизации.
  'authretryablefetchexception',
];

/// true — если ошибка вызвана обрывом связи, а не логикой сервера.
bool isTransientNetworkFailure(Object? error) {
  if (error == null) return false;
  final text = error.toString().toLowerCase();
  for (final marker in _transientMarkers) {
    if (text.contains(marker)) return true;
  }
  return false;
}
