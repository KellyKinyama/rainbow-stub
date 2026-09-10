import '../db/database.dart';
import 'user_model.dart';
import 'user_repository.dart';

class RosterEntry {
  RosterEntry({
    required this.userId,
    required this.contact,
    required this.status,
    required this.createdAt,
  });

  final String userId;
  final User contact;
  final String status;
  final DateTime createdAt;

  Map<String, dynamic> toRainbowJson({
    Map<String, dynamic>? presence,
    bool hasAvatar = false,
  }) => {
    'id': '$userId:${contact.id}',
    'userId': userId,
    'peerId': contact.id,
    'peerUser': contact.toRainbowJson(presence: presence, hasAvatar: hasAvatar),
    'status': status,
    'type': 'user',
    'isRoster': true,
    'creationDate': createdAt.toUtc().toIso8601String(),
  };
}

class RosterRepository {
  RosterRepository(this._db, this._users);

  final AppDatabase _db;
  final UserRepository _users;

  List<RosterEntry> listFor(String userId, {int offset = 0, int limit = 100}) {
    final rs = _db.db.select(
      '''
      SELECT r.contact_id, r.status, r.created_at
      FROM roster r
      WHERE r.user_id = ?
      ORDER BY r.created_at DESC
      LIMIT ? OFFSET ?
      ''',
      [userId, limit, offset],
    );
    final out = <RosterEntry>[];
    for (final row in rs) {
      final c = _users.findById(row['contact_id'] as String);
      if (c == null) continue;
      out.add(
        RosterEntry(
          userId: userId,
          contact: c,
          status: row['status'] as String,
          createdAt: DateTime.parse(row['created_at'] as String),
        ),
      );
    }
    return out;
  }

  int countFor(String userId) {
    final rs = _db.db.select(
      'SELECT COUNT(*) AS n FROM roster WHERE user_id = ?',
      [userId],
    );
    return rs.first['n'] as int;
  }

  bool exists(String userId, String contactId) {
    final rs = _db.db.select(
      'SELECT 1 FROM roster WHERE user_id = ? AND contact_id = ?',
      [userId, contactId],
    );
    return rs.isNotEmpty;
  }

  RosterEntry add(
    String userId,
    String contactId, {
    String status = 'accepted',
  }) {
    final now = DateTime.now().toUtc();
    // Symmetric: whenever userId adds contactId, mirror the reverse so
    // both parties see each other. Matches real Rainbow's post-accept
    // behavior for the demo/test-drive UX.
    _db.db.execute('BEGIN');
    try {
      _db.db.execute(
        '''
        INSERT INTO roster (user_id, contact_id, status, created_at)
        VALUES (?, ?, ?, ?)
        ON CONFLICT(user_id, contact_id) DO UPDATE SET status = excluded.status
        ''',
        [userId, contactId, status, now.toIso8601String()],
      );
      _db.db.execute(
        '''
        INSERT INTO roster (user_id, contact_id, status, created_at)
        VALUES (?, ?, ?, ?)
        ON CONFLICT(user_id, contact_id) DO UPDATE SET status = excluded.status
        ''',
        [contactId, userId, status, now.toIso8601String()],
      );
      _db.db.execute('COMMIT');
    } catch (_) {
      _db.db.execute('ROLLBACK');
      rethrow;
    }
    final c = _users.findById(contactId);
    if (c == null) {
      throw StateError('Contact $contactId not found');
    }
    return RosterEntry(
      userId: userId,
      contact: c,
      status: status,
      createdAt: now,
    );
  }

  void remove(String userId, String contactId) {
    // Symmetric removal — see [add] for rationale.
    _db.db.execute('BEGIN');
    try {
      _db.db.execute(
        'DELETE FROM roster WHERE user_id = ? AND contact_id = ?',
        [userId, contactId],
      );
      _db.db.execute(
        'DELETE FROM roster WHERE user_id = ? AND contact_id = ?',
        [contactId, userId],
      );
      _db.db.execute('COMMIT');
    } catch (_) {
      _db.db.execute('ROLLBACK');
      rethrow;
    }
  }

  /// One-shot migration: for every existing (u, c) entry, ensure a
  /// matching (c, u) entry exists with the same status. Called at boot
  /// so pre-existing asymmetric rosters become symmetric.
  int mirrorAll() {
    final rs = _db.db.select(
      'SELECT user_id, contact_id, status, created_at FROM roster',
    );
    var mirrored = 0;
    for (final row in rs) {
      final u = row['user_id'] as String;
      final c = row['contact_id'] as String;
      final status = row['status'] as String;
      final createdAt = row['created_at'] as String;
      final exists = _db.db.select(
        'SELECT 1 FROM roster WHERE user_id = ? AND contact_id = ?',
        [c, u],
      );
      if (exists.isEmpty) {
        _db.db.execute(
          '''
          INSERT INTO roster (user_id, contact_id, status, created_at)
          VALUES (?, ?, ?, ?)
          ''',
          [c, u, status, createdAt],
        );
        mirrored++;
      }
    }
    return mirrored;
  }
}
