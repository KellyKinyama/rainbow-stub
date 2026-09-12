// M3 tests — inbound PSTN INVITE → XMPP session-initiate → first-accept-wins
// → 200 OK; peer BYE → XMPP session-terminate.
//
// Covers:
//   * Unknown DID → 404.
//   * No active sessions → 480 + call-log 'missed'.
//   * Full accept path with multi-device fanout: phone accepts, web retracts,
//     peer receives 200 with rewritten SDP, ACK arrives, peer BYE → phone
//     session-terminate; call-log 'answered' for alice.
//   * Client rejects → 486 Busy Here, call-log 'declined'.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:rainbow_stub/rainbow_stub.dart';
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
  group('SipGateway M3 — inbound Jingle ← SIP call', () {
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

    Future<void> setUpWith({Map<String, String>? dids}) async {
      tmp = Directory.systemTemp.createTempSync('rainbow-stub-sip-m3');
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
        dids: dids ?? {'+18885551234': alice.id},
        inboundRingTimeout: const Duration(seconds: 5),
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
    }

    tearDown(() async {
      await gw.stop();
      await peerTransport.close();
      db.close();
      tmp.deleteSync(recursive: true);
    });

    test('unknown DID → 404 Not Found', () async {
      await setUpWith();
      final peerResponses = _collectResponses(peerTransport);
      final wire = _buildInvite(
        callId: 'sip-unknown',
        from: 'sip:+15550000@peer.example',
        to: 'sip:+15559999@$_sipDomain',
        peerEp: peerLocalEp,
        body: _peerOfferSdp,
        branch: 'z9hG4bK-u1',
      );
      await peerTransport.send(utf8.encode(wire), gwLocalEp);
      final resp = await peerResponses
          .firstWhere((r) => r.statusCode >= 200 && r.callId == 'sip-unknown')
          .timeout(const Duration(seconds: 3));
      expect(resp.statusCode, 404);
    });

    test('no active sessions → 480 Temporarily Unavailable, call-log missed',
        () async {
      await setUpWith();
      final peerResponses = _collectResponses(peerTransport);
      final wire = _buildInvite(
        callId: 'sip-nosess',
        from: 'sip:+15551234@peer.example',
        to: 'sip:+18885551234@$_sipDomain',
        peerEp: peerLocalEp,
        body: _peerOfferSdp,
        branch: 'z9hG4bK-n1',
      );
      await peerTransport.send(utf8.encode(wire), gwLocalEp);
      final resp = await peerResponses
          .firstWhere((r) => r.statusCode >= 200 && r.callId == 'sip-nosess')
          .timeout(const Duration(seconds: 3));
      expect(resp.statusCode, 480);
      final logs = callLog.listFor(alice.id);
      expect(logs, hasLength(1));
      expect(logs.single.direction, 'incoming');
      expect(logs.single.state, 'missed');
      expect(logs.single.peerJid, '+15551234@$_sipDomain');
      expect(
        metrics.render(),
        contains('rainbow_stub_sip_calls_total{outcome="missed"} 1'),
      );
    });

    test('multi-device ring → first accept wins → 200 OK → peer BYE', () async {
      await setUpWith();
      final phone = _CapturingSession(
        jid: Jid(local: alice.id, domain: _xmppDomain, resource: 'phone'),
        userId: alice.id,
      );
      final web = _CapturingSession(
        jid: Jid(local: alice.id, domain: _xmppDomain, resource: 'web'),
        userId: alice.id,
      );
      router.register(phone);
      router.register(web);

      // Peer sends INVITE and auto-ACKs any 2xx.
      final peerReceived = <SipRequest>[];
      final peerResponses = <SipResponse>[];
      SipRequest? outgoingInvite;
      final sub = peerTransport.incoming.listen((inb) async {
        if (inb.message is SipRequest) {
          peerReceived.add(inb.message as SipRequest);
          return;
        }
        final resp = inb.message as SipResponse;
        peerResponses.add(resp);
        if (resp.statusCode >= 200 &&
            resp.statusCode < 300 &&
            resp.callId == 'sip-ok' &&
            outgoingInvite != null) {
          await peerTransport.send(
            utf8.encode(_buildAckFor2xx(outgoingInvite!, resp)),
            inb.source,
          );
        }
      });

      final wire = _buildInvite(
        callId: 'sip-ok',
        from: 'sip:+15551234@peer.example',
        to: 'sip:+18885551234@$_sipDomain',
        peerEp: peerLocalEp,
        body: _peerOfferSdp,
        branch: 'z9hG4bK-ok1',
      );
      outgoingInvite = _parser.parse(
        Uint8List.fromList(utf8.encode(wire)),
      ) as SipRequest;
      await peerTransport.send(utf8.encode(wire), gwLocalEp);

      // Both sessions should receive session-initiate.
      final phoneInit = await phone
          .awaitJingleAction('session-initiate')
          .timeout(const Duration(seconds: 3));
      final webInit = await web
          .awaitJingleAction('session-initiate')
          .timeout(const Duration(seconds: 3));
      final sid = phoneInit.getAttribute('sid');
      expect(sid, isNotNull);
      expect(webInit.getAttribute('sid'), sid);
      expect(phoneInit.getAttribute('initiator'), '+15551234@$_sipDomain');

      // 180 Ringing should have hit the peer.
      await _waitFor(
        () => peerResponses.any((r) => r.statusCode == 180),
        const Duration(seconds: 2),
      );

      // Phone accepts.
      final acceptXml = XmlDocument.parse(_answerAccept(sid!)).rootElement;
      await gw.onJingle(
        callerJid: Jid(local: alice.id, domain: _xmppDomain, resource: 'phone'),
        calleeJid: Jid(local: '+15551234', domain: _sipDomain),
        jingle: acceptXml,
      );

      // Peer should get a 200 OK for the INVITE.
      await _waitFor(
        () => peerResponses.any((r) =>
            r.statusCode == 200 &&
            r.callId == 'sip-ok' &&
            r.parseCSeq().method == 'INVITE'),
        const Duration(seconds: 3),
      );
      final ok = peerResponses.firstWhere(
        (r) => r.statusCode == 200 && r.parseCSeq().method == 'INVITE',
      );
      expect(ok.bodyBytes(), isNotEmpty);

      // Web should get a session-terminate (retract).
      final webRetract = await web
          .awaitJingleAction('session-terminate')
          .timeout(const Duration(seconds: 2));
      expect(
        webRetract
            .getElement('reason')
            ?.children
            .whereType<XmlElement>()
            .first
            .name
            .local,
        'cancel',
      );

      // gauge & call-log rows.
      expect(
        metrics.render(),
        contains('rainbow_stub_sip_calls_active 1'),
      );
      expect(
        metrics.render(),
        contains('rainbow_stub_sip_calls_total{outcome="answered"} 1'),
      );
      final logsBefore = callLog.listFor(alice.id);
      expect(logsBefore, hasLength(1));
      expect(logsBefore.single.state, 'answered');
      expect(logsBefore.single.direction, 'incoming');

      // Peer hangs up with BYE. Build BYE from the confirmed dialog.
      final byeCallId = ok.callId!;
      final peerContact = 'sip:peer@127.0.0.1:${peerLocalEp.port}';
      final bye = _buildBye(
        callId: byeCallId,
        fromHeader: ok.firstHeader('from')!.value(),
        toHeader: ok.firstHeader('to')!.value(),
        requestUri: 'sip:b2bua@127.0.0.1:${gwLocalEp.port}',
        cseq: 2,
        branch: 'z9hG4bK-bye1',
        contact: peerContact,
        peerEp: peerLocalEp,
      );
      await peerTransport.send(utf8.encode(bye), gwLocalEp);

      // Peer should get 200 for the BYE.
      await _waitFor(
        () => peerResponses.any((r) =>
            r.statusCode == 200 &&
            r.callId == byeCallId &&
            r.parseCSeq().method == 'BYE'),
        const Duration(seconds: 3),
      );

      // Phone should get session-terminate reason=success.
      final phoneEnd = await phone
          .awaitJingleAction('session-terminate')
          .timeout(const Duration(seconds: 2));
      expect(
        phoneEnd
            .getElement('reason')
            ?.children
            .whereType<XmlElement>()
            .first
            .name
            .local,
        'success',
      );

      // Active gauge back to 0.
      expect(
        metrics.render(),
        contains('rainbow_stub_sip_calls_active 0'),
      );

      await sub.cancel();
    });

    test('client rejects incoming call → 486 Busy Here', () async {
      await setUpWith();
      final phone = _CapturingSession(
        jid: Jid(local: alice.id, domain: _xmppDomain, resource: 'phone'),
        userId: alice.id,
      );
      router.register(phone);

      final peerResponses = _collectResponses(peerTransport);

      final wire = _buildInvite(
        callId: 'sip-rej',
        from: 'sip:+15551234@peer.example',
        to: 'sip:+18885551234@$_sipDomain',
        peerEp: peerLocalEp,
        body: _peerOfferSdp,
        branch: 'z9hG4bK-r1',
      );
      await peerTransport.send(utf8.encode(wire), gwLocalEp);

      final init = await phone
          .awaitJingleAction('session-initiate')
          .timeout(const Duration(seconds: 3));
      final sid = init.getAttribute('sid')!;

      // Client rejects.
      final term =
          XmlDocument.parse(_terminate(sid, reason: 'decline')).rootElement;
      await gw.onJingle(
        callerJid: Jid(local: alice.id, domain: _xmppDomain, resource: 'phone'),
        calleeJid: Jid(local: '+15551234', domain: _sipDomain),
        jingle: term,
      );

      final resp = await peerResponses
          .firstWhere((r) => r.statusCode >= 400 && r.callId == 'sip-rej')
          .timeout(const Duration(seconds: 3));
      expect(resp.statusCode, 486);

      final logs = callLog.listFor(alice.id);
      expect(logs, hasLength(1));
      expect(logs.single.state, 'declined');
      expect(
        metrics.render(),
        contains('rainbow_stub_sip_calls_total{outcome="declined"} 1'),
      );
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

Stream<SipResponse> _collectResponses(SipTransport t) {
  final c = StreamController<SipResponse>.broadcast();
  t.incoming.listen((inb) {
    if (inb.message is SipResponse) c.add(inb.message as SipResponse);
  });
  return c.stream;
}

String _buildInvite({
  required String callId,
  required String from,
  required String to,
  required Endpoint peerEp,
  required String body,
  required String branch,
}) {
  final bodyBytes = utf8.encode(body);
  return 'INVITE $to SIP/2.0\r\n'
      'Via: SIP/2.0/UDP 127.0.0.1:${peerEp.port};branch=$branch\r\n'
      'Max-Forwards: 70\r\n'
      'From: <$from>;tag=peer-from\r\n'
      'To: <$to>\r\n'
      'Call-ID: $callId\r\n'
      'CSeq: 1 INVITE\r\n'
      'Contact: <sip:peer@127.0.0.1:${peerEp.port}>\r\n'
      'Content-Type: application/sdp\r\n'
      'Content-Length: ${bodyBytes.length}\r\n'
      '\r\n'
      '$body';
}

String _buildBye({
  required String callId,
  required String fromHeader,
  required String toHeader,
  required String requestUri,
  required int cseq,
  required String branch,
  required String contact,
  required Endpoint peerEp,
}) {
  return 'BYE $requestUri SIP/2.0\r\n'
      'Via: SIP/2.0/UDP 127.0.0.1:${peerEp.port};branch=$branch\r\n'
      'Max-Forwards: 70\r\n'
      'From: $fromHeader\r\n'
      'To: $toHeader\r\n'
      'Call-ID: $callId\r\n'
      'CSeq: $cseq BYE\r\n'
      'Contact: <$contact>\r\n'
      'Content-Length: 0\r\n'
      '\r\n';
}

String _buildAckFor2xx(SipRequest invite, SipResponse ok) {
  final callId = invite.callId!;
  final fromHeader = invite.firstHeader('from')!.value();
  final toHeader = ok.firstHeader('to')!.value();
  final ru = invite.requestUri;
  return 'ACK $ru SIP/2.0\r\n'
      'Via: ${invite.firstHeader('via')!.value()}\r\n'
      'Max-Forwards: 70\r\n'
      'From: $fromHeader\r\n'
      'To: $toHeader\r\n'
      'Call-ID: $callId\r\n'
      'CSeq: ${invite.parseCSeq().sequence} ACK\r\n'
      'Content-Length: 0\r\n'
      '\r\n';
}

/// Client-side session-accept that mirrors the offer (rtpengine echoes
/// through unchanged in the FakeRtpengine).
String _answerAccept(String sid) => '''
<jingle xmlns="urn:xmpp:jingle:1" action="session-accept" sid="$sid">
  <content creator="initiator" name="audio" senders="both">
    <description xmlns="urn:xmpp:jingle:apps:rtp:1" media="audio">
      <payload-type id="111" name="opus" clockrate="48000" channels="2"/>
      <rtcp-mux/>
    </description>
    <transport xmlns="urn:xmpp:jingle:transports:ice-udp:1"
               ufrag="clientU" pwd="clientPasswordXXXXXXXXX">
      <fingerprint xmlns="urn:xmpp:jingle:apps:dtls:0"
                   hash="sha-256" setup="active">DE:AD:BE:EF</fingerprint>
      <candidate component="1" foundation="1" generation="0" id="c1"
                 ip="10.0.1.55" network="1" port="42000"
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

/// Minimal peer-side SDP offer.
const _peerOfferSdp = 'v=0\r\n'
    'o=- 5678 1 IN IP4 127.0.0.1\r\n'
    's=-\r\n'
    't=0 0\r\n'
    'm=audio 40000 UDP/TLS/RTP/SAVPF 111\r\n'
    'c=IN IP4 127.0.0.1\r\n'
    'a=rtcp-mux\r\n'
    'a=ice-ufrag:peerU\r\n'
    'a=ice-pwd:peerPasswordXXXXXXXXXXX\r\n'
    'a=fingerprint:sha-256 AA:BB:CC\r\n'
    'a=setup:actpass\r\n'
    'a=mid:audio\r\n'
    'a=sendrecv\r\n'
    'a=rtpmap:111 opus/48000/2\r\n'
    'a=candidate:1 1 udp 2130706431 127.0.0.1 40000 typ host generation 0\r\n';
