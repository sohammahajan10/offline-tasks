/// Fractional indexing: order keys that always have room in between.
///
/// [keyBetween] returns a key strictly between two others, so moving an item
/// only rewrites that item's key, and two devices reordering offline only
/// conflict on the items they moved.
///
/// Key format (as in rocicorp/fractional-indexing, base 62):
/// an *integer part* whose first character encodes its length ('a'..'z' are
/// 1..26 digits for non-negative values, 'Z'..'A' for negative), followed by
/// an optional *fraction* that never ends in '0'. Digits 0-9A-Za-z sort in
/// ASCII order, so plain string comparison orders keys. Adding at either end
/// only steps the integer part, so keys stay short (`a0`, `a1`, … `Zz`, …);
/// only repeated inserts into the same gap lengthen the fraction.
abstract final class FractionalIndex {
  static const digits =
      '0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz';
  static const _zero = '0';
  static final _smallestInteger = 'A${'0' * 26}';

  /// A key strictly after [before] (or the start) and strictly before
  /// [after] (or the end). Throws if [before] >= [after].
  static String keyBetween(String? before, String? after) {
    if (before != null) _validate(before);
    if (after != null) _validate(after);
    if (before != null && after != null && before.compareTo(after) >= 0) {
      throw ArgumentError('$before must sort before $after');
    }
    if (before == null) {
      if (after == null) return 'a$_zero';
      final ib = _integerPart(after);
      final fb = after.substring(ib.length);
      if (ib == _smallestInteger) return ib + _midpoint('', fb);
      if (ib.compareTo(after) < 0) return ib;
      return _decrement(ib) ?? (throw StateError('cannot decrement any more'));
    }
    if (after == null) {
      final ia = _integerPart(before);
      final fa = before.substring(ia.length);
      return _increment(ia) ?? ia + _midpoint(fa, null);
    }
    final ia = _integerPart(before);
    final fa = before.substring(ia.length);
    final ib = _integerPart(after);
    final fb = after.substring(ib.length);
    if (ia == ib) return ia + _midpoint(fa, fb);
    final i = _increment(ia) ?? (throw StateError('cannot increment any more'));
    if (i.compareTo(after) < 0) return i;
    return ia + _midpoint(fa, null);
  }

  /// Midpoint of fractions [a] (may be empty) and [b] (null = 1.0).
  static String _midpoint(String a, String? b) {
    if (b != null) {
      var n = 0;
      while (n < b.length && (n < a.length ? a[n] : _zero) == b[n]) {
        n++;
      }
      if (n > 0) {
        return b.substring(0, n) +
            _midpoint(a.length > n ? a.substring(n) : '', b.substring(n));
      }
    }
    final da = a.isEmpty ? 0 : digits.indexOf(a[0]);
    final db = b == null ? digits.length : digits.indexOf(b[0]);
    if (db - da > 1) return digits[(da + db) ~/ 2];
    if (b != null && b.length > 1) return b[0];
    return digits[da] + _midpoint(a.length > 1 ? a.substring(1) : '', null);
  }

  static int _integerLength(String head) {
    final c = head.codeUnitAt(0);
    if (c >= 0x61 && c <= 0x7a) return c - 0x61 + 2; // a-z
    if (c >= 0x41 && c <= 0x5a) return 0x5a - c + 2; // A-Z
    throw ArgumentError.value(head, 'key', 'invalid integer head');
  }

  static String _integerPart(String key) {
    final length = _integerLength(key[0]);
    if (length > key.length) {
      throw ArgumentError.value(key, 'key', 'integer part too short');
    }
    return key.substring(0, length);
  }

  static void _validate(String key) {
    if (key.isEmpty ||
        key == _smallestInteger ||
        key.split('').skip(1).any((c) => !digits.contains(c))) {
      throw ArgumentError.value(key, 'key', 'not a valid order key');
    }
    final fraction = key.substring(_integerPart(key).length);
    if (fraction.endsWith(_zero)) {
      throw ArgumentError.value(key, 'key', 'fraction ends in 0');
    }
  }

  static String? _increment(String x) {
    final head = x[0];
    final digs = x.substring(1).split('');
    var carry = true;
    for (var i = digs.length - 1; carry && i >= 0; i--) {
      final d = digits.indexOf(digs[i]) + 1;
      if (d == digits.length) {
        digs[i] = _zero;
      } else {
        digs[i] = digits[d];
        carry = false;
      }
    }
    if (!carry) return head + digs.join();
    if (head == 'Z') return 'a$_zero';
    if (head == 'z') return null;
    final h = String.fromCharCode(head.codeUnitAt(0) + 1);
    if (h.compareTo('a') > 0) {
      digs.add(_zero);
    } else {
      digs.removeLast();
    }
    return h + digs.join();
  }

  static String? _decrement(String x) {
    final head = x[0];
    final digs = x.substring(1).split('');
    var borrow = true;
    for (var i = digs.length - 1; borrow && i >= 0; i--) {
      final d = digits.indexOf(digs[i]) - 1;
      if (d == -1) {
        digs[i] = digits[digits.length - 1];
      } else {
        digs[i] = digits[d];
        borrow = false;
      }
    }
    if (!borrow) return head + digs.join();
    if (head == 'a') return 'Z${digits[digits.length - 1]}';
    if (head == 'A') return null;
    final h = String.fromCharCode(head.codeUnitAt(0) - 1);
    if (h.compareTo('Z') < 0) {
      digs.add(digits[digits.length - 1]);
    } else {
      digs.removeLast();
    }
    return h + digs.join();
  }
}
