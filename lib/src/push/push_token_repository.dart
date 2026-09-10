import '../db/database.dart';

/// APNs/FCM device tokens. One row per (user_id, token). Repository
/// exposes just the pieces the routes + push dispatcher need.
class PushTokenRepository {
  PushTokenRepository(this._db);

  final AppDatabase _db;

  void upsert({
    required String userId,
    required String token,
    required String platform,
  }) {
    _db.db.execute(
      '''
      INSERT INTO push_tokens (user_id, token, platform, updated_at)
      VALUES (?, ?, ?, ?)
      ON CONFLICT (user_id, token) DO UPDATE
        SET platform   = excluded.platform,
            updated_at = excluded.updated_at
      ''',
      [userId, token, platform, DateTime.now().toUtc().toIso8601String()],
    );
  }

  void delete({required String userId, required String token}) {
    _db.db.execute('DELETE FROM push_tokens WHERE user_id = ? AND token = ?', [
      userId,
      token,
    ]);
  }

  List<PushToken> findForUser(String userId) {
    final rs = _db.db.select(
      'SELECT user_id, token, platform, updated_at FROM push_tokens '
      'WHERE user_id = ? ORDER BY updated_at DESC',
      [userId],
    );
    return rs.map(_row).toList();
  }

  PushToken _row(Map<String, Object?> r) => PushToken(
    userId: r['user_id'] as String,
    token: r['token'] as String,
    platform: r['platform'] as String,
    updatedAt: DateTime.parse(r['updated_at'] as String),
  );
}

class PushToken {
  const PushToken({
    required this.userId,
    required this.token,
    required this.platform,
    required this.updatedAt,
  });
  final String userId;
  final String token;
  final String platform;
  final DateTime updatedAt;

  Map<String, dynamic> toJson() => {
    'userId': userId,
    'token': token,
    'platform': platform,
    'updatedAt': updatedAt.toUtc().toIso8601String(),
  };
}
