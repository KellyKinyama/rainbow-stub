import '../db/database.dart';
import '../util/ids.dart';

class TokenRecord {
  TokenRecord({
    required this.token,
    required this.userId,
    required this.issuedAt,
    required this.expiresAt,
    required this.renewExpiresAt,
    required this.revoked,
  });

  final String token;
  final String userId;
  final DateTime issuedAt;
  final DateTime expiresAt;
  final DateTime renewExpiresAt;
  final bool revoked;

  bool get isExpired => DateTime.now().toUtc().isAfter(expiresAt);
  bool get canRenew => DateTime.now().toUtc().isBefore(renewExpiresAt);
}

class TokenStore {
  TokenStore(this._db);

  final AppDatabase _db;

  TokenRecord issue({
    required String userId,
    required Duration ttl,
    required Duration renewTtl,
  }) {
    final now = DateTime.now().toUtc();
    final rec = TokenRecord(
      token: newBearerToken(),
      userId: userId,
      issuedAt: now,
      expiresAt: now.add(ttl),
      renewExpiresAt: now.add(renewTtl),
      revoked: false,
    );
    _db.db.execute(
      '''
      INSERT INTO auth_tokens
        (token, user_id, issued_at, expires_at, renew_expires_at, revoked)
      VALUES (?, ?, ?, ?, ?, 0)
      ''',
      [
        rec.token,
        rec.userId,
        rec.issuedAt.toIso8601String(),
        rec.expiresAt.toIso8601String(),
        rec.renewExpiresAt.toIso8601String(),
      ],
    );
    return rec;
  }

  TokenRecord? find(String token) {
    final rs = _db.db.select('SELECT * FROM auth_tokens WHERE token = ?', [
      token,
    ]);
    if (rs.isEmpty) return null;
    final r = rs.first;
    return TokenRecord(
      token: r['token'] as String,
      userId: r['user_id'] as String,
      issuedAt: DateTime.parse(r['issued_at'] as String),
      expiresAt: DateTime.parse(r['expires_at'] as String),
      renewExpiresAt: DateTime.parse(r['renew_expires_at'] as String),
      revoked: (r['revoked'] as int) == 1,
    );
  }

  void revoke(String token) {
    _db.db.execute('UPDATE auth_tokens SET revoked = 1 WHERE token = ?', [
      token,
    ]);
  }

  TokenRecord renew({
    required String oldToken,
    required Duration ttl,
    required Duration renewTtl,
  }) {
    final existing = find(oldToken);
    if (existing == null || existing.revoked || !existing.canRenew) {
      throw StateError('Cannot renew token');
    }
    revoke(oldToken);
    return issue(userId: existing.userId, ttl: ttl, renewTtl: renewTtl);
  }
}
