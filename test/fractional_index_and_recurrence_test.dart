import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:offline_tasks/domain/fractional_index.dart';
import 'package:offline_tasks/domain/recurrence.dart';

void main() {
  group('FractionalIndex', () {
    String between(String? a, String? b) => FractionalIndex.keyBetween(a, b);

    void expectBetween(String? a, String key, String? b) {
      if (a != null) expect(a.compareTo(key) < 0, isTrue, reason: '$a < $key');
      if (b != null) expect(key.compareTo(b) < 0, isTrue, reason: '$key < $b');
    }

    test('appending and prepending stay short', () {
      var last = between(null, null);
      var first = last;
      for (var i = 0; i < 5000; i++) {
        last = between(last, null);
        first = between(null, first);
      }
      expect(last.length, lessThanOrEqualTo(4));
      expect(first.length, lessThanOrEqualTo(4));
    });

    test('first key, and keys before/after', () {
      final first = between(null, null);
      expect(first, 'a0');
      expectBetween(null, between(null, first), first);
      expectBetween(first, between(first, null), null);
    });

    test('tight spots: adjacent digits and shared prefixes', () {
      for (final (a, b) in [
        ('a0', 'a1'),
        ('a0', 'a0V'),
        ('a0V', 'a1'),
        ('a1', 'a1001'),
        ('az', 'b10'),
        ('Zz', 'a0'),
        ('zzzzzzzzzzzzzzzzzzzzzzzzzzz', null),
        (null, 'Zz'),
      ]) {
        expectBetween(a, between(a, b), b);
      }
    });

    test('repeated inserts at the front, back and middle keep order', () {
      final rng = Random(1);
      final keys = <String>[between(null, null)];
      for (var i = 0; i < 2000; i++) {
        final at = switch (i % 3) {
          0 => 0,
          1 => keys.length,
          _ => rng.nextInt(keys.length + 1),
        };
        final key = between(
          at == 0 ? null : keys[at - 1],
          at == keys.length ? null : keys[at],
        );
        keys.insert(at, key);
      }
      final sorted = [...keys]..sort();
      expect(keys, sorted, reason: 'insertion order == sort order');
      expect(keys.toSet(), hasLength(keys.length), reason: 'all distinct');
      // Ends only step the integer part, so keys stay short.
      expect(keys.map((k) => k.length).reduce(max), lessThan(16));
    });

    test('rejects bad input', () {
      expect(() => between('b', 'a'), throwsArgumentError);
      expect(() => between('a', 'a'), throwsArgumentError);
      expect(
        () => between('a10', null),
        throwsArgumentError,
        reason: 'fraction ends in 0',
      );
      expect(() => between('a-', null), throwsArgumentError);
      expect(
        () => between('b1', null),
        throwsArgumentError,
        reason: 'integer part too short',
      );
    });
  });

  group('Recurrence', () {
    test('daily and weekly add whole UTC days', () {
      final due = DateTime.utc(2026, 10, 24, 9, 30);
      expect(Recurrence.daily.next(due), DateTime.utc(2026, 10, 25, 9, 30));
      expect(Recurrence.weekly.next(due), DateTime.utc(2026, 10, 31, 9, 30));
    });

    test('monthly clamps to the end of shorter months', () {
      expect(
        Recurrence.monthly.next(DateTime.utc(2026, 1, 31, 8)),
        DateTime.utc(2026, 2, 28, 8),
      );
      expect(
        Recurrence.monthly.next(DateTime.utc(2028, 1, 31, 8)),
        DateTime.utc(2028, 2, 29, 8),
      );
      expect(
        Recurrence.monthly.next(DateTime.utc(2026, 12, 15)),
        DateTime.utc(2027, 1, 15),
      );
    });

    test('the same instant gives the same result in any time zone', () {
      final utc = DateTime.utc(2026, 10, 24, 22);
      final local = utc.toLocal();
      expect(Recurrence.daily.next(local), Recurrence.daily.next(utc));
    });

    test('occurrence ids are deterministic per series and due time', () {
      final due = DateTime.utc(2026, 10, 25, 9);
      final a = occurrenceId('series-1', due);
      expect(occurrenceId('series-1', due.toLocal()), a);
      expect(
        occurrenceId('series-1', due.add(const Duration(days: 1))),
        isNot(a),
      );
      expect(occurrenceId('series-2', due), isNot(a));
      expect(a, matches(RegExp(r'^[0-9a-f-]{36}$')));
      expect(a[14], '5', reason: 'UUID version 5');
    });

    test('parse', () {
      expect(Recurrence.parse('weekly'), Recurrence.weekly);
      expect(Recurrence.parse(null), isNull);
      expect(Recurrence.parse('yearly'), isNull);
    });
  });
}
