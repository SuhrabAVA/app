import 'dart:io';

/// An HttpOverrides implementation that simply delegates to the default
/// HttpClient. In some environments (e.g. Windows builds) it may be
/// necessary to override the global HTTP client to avoid certificate
/// or header issues. Assign an instance of [MyHttpOverrides] to
/// [HttpOverrides.global] before any network calls are made.
class MyHttpOverrides extends HttpOverrides {
  @override
  HttpClient createHttpClient(SecurityContext? context) {
    // Returning the default HttpClient leaves all settings unchanged.
    return super.createHttpClient(context);
  }
}