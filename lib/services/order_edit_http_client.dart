import 'dart:convert';

import 'package:http/http.dart' as http;

/// Capabilities are per editor, not per employee: devices share Supabase auth.
/// Keep the token until release completes so in-flight writes stay fenced.
class OrderEditTokens {
  static final Map<String, String> active = {};
}

class OrderEditHttpClient extends http.BaseClient {
  OrderEditHttpClient(this.origin, {http.Client? inner})
      : _inner = inner ?? http.Client();

  final Uri origin;
  final http.Client _inner;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) {
    if (request.url.origin == origin.origin &&
        request.url.path.startsWith('/rest/v1/') &&
        OrderEditTokens.active.isNotEmpty) {
      request.headers['x-order-edit-tokens'] =
          jsonEncode(OrderEditTokens.active);
    }
    return _inner.send(request);
  }

  @override
  void close() => _inner.close();
}
