// M2 tests — outbound Jingle→SIP INVITE with FakeRtpengine media anchor.
//
// Covers:
//   * XMPP session-initiate → INVITE with anchored SDP → 200 OK → gateway
//     emits session-info <ringing/> and session-accept back to the client;
//     ACK is sent; calls_active gauge goes 0→1.
//   * XMPP session-terminate after answer → BYE on the wire; calls_active
//     drops back to 0; call-log records state=answered.
//   * INVITE returns 486 Busy → gateway emits session-terminate with
//     reason=busy; call-log state=failed.
//   * XMPP session-terminate before answer → CANCEL on the wire;
//     call-log state=canceled.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:rainbow_stub/rainbow_stub.dart';
import 'package:rainbow_stub/src/sip/jingle_sdp.dart';
import 'package:rainbow_stub/src/sip/sip_config.dart';
import 'package:rainbow_stub/src/sip/sip_gateway.dart';
import 'package:sip_core/sip_core.dart';
import 'package:sip_media/sip_media.dart';
import 'package:sip_transport/sip_transport.dart';
import 'package:test/test.dart';
import 'package:xml/xml.dart';

const _xmppDomain = 'rainbow-stub.local';
const _sipDomain = 'sip.rainbow-stub.local';
const _parser = SipParser();

void main() {
  group('SipGateway M2 — Jingle → SIP call', () {
    late Directory tmp;
    late AppDatabase db;
    late UserRepository users;
    late MessageRepository messages;
    late CallLogRepository callLog;
    late StanzaRouter router;
    late MetricsRegistry metrics;
    late User alice;
    late FakeRtpengine fake;
    late MediaAnchor mediaAnchor;

    late UdpSipTransport gwTransport;
    late UdpSipTransport peerTransport;
    late Endpoint peerLocalEp;
    late Endpoint gwLocalEp;
    late SipGateway gw;

    setUp(() async {
      tmp = Directory.systemTemp.createTempSync('rainbow-stub-sip-m2');
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
      fake = FakeRtpengine();
      mediaAnchor = MediaAnchor(
        client: RtpengineClient(transport: FakeRtpengineTransport(fake.handle)),
      );

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
        mediaAnchor: mediaAnchor,
      );
    });

    tearDown(() async {
      await gw.stop();
      await peerTransport.close();
      db.close();
      tmp.deleteSync(recursive: true);
    });

    test('outbound answered call — full ring / accept / BYE round-trip',
        () async {
      final mock = _CapturingSession(
        jid: Jid(local: alice.id, domain: _xmppDomain),
        userId: alice.id,
      );
      router.register(mock);

      final peerReceived = <SipRequest>[];
      final sub = peerTransport.incoming.listen((inb) async {
        if (inb.message is! SipRequest) return;
        final req = inb.message as SipRequest;
        peerReceived.add(req);
        if (req.method == 'INVITE') {
          await peerTransport.send(
            utf8.encode(_buildResponse(req, 100, 'Trying')),
            inb.source,
          );
          await peerTransport.send(
            utf8.encode(_buildResponse(req, 180, 'Ringing', toTag: 'peer-tag')),
            inb.source,
          );
          await peerTransport.send(
            utf8.encode(_buildResponse(
              req,
              200,
              'OK',
              toTag: 'peer-tag',
              body: _peerAnswerSdp,
              contact: 'sip:peer@127.0.0.1:${peerLocalEp.port}',
            )),
            inb.source,
          );
        }
      });

      final jingle = XmlDocument.parse(_offerInitiate('sid-A1')).rootElement;
      await gw.onJingle(
        callerJid: Jid(local: alice.id, domain: _xmppDomain),
        calleeJid: Jid(local: '+15551234', domain: _sipDomain),
        jingle: jingle,
      );

      // Give the FSM + XMPP fanout a beat to settle.
      final acceptEvent = await mock
          .awaitJingleAction('session-accept')
          .timeout(const Duration(seconds: 3));

      // We should have received at least one INVITE and one ACK.
      final methods = peerReceived.map((r) => r.method).toList();
      expect(methods, contains('INVITE'));
      await _waitFor(
        () => peerReceived.any((r) => r.method == 'ACK'),
        const Duration(seconds: 2),
      );

      // Ringing session-info should have arrived before session-accept.
      final actions = mock.jingleActionsSeen();
      expect(actions.first, 'session-info');
      expect(actions, contains('session-accept'));

      // session-accept should carry a parseable Jingle content.
      final acceptContent = acceptEvent.getElement('content');
      expect(acceptContent, isNotNull);
      expect(acceptContent!.getAttribute('name'), 'audio');

      // Metrics: one active call while accepted.
      expect(
        metrics.render(),
        contains('rainbow_stub_sip_calls_active 1'),
      );

      // Now the client hangs up.
      final terminate =
          XmlDocument.parse(_terminate('sid-A1', reason: 'success'))
              .rootElement;
      await gw.onJingle(
        callerJid: Jid(local: alice.id, domain: _xmppDomain),
        calleeJid: Jid(local: '+15551234', domain: _sipDomain),
        jingle: terminate,
      );

      // Peer should have received a BYE.
      await _waitFor(
        () => peerReceived.any((r) => r.method == 'BYE'),
        const Duration(seconds: 2),
      );
      expect(peerReceived.map((r) => r.method), contains('BYE'));

      // calls_active back to 0.
      expect(
        metrics.render(),
        contains('rainbow_stub_sip_calls_active 0'),
      );

      // Call-log has an answered outgoing entry for alice.
      final logs = callLog.listFor(alice.id);
      expect(logs, hasLength(1));
      expect(logs.single.direction, 'outgoing');
      expect(logs.single.state, 'answered');
      expect(logs.single.peerJid, '+15551234@$_sipDomain');

      // Metric total ok.
      expect(
        metrics.render(),
        contains('rainbow_stub_sip_calls_total{outcome="answered"} 1'),
      );

      await sub.cancel();
    });

    test('outbound INVITE gets 486 Busy → Jingle terminate reason=busy',
        () async {
      final mock = _CapturingSession(
        jid: Jid(local: alice.id, domain: _xmppDomain),
        userId: alice.id,
      );
      router.register(mock);

      final peerReceived = <SipRequest>[];
      final sub = peerTransport.incoming.listen((inb) async {
        if (inb.message is! SipRequest) return;
        final req = inb.message as SipRequest;
        peerReceived.add(req);
        if (req.method == 'INVITE') {
          await peerTransport.send(
            utf8.encode(
                _buildResponse(req, 486, 'Busy Here', toTag: 'peer-tag')),
            inb.source,
          );
        }
      });

      final jingle = XmlDocument.parse(_offerInitiate('sid-B1')).rootElement;
      await gw.onJingle(
        callerJid: Jid(local: alice.id, domain: _xmppDomain),
        calleeJid: Jid(local: '+15551234', domain: _sipDomain),
        jingle: jingle,
      );

      final terminate = await mock
          .awaitJingleAction('session-terminate')
          .timeout(const Duration(seconds: 3));
      final reason = terminate.getElement('reason');
      expect(reason, isNotNull);
      expect(reason!.children.whereType<XmlElement>().first.name.local, 'busy');

      // ACK for the non-2xx is emitted by the FSM — the peer should see it.
      await _waitFor(
        () => peerReceived.any((r) => r.method == 'ACK'),
        const Duration(seconds: 2),
      );
      expect(peerReceived.map((r) => r.method), containsAll(['INVITE', 'ACK']));

      final logs = callLog.listFor(alice.id);
      expect(logs, hasLength(1));
      expect(logs.single.state, 'failed');
      expect(
        metrics.render(),
        contains('rainbow_stub_sip_calls_total{outcome="declined"} 1'),
      );
      expect(
        metrics.render(),
        contains('rainbow_stub_sip_calls_active 0'),
      );

      await sub.cancel();
    });

    test(
        'client hangs up before answer → CANCEL on the wire, '
        'call-log canceled', () async {
      final mock = _CapturingSession(
        jid: Jid(local: alice.id, domain: _xmppDomain),
        userId: alice.id,
      );
      router.register(mock);

      final peerReceived = <SipRequest>[];
      final sub = peerTransport.incoming.listen((inb) async {
        if (inb.message is! SipRequest) return;
        final req = inb.message as SipRequest;
        peerReceived.add(req);
        if (req.method == 'INVITE') {
          await peerTransport.send(
            utf8.encode(_buildResponse(req, 100, 'Trying')),
            inb.source,
          );
          await peerTransport.send(
            utf8.encode(_buildResponse(req, 180, 'Ringing', toTag: 'peer-tag')),
            inb.source,
          );
          // …no 200 OK. Wait for CANCEL, then send 487.
        } else if (req.method == 'CANCEL') {
          await peerTransport.send(
            utf8.encode(_buildResponse(req, 200, 'OK')),
            inb.source,
          );
          // The original INVITE server tx would send 487 to complete the
          // CANCEL sequence.
          final invite = peerReceived.firstWhere((r) => r.method == 'INVITE');
          await peerTransport.send(
            utf8.encode(_buildResponse(invite, 487, 'Request Terminated',
                toTag: 'peer-tag')),
            inb.source,
          );
        }
      });

      final jingle = XmlDocument.parse(_offerInitiate('sid-C1')).rootElement;
      // Fire-and-forget — session-initiate blocks until the SIP dialog
      // finalises; the test drives it forward via the client's terminate.
      unawaited(gw.onJingle(
        callerJid: Jid(local: alice.id, domain: _xmppDomain),
        calleeJid: Jid(local: '+15551234', domain: _sipDomain),
        jingle: jingle,
      ));

      // Wait for ringing to arrive so the INVITE is in-flight.
      await mock
          .awaitJingleAction('session-info')
          .timeout(const Duration(seconds: 3));

      // Client hangs up.
      final terminate =
          XmlDocument.parse(_terminate('sid-C1', reason: 'cancel')).rootElement;
      await gw.onJingle(
        callerJid: Jid(local: alice.id, domain: _xmppDomain),
        calleeJid: Jid(local: '+15551234', domain: _sipDomain),
        jingle: terminate,
      );

      await _waitFor(
        () => peerReceived.any((r) => r.method == 'CANCEL'),
        const Duration(seconds: 2),
      );
      expect(peerReceived.map((r) => r.method), contains('CANCEL'));

      // Call-log records a canceled outgoing call for alice.
      // Retry read since the finalResponse handler runs asynchronously.
      await _waitFor(
        () => callLog.listFor(alice.id).any((l) => l.state == 'canceled'),
        const Duration(seconds: 2),
      );
      final logs = callLog.listFor(alice.id);
      expect(logs.first.state, 'canceled');
      expect(
        metrics.render(),
        contains('rainbow_stub_sip_calls_total{outcome="canceled"} 1'),
      );

      await sub.cancel();
    });
  });
}

class _CapturingSession implements XmppSession {
  _CapturingSession({required this.jid, required this.userId});

  @override
  final Jid jid;
  @override
  final String userId;
  final List<String> stanzas = [];
  final _actionSignals = <String, Completer<XmlElement>>{};

  @override
  void send(String stanza) {
    stanzas.add(stanza);
    // Peek at the jingle action if it's an IQ carrying <jingle>.
    try {
      final el = XmlDocument.parse(stanza).rootElement;
      if (el.localName != 'iq') return;
      final j = el.getElement('jingle', namespace: 'urn:xmpp:jingle:1');
      if (j == null) return;
      final action = j.getAttribute('action');
      if (action == null) return;
      final c = _actionSignals[action];
      if (c != null && !c.isCompleted) c.complete(j);
    } catch (_) {
      /* not our stanza */
    }
  }

  Future<XmlElement> awaitJingleAction(String action) {
    // If already seen, return immediately.
    for (final stanza in stanzas) {
      try {
        final el = XmlDocument.parse(stanza).rootElement;
        if (el.localName != 'iq') continue;
        final j = el.getElement('jingle', namespace: 'urn:xmpp:jingle:1');
        if (j?.getAttribute('action') == action) {
          return Future.value(j);
        }
      } catch (_) {}
    }
    return (_actionSignals[action] ??= Completer<XmlElement>()).future;
  }

  List<String> jingleActionsSeen() {
    final out = <String>[];
    for (final stanza in stanzas) {
      try {
        final el = XmlDocument.parse(stanza).rootElement;
        if (el.localName != 'iq') continue;
        final j = el.getElement('jingle', namespace: 'urn:xmpp:jingle:1');
        final action = j?.getAttribute('action');
        if (action != null) out.add(action);
      } catch (_) {}
    }
    return out;
  }
}

Future<void> _waitFor(bool Function() predicate, Duration timeout) async {
  final sw = Stopwatch()..start();
  while (!predicate()) {
    if (sw.elapsed > timeout) {
      throw TimeoutException('predicate not satisfied in $timeout');
    }
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
}

// Build a syntactically valid SIP response.
String _buildResponse(
  SipRequest req,
  int code,
  String reason, {
  String? toTag,
  String? body,
  String? contact,
}) {
  final via = req.firstHeader('via')!.value();
  final from = req.firstHeader('from')!.value();
  final to = req.firstHeader('to')!.value();
  final callId = req.callId!;
  final cseq = req.parseCSeq();
  final toWithTag =
      to.contains(';tag=') ? to : (toTag == null ? to : '$to;tag=$toTag');
  final bodyBytes = body == null ? const <int>[] : utf8.encode(body);
  final sb = StringBuffer()
    ..write('SIP/2.0 $code $reason\r\n')
    ..write('Via: $via\r\n')
    ..write('From: $from\r\n')
    ..write('To: $toWithTag\r\n')
    ..write('Call-ID: $callId\r\n')
    ..write('CSeq: ${cseq.sequence} ${cseq.method}\r\n');
  if (contact != null) sb.write('Contact: <$contact>\r\n');
  if (body != null) {
    sb.write('Content-Type: application/sdp\r\n');
  }
  sb.write('Content-Length: ${bodyBytes.length}\r\n\r\n');
  if (body != null) sb.write(body);
  return sb.toString();
}

String _offerInitiate(String sid) => '''
<jingle xmlns="urn:xmpp:jingle:1" action="session-initiate"
        initiator="alice\@rainbow-stub.local/phone" sid="$sid">
  <content creator="initiator" name="audio" senders="both">
    <description xmlns="urn:xmpp:jingle:apps:rtp:1" media="audio">
      <payload-type id="111" name="opus" clockrate="48000" channels="2">
        <parameter name="minptime" value="10"/>
        <parameter name="useinbandfec" value="1"/>
      </payload-type>
      <payload-type id="0" name="PCMU" clockrate="8000"/>
      <rtcp-mux/>
    </description>
    <transport xmlns="urn:xmpp:jingle:transports:ice-udp:1"
               ufrag="8hhY" pwd="asd88fgpdd777uzjYhagZg">
      <fingerprint xmlns="urn:xmpp:jingle:apps:dtls:0"
                   hash="sha-256" setup="actpass">AB:CD:EF</fingerprint>
      <candidate component="1" foundation="1" generation="0" id="c1"
                 ip="10.0.1.1" network="1" port="8998"
                 priority="2130706431" protocol="udp" type="host"/>
    </transport>
  </content>
</jingle>
''';

String _terminate(String sid, {required String reason}) => '''
<jingle xmlns="urn:xmpp:jingle:1" action="session-terminate" sid="$sid">
  <reason><$reason/></reason>
</jingle>
''';

// Minimal callee-side SDP answer. Chrome/Firefox shape; opus only.
const _peerAnswerSdp = 'v=0\r\n'
    'o=- 1234 2 IN IP4 127.0.0.1\r\n'
    's=-\r\n'
    't=0 0\r\n'
    'm=audio 40000 UDP/TLS/RTP/SAVPF 111\r\n'
    'c=IN IP4 127.0.0.1\r\n'
    'a=rtcp-mux\r\n'
    'a=ice-ufrag:peerU\r\n'
    'a=ice-pwd:peerPasswordXXXXXXXXXXX\r\n'
    'a=fingerprint:sha-256 12:34:56\r\n'
    'a=setup:active\r\n'
    'a=mid:audio\r\n'
    'a=sendrecv\r\n'
    'a=rtpmap:111 opus/48000/2\r\n'
    'a=candidate:1 1 udp 2130706431 127.0.0.1 40000 typ host generation 0\r\n';
