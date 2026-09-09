import '../db/database.dart';

class PresenceRecord {
  PresenceRecord({
    required this.userId,
    required this.show,
    this.status,
    required this.updatedAt,
  });

  final String userId;
  final String show;
  final String? status;
  final DateTime updatedAt;

  Map<String, dynamic> toRainbowJson() => {
    'show': show,
    'status': status,
    'lastUpdateDate': updatedAt.toUtc().toIso8601String(),
  };
}

class PresenceRepository {
  PresenceRepository(this._db);

  final AppDatabase _db;

  PresenceRecord? find(String userId) {
    final rs = _db.db.select('SELECT * FROM presence WHERE user_id = ?', [
      userId,
    ]);
    if (rs.isEmpty) return null;
    final r = rs.first;
    return PresenceRecord(
      userId: r['user_id'] as String,
      show: r['show'] as String,
      status: r['status'] as String?,
      updatedAt: DateTime.parse(r['updated_at'] as String),
    );
  }

  /// Default presence when we've never observed the user: `offline`.
  PresenceRecord findOrDefault(String userId) =>
      find(userId) ??
      PresenceRecord(
        userId: userId,
        show: 'offline',
        updatedAt: DateTime.now().toUtc(),
      );

  PresenceRecord set(String userId, String show, {String? status}) {
    final now = DateTime.now().toUtc();
    _db.db.execute(
      '''
      INSERT INTO presence (user_id, show, status, updated_at)
      VALUES (?, ?, ?, ?)
      ON CONFLICT(user_id) DO UPDATE SET
        show = excluded.show,
        status = excluded.status,
        updated_at = excluded.updated_at
      ''',
      [userId, show, status, now.toIso8601String()],
    );
    return PresenceRecord(
      userId: userId,
      show: show,
      status: status,
      updatedAt: now,
    );
  }
}
