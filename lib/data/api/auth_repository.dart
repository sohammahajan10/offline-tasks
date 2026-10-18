import 'package:supabase_flutter/supabase_flutter.dart';

class AuthFailure implements Exception {
  const AuthFailure(this.message);
  final String message;

  @override
  String toString() => message;
}

enum SignUpOutcome {
  /// Signed in right away (email confirmation is off in the project).
  signedIn,

  /// Account created; the user must click the link in their email first.
  confirmEmail,
}

/// Email + password accounts through Supabase Auth. Every synced row is owned
/// by `auth.uid()`, so the same account on two devices sees the same tasks.
class AuthRepository {
  AuthRepository(this._auth);

  final GoTrueClient _auth;

  User? get currentUser => _auth.currentUser;

  /// Emits the signed-in user (or null) whenever the session changes.
  Stream<User?> get userChanges =>
      _auth.onAuthStateChange.map((state) => state.session?.user);

  Future<void> signIn({required String email, required String password}) =>
      _wrap(
        () => _auth.signInWithPassword(email: email.trim(), password: password),
      );

  Future<SignUpOutcome> signUp({
    required String email,
    required String password,
  }) async {
    final res = await _wrap(
      () => _auth.signUp(email: email.trim(), password: password),
    );
    return res.session == null
        ? SignUpOutcome.confirmEmail
        : SignUpOutcome.signedIn;
  }

  /// Ends the session. The caller decides what happens to local data (see
  /// [AppDatabase.clearAccountData]); unsynced changes would otherwise be
  /// pushed into the next account that signs in on this device.
  Future<void> signOut() => _wrap(() => _auth.signOut());

  Future<T> _wrap<T>(Future<T> Function() call) async {
    try {
      return await call();
    } on AuthException catch (e) {
      throw AuthFailure(_friendly(e));
    }
  }

  static String _friendly(AuthException e) {
    final m = e.message.toLowerCase();
    if (m.contains('invalid login credentials')) {
      return 'Wrong email or password.';
    }
    if (m.contains('email not confirmed')) {
      return 'Confirm your email first: check your inbox for the link.';
    }
    if (m.contains('already registered')) {
      return 'An account with this email already exists. Sign in instead.';
    }
    if (m.contains('password')) return e.message;
    if (e is AuthRetryableFetchException) {
      return 'Can\'t reach the server. Check your connection and try again.';
    }
    return e.message;
  }
}
