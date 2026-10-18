import 'dart:math';

/// Exponential backoff with jitter: 2s, 4s, 8s … capped at 5 minutes, plus up
/// to 25% random extra so many devices coming back online don't retry in
/// lockstep.
class Backoff {
  const Backoff({
    this.base = const Duration(seconds: 2),
    this.cap = const Duration(minutes: 5),
    this.maxAttempts = 5,
  });

  final Duration base;
  final Duration cap;

  /// After this many failed attempts an op is marked `failed` and waits for a
  /// manual retry from the UI.
  final int maxAttempts;

  /// Delay before the next attempt, given how many attempts have failed (≥ 1).
  Duration delayFor(int failedAttempts, [Random? random]) {
    final exp = base.inMilliseconds * pow(2, max(0, failedAttempts - 1));
    final capped = min(exp, cap.inMilliseconds).round();
    final jitter = ((random ?? Random()).nextDouble() * capped * 0.25).round();
    return Duration(milliseconds: capped + jitter);
  }

  bool exhausted(int failedAttempts) => failedAttempts >= maxAttempts;
}
