import 'dart:collection';

import 'package:logging/logging.dart';

import 'jid.dart';

final _log = Logger('xmpp.router');

/// Owns per-user session lists and lets us fan out stanzas.
class StanzaRouter {
  final _byUser = HashMap<String, Set<XmppSession>>();

  Iterable<XmppSession> get sessions =>
      _byUser.values.expand((s) => s).toList(growable: false);

  Set<XmppSession> sessionsOf(String userId) => _byUser[userId] ?? const {};

  void register(XmppSession s) {
    _byUser.putIfAbsent(s.jid.local, () => <XmppSession>{}).add(s);
    _log.info('register ${s.jid} — total=${sessions.length}');
  }

  void unregister(XmppSession s) {
    final set = _byUser[s.jid.local];
    if (set == null) return;
    set.remove(s);
    if (set.isEmpty) _byUser.remove(s.jid.local);
    _log.info('unregister ${s.jid} — total=${sessions.length}');
  }

  /// Send a stanza to every live session of `userId`. Returns count.
  int fanOut(String userId, String stanza) {
    final targets = _byUser[userId];
    if (targets == null) return 0;
    for (final s in targets) {
      s.send(stanza);
    }
    return targets.length;
  }

  /// Broadcast to every session EXCEPT `except`.
  void broadcast(String stanza, {XmppSession? except}) {
    for (final s in sessions) {
      if (identical(s, except)) continue;
      s.send(stanza);
    }
  }
}

/// The subset of a session the router needs — implemented by [XmppWsSession].
abstract class XmppSession {
  Jid get jid;
  String get userId;
  void send(String stanza);
}
