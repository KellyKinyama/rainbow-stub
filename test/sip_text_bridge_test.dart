// M1 loopback UDP integration test for SipGateway text bridge.
// - Outbound: XMPP _handleMessage → gw.sendText → real UDP MESSAGE to peer
//   → peer replies 200 OK → sendText resolves ok=true.
// - Inbound: peer sends raw SIP MESSAGE → gw dispatches → mock XMPP session
//   receives an <message> stanza and MessageRepository has a row.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:rainbow_stub/rainbow_stub.dart';
import 'package:rainbow_stub/src/sip/sip_config.dart';
import 'package:rainbow_stub/src/sip/sip_gateway.dart';
import 'package:sip_core/sip_core.dart';
import 'package:sip_transport/sip_transport.dart';
import 'package:test/test.dart';
import 'package:xml/xml.dart';

const _xmppDomain = 'rainbow-stub.local';
const _sipDomain = 'sip.rainbow-stub.local';
const _parser = SipParser();

void main() {
  group('SipGateway M1 — text bridge', () {
    late Directory tmp;
    late AppDatabase db;
    late UserRepository users;
    late MessageRepository messages;
    late CallLogRepository callLog;
    late StanzaRouter router;
    late MetricsRegistry metrics;
    late User alice;

    late UdpSipTransport gwTransport;
    late UdpSipTransport peerTransport;
    late Endpoint peerLocalEp;
    late Endpoint gwLocalEp;
    late SipGateway gw;

    setUp(() async {
      tmp = Directory.systemTemp.createTempSync('rainbow-stub-sip-m1');
      db = await AppDatabase.open(
        path: '${tmp.path}/t.db',
        schemaSqlPath: 'lib/src/db/schema.sql',
      );
      final ids = ObjectIdGen();
      users = UserRepository(db, ids);
      messages = MessageRepository(db, ids);
      callLog = CallLogRepository(db, ids);
      router = StanzaRouter();
      metrics = MetricsRegistry();
      alice = users.create(
        loginEmail: 'alice@rainbow-stub.local',
        password: 'password',
        firstName: 'Alice',
        lastName: 'Sample',
      );

      // Two loopback UDP sockets on kernel-assigned ports.
      peerTransport = UdpSipTransport(
        bindAddress: InternetAddress.loopbackIPv4,
        bindPort: 0,
      );
      await peerTransport.start();
      peerLocalEp = peerTransport.localEndpoint;

      gwTransport = UdpSipTransport(
        bindAddress: InternetAddress.loopbackIPv4,
        bindPort: 0,
      );
      await gwTransport.start();
      gwLocalEp = gwTransport.localEndpoint;

      final config = SipConfig(
        enabled: true,
        domain: _sipDomain,
        bindAddress: '127.0.0.1',
        bindPort: gwLocalEp.port,
        outboundProxyHost: '127.0.0.1',
        outboundProxyPort: peerLocalEp.port,
        localContactUri: 'sip:b2bua@127.0.0.1:${gwLocalEp.port}',
        b2buaFromUri: 'sip:rainbow-stub@$_xmppDomain',
      );
      gw = SipGateway.forTesting(
        config: config,
        xmppDomain: _xmppDomain,
        router: router,
        users: users,
        messages: messages,
        callLog: callLog,
        metrics: metrics,
        transport: gwTransport,
        outboundEndpoint: peerLocalEp,
      );
    });

    tearDown(() async {
      await gw.stop();
      await peerTransport.close();
      db.close();
      tmp.deleteSync(recursive: true);
    });

    test('outbound MESSAGE — 2xx from peer resolves sendText(true)', () async {
      // Peer role: auto-200-OK any MESSAGE it receives; capture the request.
      final received = <SipRequest>[];
      final peerSub = peerTransport.incoming.listen((inb) async {
        if (inb.message is! SipRequest) return;
        final req = inb.message as SipRequest;
        received.add(req);
        final resp = _build200(req);
        await peerTransport.send(utf8.encode(resp), inb.source);
      });

      final aliceJid = Jid(local: alice.id, domain: _xmppDomain);
      final peerJid = Jid(local: '+15551234', domain: _sipDomain);

      final ok = await gw.sendText(
        from: aliceJid,
        to: peerJid,
        body: 'hello sip',
        stanzaId: 'stanza-1',
      );

      expect(ok, isTrue);
      expect(received, hasLength(1));
      final req = received.single;
      expect(req.method, 'MESSAGE');
      expect(req.callId, 'stanza-1');
      expect(req.requestUri, contains('sip:+15551234@$_sipDomain'));
      expect(req.parseFrom().uri.user, alice.id);
      expect(req.parseFrom().uri.host, _xmppDomain);
      expect(req.parseTo().uri.user, '+15551234');
      expect(req.parseTo().uri.host, _sipDomain);
      expect(
        req.firstHeader('content-type')?.value(),
        contains('text/plain'),
      );
      expect(utf8.decode(req.bodyBytes()), 'hello sip');
      expect(
        metrics.render(),
        contains(
          'rainbow_stub_sip_messages_out_total{status="ok"} 1',
        ),
      );
      await peerSub.cancel();
    });

    test(
        'outbound MESSAGE — non-2xx from peer resolves sendText(false) '
        'and increments err counter', () async {
      final peerSub = peerTransport.incoming.listen((inb) async {
        if (inb.message is! SipRequest) return;
        final resp = _buildStatus(inb.message as SipRequest, 500, 'Boom');
        await peerTransport.send(utf8.encode(resp), inb.source);
      });

      final aliceJid = Jid(local: alice.id, domain: _xmppDomain);
      final peerJid = Jid(local: '+15551234', domain: _sipDomain);
      final ok = await gw.sendText(
        from: aliceJid,
        to: peerJid,
        body: 'oops',
        stanzaId: 'stanza-err',
      );
      expect(ok, isFalse);
      expect(
        metrics.render(),
        contains(
          'rainbow_stub_sip_messages_out_total{status="err"} 1',
        ),
      );
      await peerSub.cancel();
    });

    test('inbound MESSAGE — fans out an XMPP <message> and inserts row',
        () async {
      final mock = _CapturingSession(
        jid: Jid(local: alice.id, domain: _xmppDomain),
        userId: alice.id,
      );
      router.register(mock);

      final wire = _buildMessageRequest(
        callId: 'sip-call-42',
        from: 'sip:+15551234@$_sipDomain',
        to: 'sip:${alice.id}@$_xmppDomain',
        gwEp: gwLocalEp,
        peerEp: peerLocalEp,
        branch: 'z9hG4bK-inbound',
        body: 'inbound hi',
      );
      final ackFuture = _awaitFinal(peerTransport, callId: 'sip-call-42');
      await peerTransport.send(utf8.encode(wire), gwLocalEp);
      final resp = await ackFuture.timeout(const Duration(seconds: 2));

      expect(resp.statusCode, 200);
      // XMPP fan-out reached the mock session.
      expect(mock.captured, hasLength(1));
      final stanza = XmlDocument.parse(mock.captured.single).rootElement;
      expect(stanza.localName, 'message');
      expect(stanza.getAttribute('from'), '+15551234@$_sipDomain');
      expect(stanza.getAttribute('to'), '${alice.id}@$_xmppDomain');
      expect(stanza.getAttribute('type'), 'chat');
      expect(stanza.getElement('body')?.innerText, 'inbound hi');

      // MessageRepository persisted the row (Call-ID reused as stanza id).
      final aliceBare = Jid(local: alice.id, domain: _xmppDomain);
      final peerBare = Jid(local: '+15551234', domain: _sipDomain);
      final row = messages.findByStanzaId(peerBare, aliceBare, 'sip-call-42');
      expect(row, isNotNull);
      expect(row!.body, 'inbound hi');
      expect(
        metrics.render(),
        contains(
          'rainbow_stub_sip_messages_in_total{status="ok"} 1',
        ),
      );
    });

    test('inbound MESSAGE — unknown recipient returns 404', () async {
      final wire = _buildMessageRequest(
        callId: 'sip-call-nope',
        from: 'sip:+15550000@$_sipDomain',
        to: 'sip:not-a-user@$_xmppDomain',
        gwEp: gwLocalEp,
        peerEp: peerLocalEp,
        branch: 'z9hG4bK-nope',
        body: 'lost',
      );
      final ackFuture = _awaitFinal(peerTransport, callId: 'sip-call-nope');
      await peerTransport.send(utf8.encode(wire), gwLocalEp);
      final resp = await ackFuture.timeout(const Duration(seconds: 2));
      expect(resp.statusCode, 404);
    });
  });
}

class _CapturingSession implements XmppSession {
  _CapturingSession({required this.jid, required this.userId});

  @override
  final Jid jid;
  @override
  final String userId;
  final captured = <String>[];

  @override
  void send(String stanza) => captured.add(stanza);
}

// Build a syntactically valid 2xx/xxx echo response for a received request.
String _build200(SipRequest req) => _buildStatus(req, 200, 'OK');

String _buildStatus(SipRequest req, int code, String reason) {
  final via = req.firstHeader('via')!.value();
  final from = req.firstHeader('from')!.value();
  final to = req.firstHeader('to')!.value();
  final callId = req.callId!;
  final cseq = req.parseCSeq();
  // Stamp a to-tag on the response (RFC 3261 §8.2.6.2).
  final toWithTag = to.contains(';tag=') ? to : '$to;tag=peer-tag';
  return 'SIP/2.0 $code $reason\r\n'
      'Via: $via\r\n'
      'From: $from\r\n'
      'To: $toWithTag\r\n'
      'Call-ID: $callId\r\n'
      'CSeq: ${cseq.sequence} ${cseq.method}\r\n'
      'Content-Length: 0\r\n'
      '\r\n';
}

// Build a well-formed SIP MESSAGE request in string form.
String _buildMessageRequest({
  required String callId,
  required String from,
  required String to,
  required Endpoint gwEp,
  required Endpoint peerEp,
  required String branch,
  required String body,
}) {
  final bodyBytes = utf8.encode(body);
  return 'MESSAGE $to SIP/2.0\r\n'
      'Via: SIP/2.0/UDP 127.0.0.1:${peerEp.port};branch=$branch\r\n'
      'Max-Forwards: 70\r\n'
      'From: <$from>;tag=peer\r\n'
      'To: <$to>\r\n'
      'Call-ID: $callId\r\n'
      'CSeq: 1 MESSAGE\r\n'
      'Content-Type: text/plain; charset=utf-8\r\n'
      'Content-Length: ${bodyBytes.length}\r\n'
      '\r\n'
      '$body';
}

// Wait for the first response addressed to [callId] on the given transport.
Future<SipResponse> _awaitFinal(
  SipTransport transport, {
  required String callId,
}) {
  final c = Completer<SipResponse>();
  late StreamSubscription<InboundSipMessage> sub;
  sub = transport.incoming.listen((inb) {
    if (inb.message is! SipResponse) return;
    final resp = inb.message as SipResponse;
    if (resp.callId != callId) return;
    if (resp.statusCode < 200) return;
    if (!c.isCompleted) c.complete(resp);
    unawaited(sub.cancel());
  });
  return c.future;
}
