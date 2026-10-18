import 'package:supabase_flutter/supabase_flutter.dart';

/// Supabase settings, compiled in from the gitignored `.env`:
///
///   flutter run --dart-define-from-file=.env
///
/// Only the anon (public) key belongs here; it ships inside the APK by design
/// and RLS is what protects the data. Never put the service_role key in the app.
abstract final class SupabaseConfig {
  static const _rawUrl = String.fromEnvironment('SUPABASE_URL');
  static const anonKey = String.fromEnvironment('SUPABASE_ANON_KEY');

  /// The project URL, e.g. https://abc.supabase.co.
  static String get url => normalizeUrl(_rawUrl);

  /// Without a backend the app still works fully offline; sync is just off.
  static bool get isConfigured => url.isNotEmpty && anonKey.isNotEmpty;

  /// The client wants the bare project URL and appends /rest/v1, /auth/v1
  /// itself. The dashboard also shows the REST endpoint, which is easy to
  /// paste by mistake, so anything after the host is dropped.
  static String normalizeUrl(String raw) {
    final uri = Uri.tryParse(raw.trim());
    if (uri == null || !uri.hasScheme || uri.host.isEmpty) return '';
    return uri.origin;
  }

  /// The sync engine owns retries (backoff with jitter, attempt counting), so
  /// the PostgREST client's own retry loop for GETs is switched off: one
  /// policy, and request timeouts that mean what they say.
  static const postgrestOptions = PostgrestClientOptions(retryEnabled: false);
}
