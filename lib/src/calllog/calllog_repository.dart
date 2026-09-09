import '../db/database.dart';
import '../util/ids.dart';

class CallLogEntry {
  CallLogEntry({
    required this.id,
    required this.ownerId,
    required this.peerJid,
    this.peerDisplay,
    required this.direction,
    required this.state,
    required this.media,
    required this.startedAt,
    required this.durationMs,
    this.readAt,
  });

  final String id;
  final String ownerId;
  final String peerJid;
  final String? peerDisplay;
  final String direction;
  final String state;
  final String media;
  final DateTime startedAt;
  final int durationMs;
  final DateTime? readAt;

  Map<String, dynamic> toRainbowJson() => {
    'id': id,
    'peer': peerJid,
    'peerDisplayName': peerDisplay,
    'direction': direction,
    'state': state,
    'media': media,
    'startDate': startedAt.toUtc().toIso8601String(),
    'duration': durationMs,
    'isRead': readAt != null,
    if (readAt != null) 'readDate': readAt!.toUtc().toIso8601String(),
  };
}

class CallLogRepository {
  CallLogRepository(this._db, this._ids);

  final AppDatabase _db;
  final ObjectIdGen _ids;

  CallLogEntry insert({
    required String ownerId,
    required String peerJid,
    String? peerDisplay,
    required String direction,
    required String state,
    String media = 'audio',
    int durationMs = 0,
    DateTime? startedAt,
  }) {
    final id = _ids.next();
    final ts = (startedAt ?? DateTime.now().toUtc()).toIso8601String();
    _db.db.execute(
      '''
      INSERT INTO call_log
        (id, owner_id, peer_jid, peer_display, direction, state,
         media, started_at, duration_ms)
      VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
      ''',
      [
        id,
        ownerId,
        peerJid,
        peerDisplay,
        direction,
        state,
        media,
        ts,
        durationMs,
      ],
    );
    return findById(id)!;
  }

  CallLogEntry? findById(String id) {
    final rs = _db.db.select('SELECT * FROM call_log WHERE id = ?', [id]);
    return rs.isEmpty ? null : _row(rs.first);
  }

  List<CallLogEntry> listFor(
    String ownerId, {
    int offset = 0,
    int limit = 100,
  }) {
    final rs = _db.db.select(
      '''
      SELECT * FROM call_log WHERE owner_id = ?
      ORDER BY started_at DESC
      LIMIT ? OFFSET ?
      ''',
      [ownerId, limit, offset],
    );
    return rs.map(_row).toList();
  }

  int countMissed(String ownerId) {
    final rs = _db.db.select(
      "SELECT COUNT(*) AS n FROM call_log WHERE owner_id = ? AND state = 'missed' AND read_at IS NULL",
      [ownerId],
    );
    return rs.first['n'] as int;
  }

  void deleteOne(String ownerId, String id) {
    _db.db.execute('DELETE FROM call_log WHERE owner_id = ? AND id = ?', [
      ownerId,
      id,
    ]);
  }

  void deleteAll(String ownerId) {
    _db.db.execute('DELETE FROM call_log WHERE owner_id = ?', [ownerId]);
  }

  void markRead(String ownerId, String id) {
    _db.db.execute(
      'UPDATE call_log SET read_at = ? WHERE owner_id = ? AND id = ?',
      [DateTime.now().toUtc().toIso8601String(), ownerId, id],
    );
  }

  CallLogEntry _row(Map<String, Object?> r) => CallLogEntry(
    id: r['id'] as String,
    ownerId: r['owner_id'] as String,
    peerJid: r['peer_jid'] as String,
    peerDisplay: r['peer_display'] as String?,
    direction: r['direction'] as String,
    state: r['state'] as String,
    media: r['media'] as String,
    startedAt: DateTime.parse(r['started_at'] as String),
    durationMs: r['duration_ms'] as int,
    readAt: r['read_at'] == null
        ? null
        : DateTime.parse(r['read_at'] as String),
  );
}
