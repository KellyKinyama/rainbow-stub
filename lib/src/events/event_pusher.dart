import 'dart:convert';

import '../xmpp/router.dart';

/// The `react-native-rainbow-module` SDK subscribes to XMPP `<message>` /
/// `<iq>` stanzas whose payload elements identify a Rainbow "event". We
/// synthesize those from REST mutations so the RN app's `eventEmitter`
/// fires the corresponding `EventType.*` value.
///
/// Wire shape (best-effort — the RN SDK is defensive about payload shape):
///
///   <message from="rainbow-stub.local" to="<userJid>" type="headline">
///     <event xmlns="urn:rainbow:events" type="<EventType>">
///       <payload>{"…json…"}</payload>
///     </event>
///   </message>
class EventPusher {
  EventPusher(this.router, this.domain);

  final StanzaRouter router;
  final String domain;

  int _push({
    required String userId,
    required String eventType,
    required Map<String, dynamic> payload,
  }) {
    final json = _esc(jsonEncode(payload));
    final stanza =
        '<message from="${_esc(domain)}" '
        'to="${_esc(userId)}@${_esc(domain)}" type="headline">'
        '<event xmlns="urn:rainbow:events" type="${_esc(eventType)}">'
        '<payload>$json</payload>'
        '</event>'
        '</message>';
    return router.fanOut(userId, stanza);
  }

  int pushBubblesListUpdated(
    String userId,
    List<Map<String, dynamic>> bubbles,
  ) => _push(
    userId: userId,
    eventType: 'BubblesListUpdated',
    payload: {'bubbles': bubbles},
  );

  int pushOnBubbleUpdated(String userId, Map<String, dynamic> bubble) =>
      _push(userId: userId, eventType: 'OnBubbleUpdated', payload: bubble);

  int pushBubbleInvitation(String userId, Map<String, dynamic> bubble) => _push(
    userId: userId,
    eventType: 'InvitedBubblesResult',
    payload: {
      'bubbles': [bubble],
    },
  );

  int pushBubbleDeleted(String userId, String bubbleId) => _push(
    userId: userId,
    eventType: 'DeleteBubbleResult',
    payload: {'success': true, 'bubbleId': bubbleId},
  );

  int pushBubbleArchived(String userId, String bubbleId) => _push(
    userId: userId,
    eventType: 'ArchiveBubbleResult',
    payload: {'success': true, 'bubbleId': bubbleId},
  );

  int pushFileAttachFinished(String userId, Map<String, dynamic> file) =>
      _push(userId: userId, eventType: 'FileAttachFinished', payload: file);

  int pushFileDownloadFinished(String userId, Map<String, dynamic> file) =>
      _push(userId: userId, eventType: 'FileDownloadFinished', payload: file);

  int pushSharedFilesForPeer(
    String userId, {
    required String peerJid,
    required List<Map<String, dynamic>> files,
  }) => _push(
    userId: userId,
    eventType: 'GetAllSharedFileWithPeerResult',
    payload: {'peer': peerJid, 'files': files},
  );

  /// RFC 6121 roster push — server-initiated `<iq type="set">` telling the
  /// client that a roster item has been added, updated, or removed.
  int pushRosterItem(
    String userId, {
    required String contactJid,
    required String name,
    String subscription = 'both',
  }) {
    final iq =
        '<iq type="set" id="rp-${DateTime.now().microsecondsSinceEpoch.toRadixString(16)}" '
        'to="${_esc(userId)}@${_esc(domain)}">'
        '<query xmlns="jabber:iq:roster">'
        '<item jid="${_esc(contactJid)}" name="${_esc(name)}" '
        'subscription="${_esc(subscription)}"/>'
        '</query></iq>';
    return router.fanOut(userId, iq);
  }

  int pushRosterRemove(String userId, {required String contactJid}) {
    final iq =
        '<iq type="set" id="rp-${DateTime.now().microsecondsSinceEpoch.toRadixString(16)}" '
        'to="${_esc(userId)}@${_esc(domain)}">'
        '<query xmlns="jabber:iq:roster">'
        '<item jid="${_esc(contactJid)}" subscription="remove"/>'
        '</query></iq>';
    return router.fanOut(userId, iq);
  }
}

String _esc(String s) => s
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;')
    .replaceAll('"', '&quot;');
