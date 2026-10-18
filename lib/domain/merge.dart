import 'package:collection/collection.dart';

import 'task.dart';

class FieldConflict {
  const FieldConflict(
    this.field,
    this.localValue,
    this.remoteValue,
    this.winner,
  );

  final String field;
  final Object? localValue;
  final Object? remoteValue;

  /// 'local' or 'remote'.
  final String winner;

  @override
  String toString() =>
      '$field: "${_short(localValue)}" (this device) vs '
      '"${_short(remoteValue)}" (server) → kept $winner';

  static String _short(Object? v) {
    final s = v is List ? v.join(', ') : '$v';
    return s.length > 40 ? '${s.substring(0, 37)}…' : s;
  }
}

class MergeResult {
  const MergeResult(this.merged, this.conflicts);

  /// Merged synced fields plus `id` and `updated_at`.
  final Map<String, Object?> merged;

  /// Fields both sides changed to different values, resolved by last-writer-wins.
  final List<FieldConflict> conflicts;
}

const _deepEq = DeepCollectionEquality();

bool _same(Object? a, Object? b) => _deepEq.equals(a, b);

/// Three-way, field-level merge of two versions of one task.
///
/// [base] is the last server state both sides started from (null if unknown).
/// For each field:
/// * both sides hold the same value → keep it;
/// * only one side changed it relative to [base] → take that side, so edits
///   to different fields on two devices both survive;
/// * both changed it (or there is no base) → last-writer-wins on the record's
///   `updated_at`, reported as a conflict. On an exact tie the server wins, so
///   every device resolves the same way.
///
/// A delete is the `is_deleted` field like any other, so delete-vs-edit keeps
/// the tombstone *and* the edit: the task stays deleted, and restoring it
/// later brings back the edited version.
///
/// All maps must be canonical (see [canonicalWire]).
MergeResult mergeTask({
  required Map<String, Object?>? base,
  required Map<String, Object?> local,
  required Map<String, Object?> remote,
}) {
  final localAt = DateTime.parse(local['updated_at'] as String);
  final remoteAt = DateTime.parse(remote['updated_at'] as String);
  final localIsNewer = localAt.isAfter(remoteAt);

  final merged = <String, Object?>{'id': remote['id'] ?? local['id']};
  final conflicts = <FieldConflict>[];

  for (final f in TaskFields.all) {
    final l = local[f];
    final r = remote[f];
    if (_same(l, r)) {
      merged[f] = l;
    } else if (base != null && _same(l, base[f])) {
      merged[f] = r; // only the server changed it
    } else if (base != null && _same(r, base[f])) {
      merged[f] = l; // only this device changed it
    } else {
      merged[f] = localIsNewer ? l : r;
      conflicts.add(FieldConflict(f, l, r, localIsNewer ? 'local' : 'remote'));
    }
  }

  merged['updated_at'] = normalizeTimestamp(localIsNewer ? localAt : remoteAt);
  return MergeResult(merged, conflicts);
}

/// True when the synced fields of [a] and [b] are identical.
bool sameFields(Map<String, Object?> a, Map<String, Object?> b) =>
    TaskFields.all.every((f) => _same(a[f], b[f]));
