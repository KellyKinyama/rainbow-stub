import '../db/database.dart';
import '../util/ids.dart';
import '../xmpp/jid.dart';

class ChatMessage {
  ChatMessage({
    required this.id,
    required this.stanzaId,
    required this.from,
    required this.to,
    required this.conversation,
    required this.body,
    required this.sentAt,
    this.delivered = false,
    this.readAt,
  });

  final String id;
  final String stanzaId;
  final Jid from;
  final Jid to;
  final String conversation;
  final String body;
  final DateTime sentAt;
  final bool delivered;
  final DateTime? readAt;

  Map<String, dynamic> toRainbowJson() => {
    'id': id,
    'messageId': stanzaId,
    'from': from.toString(),
    'to': to.toString(),
    'conversation': conversation,
    'body': body,
    'date': sentAt.toUtc().toIso8601String(),
    'delivered': delivered,
    if (readAt != null) 'read': readAt!.toUtc().toIso8601String(),
  };
}

class MessageRepository {
  MessageRepository(this._db, this._ids);

  final AppDatabase _db;
  final ObjectIdGen _ids;

  static String canonicalConversation(Jid a, Jid b) {
    final aa = a.bare.toString();
    final bb = b.bare.toString();
    return (aa.compareTo(bb) < 0) ? '$aa|$bb' : '$bb|$aa';
  }

  ChatMessage insert({
    required Jid from,
    required Jid to,
    required String stanzaId,
    required String body,
  }) {
    final id = _ids.next();
    final now = DateTime.now().toUtc();
    final conv = canonicalConversation(from, to);
    _db.db.execute(
      '''
      INSERT INTO messages
        (id, stanza_id, from_jid, to_jid, conversation, body, sent_at)
      VALUES (?, ?, ?, ?, ?, ?, ?)
      ''',
      [
        id,
        stanzaId,
        from.bare.toString(),
        to.bare.toString(),
        conv,
        body,
        now.toIso8601String(),
      ],
    );
    return ChatMessage(
      id: id,
      stanzaId: stanzaId,
      from: from,
      to: to,
      conversation: conv,
      body: body,
      sentAt: now,
    );
  }

  /// MAM-style query — bounded slice of a 1:1 conversation between two JIDs.
  List<ChatMessage> conversationBetween(
    Jid a,
    Jid b, {
    int limit = 100,
    DateTime? before,
  }) {
    final conv = canonicalConversation(a, b);
    final params = <Object?>[conv];
    var sql = 'SELECT * FROM messages WHERE conversation = ?';
    if (before != null) {
      sql += ' AND sent_at < ?';
      params.add(before.toIso8601String());
    }
    sql += ' ORDER BY sent_at DESC LIMIT ?';
    params.add(limit);
    final rs = _db.db.select(sql, params);
    return rs.map(_rowToChat).toList();
  }

  /// XEP-0313 + RSM-aware slice. Each returned page is chronological
  /// (ASC), but the WINDOW of the archive it comes from depends on the
  /// anchor:
  ///   - no anchor or `beforeId` → the newest [max] messages older
  ///     than the anchor (or newest [max] overall).
  ///   - `afterId` → the oldest [max] messages newer than the anchor.
  /// This matches XEP-0313 §4.3 "final page" semantics: with no RSM
  /// the client receives the tail of the archive.
  ({List<ChatMessage> page, int total}) mamSlice(
    Jid a,
    Jid b, {
    int max = 50,
    String? beforeId,
    String? afterId,
  }) {
    final conv = canonicalConversation(a, b);
    final total =
        _db.db.select(
              'SELECT COUNT(*) AS n FROM messages WHERE conversation = ?',
              [conv],
            ).first['n']
            as int;
    final params = <Object?>[conv];
    var sql = 'SELECT * FROM messages WHERE conversation = ?';
    if (beforeId != null && beforeId.isNotEmpty) {
      final anchor = _findAnchor(beforeId);
      if (anchor != null) {
        sql += ' AND (sent_at < ? OR (sent_at = ? AND id < ?))';
        params
          ..add(anchor.sentAt)
          ..add(anchor.sentAt)
          ..add(anchor.id);
      }
    }
    if (afterId != null && afterId.isNotEmpty) {
      final anchor = _findAnchor(afterId);
      if (anchor != null) {
        sql += ' AND (sent_at > ? OR (sent_at = ? AND id > ?))';
        params
          ..add(anchor.sentAt)
          ..add(anchor.sentAt)
          ..add(anchor.id);
      }
    }
    // No anchor or `<before>` → grab the NEWEST [max] via DESC, then
    // reverse to chronological. `<after>` walks forward, keep ASC.
    final walkForward = afterId != null && afterId.isNotEmpty;
    sql += walkForward
        ? ' ORDER BY sent_at ASC, id ASC LIMIT ?'
        : ' ORDER BY sent_at DESC, id DESC LIMIT ?';
    params.add(max);
    final rs = _db.db.select(sql, params);
    var page = rs.map(_rowToChat).toList();
    if (!walkForward) page = page.reversed.toList();
    return (page: page, total: total);
  }

  ({String id, String sentAt})? _findAnchor(String id) {
    final rs = _db.db.select('SELECT id, sent_at FROM messages WHERE id = ?', [
      id,
    ]);
    if (rs.isEmpty) return null;
    return (
      id: rs.first['id'] as String,
      sentAt: rs.first['sent_at'] as String,
    );
  }

  ChatMessage _rowToChat(Map<String, Object?> r) => ChatMessage(
    id: r['id'] as String,
    stanzaId: r['stanza_id'] as String,
    from: Jid.parse(r['from_jid'] as String),
    to: Jid.parse(r['to_jid'] as String),
    conversation: r['conversation'] as String,
    body: r['body'] as String,
    sentAt: DateTime.parse(r['sent_at'] as String),
    delivered: (r['delivered'] as int) == 1,
    readAt: r['read_at'] == null
        ? null
        : DateTime.parse(r['read_at'] as String),
  );

  /// Returns the row matching [stanzaId] within the canonical conversation
  /// for [a] and [b], or null if no such message exists.
  ChatMessage? findByStanzaId(Jid a, Jid b, String stanzaId) {
    final conv = canonicalConversation(a, b);
    final rs = _db.db.select(
      'SELECT * FROM messages WHERE conversation = ? AND stanza_id = ? LIMIT 1',
      [conv, stanzaId],
    );
    if (rs.isEmpty) return null;
    return _rowToChat(rs.first);
  }

  /// Deletes the row for [stanzaId] in the canonical conversation. Returns
  /// true if a row was removed. Used to implement XEP-0424 retraction.
  bool deleteByStanzaId(Jid a, Jid b, String stanzaId) {
    final conv = canonicalConversation(a, b);
    _db.db.execute(
      'DELETE FROM messages WHERE conversation = ? AND stanza_id = ?',
      [conv, stanzaId],
    );
    return _db.db.updatedRows > 0;
  }
}
