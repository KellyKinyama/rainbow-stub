import 'dart:convert';

import '../db/database.dart';

/// XEP-0444 reactions store — one row per (target message stanza id,
/// reactor user id). Emojis is the full JSON snapshot per the spec's
/// "current full set" semantics.
class ReactionRepository {
  ReactionRepository(this._db);

  final AppDatabase _db;

  void upsert({
    required String targetStanzaId,
    required String fromUserId,
    required List<String> emojis,
  }) {
    _db.db.execute(
      '''
      INSERT INTO reactions
        (target_stanza_id, from_user_id, emojis_json, updated_at)
      VALUES (?, ?, ?, ?)
      ON CONFLICT (target_stanza_id, from_user_id) DO UPDATE
        SET emojis_json = excluded.emojis_json,
            updated_at = excluded.updated_at
      ''',
      [
        targetStanzaId,
        fromUserId,
        jsonEncode(emojis),
        DateTime.now().toUtc().toIso8601String(),
      ],
    );
  }

  /// Returns the current reactor→emojis snapshot for [targetStanzaId].
  Map<String, List<String>> findForMessage(String targetStanzaId) {
    final rs = _db.db.select(
      'SELECT from_user_id, emojis_json FROM reactions '
      'WHERE target_stanza_id = ?',
      [targetStanzaId],
    );
    final result = <String, List<String>>{};
    for (final row in rs) {
      final emojis = (jsonDecode(row['emojis_json'] as String) as List)
          .cast<String>();
      if (emojis.isNotEmpty) {
        result[row['from_user_id'] as String] = emojis;
      }
    }
    return result;
  }
}
