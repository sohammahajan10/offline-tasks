import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:offline_tasks/domain/backoff.dart';

class _FixedRandom implements Random {
  _FixedRandom(this.value);
  final double value;
  @override
  double nextDouble() => value;
  @override
  int nextInt(int max) => 0;
  @override
  bool nextBool() => false;
}

void main() {
  const backoff = Backoff();

  test('doubles from 2s and caps at 5 minutes', () {
    final noJitter = _FixedRandom(0);
    expect(
      [for (var n = 1; n <= 10; n++) backoff.delayFor(n, noJitter).inSeconds],
      [2, 4, 8, 16, 32, 64, 128, 256, 300, 300],
    );
  });

  test('jitter adds between 0% and 25%', () {
    expect(
      backoff.delayFor(3, _FixedRandom(0.999)).inMilliseconds,
      closeTo(10000, 2),
    );
    final rng = Random(42);
    for (var i = 0; i < 200; i++) {
      final ms = backoff.delayFor(2, rng).inMilliseconds;
      expect(ms, inInclusiveRange(4000, 5000));
    }
  });

  test('gives up after 5 attempts', () {
    expect(backoff.maxAttempts, 5);
    expect(backoff.exhausted(4), isFalse);
    expect(backoff.exhausted(5), isTrue);
  });
}
