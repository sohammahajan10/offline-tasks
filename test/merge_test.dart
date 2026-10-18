import 'package:flutter_test/flutter_test.dart';
import 'package:offline_tasks/domain/merge.dart';
import 'package:offline_tasks/domain/task.dart';

Map<String, Object?> wire(
  Map<String, Object?> changes, {
  required int minute,
}) => canonicalWire({
  'id': 't1',
  'title': 'Buy milk',
  'notes': '',
  'priority': 1,
  'due_at': null,
  'category': 'Home',
  'tags': ['errand'],
  'completed': false,
  'is_deleted': false,
  'updated_at': DateTime.utc(2026, 10, 18, 9, minute).toIso8601String(),
  ...changes,
});

void main() {
  final base = wire({}, minute: 0);

  group('mergeTask', () {
    test('no conflict: identical sides merge to themselves', () {
      final local = wire({'title': 'Buy oat milk'}, minute: 5);
      final remote = wire({'title': 'Buy oat milk'}, minute: 6);

      final r = mergeTask(base: base, local: local, remote: remote);
      expect(r.conflicts, isEmpty);
      expect(sameFields(r.merged, local), isTrue);
    });

    test('no conflict: only one side changed anything', () {
      final local = wire({}, minute: 0);
      final remote = wire({'notes': 'semi-skimmed', 'priority': 2}, minute: 7);

      final r = mergeTask(base: base, local: local, remote: remote);
      expect(r.conflicts, isEmpty);
      expect(sameFields(r.merged, remote), isTrue);
    });

    test('different fields changed: both edits survive', () {
      // Device A renamed the task; device B marked it done.
      final local = wire({'title': 'Buy oat milk'}, minute: 5);
      final remote = wire({'completed': true}, minute: 9);

      final r = mergeTask(base: base, local: local, remote: remote);
      expect(r.conflicts, isEmpty);
      expect(r.merged['title'], 'Buy oat milk');
      expect(r.merged['completed'], isTrue);
      expect(r.merged['updated_at'], remote['updated_at'], reason: 'newest');
    });

    test('same field changed: newer local edit wins and is reported', () {
      final local = wire({'title': 'Local title', 'notes': 'mine'}, minute: 9);
      final remote = wire({'title': 'Remote title', 'priority': 0}, minute: 5);

      final r = mergeTask(base: base, local: local, remote: remote);
      expect(r.merged['title'], 'Local title');
      expect(r.merged['notes'], 'mine');
      expect(r.merged['priority'], 0);
      expect(r.conflicts.single.field, 'title');
      expect(r.conflicts.single.winner, 'local');
    });

    test('same field changed: newer remote edit wins', () {
      final local = wire({'due_at': '2026-11-01T10:00:00Z'}, minute: 2);
      final remote = wire({'due_at': '2026-11-02T10:00:00Z'}, minute: 3);

      final r = mergeTask(base: base, local: local, remote: remote);
      expect(r.merged['due_at'], '2026-11-02T10:00:00.000Z');
      expect(r.conflicts.single.winner, 'remote');
    });

    test('same field, same timestamp: the server wins on every device', () {
      final local = wire({'category': 'Work'}, minute: 4);
      final remote = wire({'category': 'Errands'}, minute: 4);

      // Whichever device merges, the value already on the server is kept,
      // so a tie can't flip-flop between devices.
      final r = mergeTask(base: base, local: local, remote: remote);
      expect(r.merged['category'], 'Errands');
      expect(r.conflicts.single.winner, 'remote');
    });

    test('delete vs edit: the tombstone and the edit are both kept', () {
      final local = wire({'is_deleted': true}, minute: 3);
      final remote = wire({'title': 'Buy milk and eggs'}, minute: 8);

      final r = mergeTask(base: base, local: local, remote: remote);
      expect(r.conflicts, isEmpty);
      expect(r.merged['is_deleted'], isTrue, reason: 'delete wins');
      expect(
        r.merged['title'],
        'Buy milk and eggs',
        reason: 'restoring later brings back the edited task',
      );
    });

    test('edit vs delete from the other side behaves the same', () {
      final local = wire({'notes': 'call first'}, minute: 9);
      final remote = wire({'is_deleted': true}, minute: 1);

      final r = mergeTask(base: base, local: local, remote: remote);
      expect(r.merged['is_deleted'], isTrue);
      expect(r.merged['notes'], 'call first');
    });

    test('tags are compared as lists, not by identity', () {
      final local = wire({
        'tags': ['errand', 'weekly'],
      }, minute: 5);
      final remote = wire({
        'tags': ['errand'],
      }, minute: 6);

      final r = mergeTask(base: base, local: local, remote: remote);
      expect(r.conflicts, isEmpty);
      expect(r.merged['tags'], ['errand', 'weekly']);
    });

    test('timestamps in different formats count as equal', () {
      final b = wire({'due_at': '2026-11-01T10:00:00+00:00'}, minute: 0);
      final local = wire({'due_at': '2026-11-01T11:00:00+01:00'}, minute: 5);
      final remote = wire({'due_at': '2026-11-01T10:00:00.000Z'}, minute: 6);

      final r = mergeTask(base: b, local: local, remote: remote);
      expect(r.conflicts, isEmpty);
    });

    test('without a base, differing fields fall back to last-writer-wins', () {
      final local = wire({'title': 'A', 'notes': 'n'}, minute: 1);
      final remote = wire({'title': 'B'}, minute: 2);

      final r = mergeTask(base: null, local: local, remote: remote);
      expect(r.merged['title'], 'B');
      expect(r.merged['notes'], '');
      expect(r.conflicts.map((c) => c.field), ['title', 'notes']);
    });
  });
}
