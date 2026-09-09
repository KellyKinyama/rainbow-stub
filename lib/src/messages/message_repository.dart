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

  /// XEP-0313 + RSM-aware slice: pages FORWARD (chronological) with
  /// optional `before`/`after` MAM stanza-id anchors.
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
        // (sent_at, id) < (anchor.sent_at, anchor.id)  — ties break by id.
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
    sql += ' ORDER BY sent_at ASC, id ASC LIMIT ?';
    params.add(max);
    final rs = _db.db.select(sql, params);
    return (page: rs.map(_rowToChat).toList(), total: total);
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
}
