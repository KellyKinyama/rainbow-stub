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
    _db.db.execute(
      '''
      INSERT INTO roster (user_id, contact_id, status, created_at)
      VALUES (?, ?, ?, ?)
      ON CONFLICT(user_id, contact_id) DO UPDATE SET status = excluded.status
      ''',
      [userId, contactId, status, now.toIso8601String()],
    );
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
    _db.db.execute('DELETE FROM roster WHERE user_id = ? AND contact_id = ?', [
      userId,
      contactId,
    ]);
  }
}
