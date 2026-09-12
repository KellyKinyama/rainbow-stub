// M4 tests — DTMF and hold/unhold on an active bridged call.
//
// Covers:
//   * Outbound DTMF: phone sends <session-info><dtmf digit="1"/></session-info>
//     → RtpengineClient.injectDtmf hits /calls/{sid}/dtmf; metric ticks.
//   * Outbound hold + unhold: phone sends <hold/>/<unhold/> → peer sees a
//     re-INVITE whose SDP body carries a=sendonly / a=sendrecv; the rtpengine
//     offer endpoint is called again with the updated SDP; metrics tick.
//   * Inbound DTMF: after the callee accepts the SIP call, phone injects a
//     digit via <dtmf/> — rtpengine gets the call.

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
  group('SipGateway M4 — session-info: DTMF + hold', () {
    late Directory tmp;
    late AppDatabase db;
    late UserRepository users;
    late MessageRepository messages;
    late CallLogRepository callLog;
    late StanzaRouter router;
    late MetricsRegistry metrics;
    late User alice;
    late FakeRtpengine fake;
    late FakeRtpengineTransport fakeTransport;
    late RtpengineClient rtpClient;
    late MediaAnchor mediaAnchor;

    late UdpSipTransport gwTransport;
    late UdpSipTransport peerTransport;
    late Endpoint peerLocalEp;
    late Endpoint gwLocalEp;
    late SipGateway gw;

    setUp(() async {
      tmp = Directory.systemTemp.createTempSync('rainbow-stub-sip-m4');
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
      fakeTransport = FakeRtpengineTransport(fake.handle);
      rtpClient = RtpengineClient(transport: fakeTransport);
      mediaAnchor = MediaAnchor(client: rtpClient);

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
        dids: {'+18885551234': alice.id},
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
        rtpengineClient: rtpClient,
      );
    });

    tearDown(() async {
      await gw.stop();
      await peerTransport.close();
      db.close();
      tmp.deleteSync(recursive: true);
    });

    test('outbound DTMF injects to rtpengine on the client-side leg', () async {
      final phone = _CapturingSession(
        jid: Jid(local: alice.id, domain: _xmppDomain, resource: 'phone'),
        userId: alice.id,
      );
      router.register(phone);

      // Peer auto-answers INVITE with 200 OK.
      final sub = peerTransport.incoming.listen((inb) async {
        if (inb.message is! SipRequest) return;
        final req = inb.message as SipRequest;
        if (req.method != 'INVITE') return;
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
      });

      final initiate =
          XmlDocument.parse(_offerInitiate('sid-dtmf1')).rootElement;
      await gw.onJingle(
        callerJid: Jid(local: alice.id, domain: _xmppDomain, resource: 'phone'),
        calleeJid: Jid(local: '+15551234', domain: _sipDomain),
        jingle: initiate,
      );

      await phone
          .awaitJingleAction('session-accept')
          .timeout(const Duration(seconds: 3));

      // Phone injects DTMF '1'.
      final dtmfXml =
          XmlDocument.parse(_dtmfInfo('sid-dtmf1', digit: '1')).rootElement;
      await gw.onJingle(
        callerJid: Jid(local: alice.id, domain: _xmppDomain, resource: 'phone'),
        calleeJid: Jid(local: '+15551234', domain: _sipDomain),
        jingle: dtmfXml,
      );

      // rtpengine got a POST /calls/sid-dtmf1/dtmf.
      await _waitFor(
        () => fakeTransport.requests.any((r) =>
            r.method == 'POST' &&
            r.path == '/calls/sid-dtmf1/dtmf' &&
            (r.body?['event'] == '1')),
        const Duration(seconds: 2),
      );

      // Metric ticked.
      expect(
        metrics.render(),
        contains(
          'rainbow_stub_sip_dtmf_out_total{direction="outbound"} 1',
        ),
      );

      await sub.cancel();
    });

    test('outbound hold → re-INVITE with a=sendonly + rtpengine re-offer',
        () async {
      final phone = _CapturingSession(
        jid: Jid(local: alice.id, domain: _xmppDomain, resource: 'phone'),
        userId: alice.id,
      );
      router.register(phone);

      final peerReceived = <SipRequest>[];
      final sub = peerTransport.incoming.listen((inb) async {
        if (inb.message is! SipRequest) return;
        final req = inb.message as SipRequest;
        peerReceived.add(req);
        if (req.method == 'INVITE' && (req.parseCSeq().sequence == 1)) {
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

      final initiate =
          XmlDocument.parse(_offerInitiate('sid-hold1')).rootElement;
      await gw.onJingle(
        callerJid: Jid(local: alice.id, domain: _xmppDomain, resource: 'phone'),
        calleeJid: Jid(local: '+15551234', domain: _sipDomain),
        jingle: initiate,
      );

      await phone
          .awaitJingleAction('session-accept')
          .timeout(const Duration(seconds: 3));

      // Phone puts the call on hold.
      final hold = XmlDocument.parse(_holdInfo('sid-hold1')).rootElement;
      await gw.onJingle(
        callerJid: Jid(local: alice.id, domain: _xmppDomain, resource: 'phone'),
        calleeJid: Jid(local: '+15551234', domain: _sipDomain),
        jingle: hold,
      );

      // A second INVITE (re-INVITE) should reach the peer.
      await _waitFor(
        () => peerReceived.where((r) => r.method == 'INVITE').length >= 2,
        const Duration(seconds: 2),
      );
      final reInvite = peerReceived.where((r) => r.method == 'INVITE').last;
      final body = utf8.decode(reInvite.bodyBytes());
      expect(body, contains('a=sendonly'));
      expect(body, isNot(contains('a=sendrecv')));

      // rtpengine received a block-media call for the client leg.
      expect(
        fakeTransport.requests.any((r) =>
            r.method == 'POST' &&
            r.path.startsWith('/calls/sid-hold1/legs/') &&
            r.path.endsWith('/block/media')),
        isTrue,
      );

      expect(
        metrics.render(),
        contains('rainbow_stub_sip_holds_total{action="hold"} 1'),
      );

      // Unhold.
      final unhold = XmlDocument.parse(_unholdInfo('sid-hold1')).rootElement;
      await gw.onJingle(
        callerJid: Jid(local: alice.id, domain: _xmppDomain, resource: 'phone'),
        calleeJid: Jid(local: '+15551234', domain: _sipDomain),
        jingle: unhold,
      );

      await _waitFor(
        () => peerReceived.where((r) => r.method == 'INVITE').length >= 3,
        const Duration(seconds: 2),
      );
      final resumeInvite = peerReceived.where((r) => r.method == 'INVITE').last;
      final resumeBody = utf8.decode(resumeInvite.bodyBytes());
      expect(resumeBody, contains('a=sendrecv'));

      expect(
        fakeTransport.requests.any((r) =>
            r.method == 'POST' &&
            r.path.startsWith('/calls/sid-hold1/legs/') &&
            r.path.endsWith('/unblock/media')),
        isTrue,
      );

      expect(
        metrics.render(),
        contains('rainbow_stub_sip_holds_total{action="unhold"} 1'),
      );

      await sub.cancel();
    });

    test('inbound DTMF after accept → rtpengine sees the digit', () async {
      final phone = _CapturingSession(
        jid: Jid(local: alice.id, domain: _xmppDomain, resource: 'phone'),
        userId: alice.id,
      );
      router.register(phone);

      // Peer auto-ACKs any 2xx.
      final peerReceived = <SipRequest>[];
      SipRequest? outgoingInvite;
      final sub = peerTransport.incoming.listen((inb) async {
        if (inb.message is SipRequest) {
          peerReceived.add(inb.message as SipRequest);
          return;
        }
        final resp = inb.message as SipResponse;
        if (resp.statusCode >= 200 &&
            resp.statusCode < 300 &&
            resp.callId == 'sip-in-dtmf' &&
            outgoingInvite != null) {
          await peerTransport.send(
            utf8.encode(_buildAckFor2xx(outgoingInvite!, resp)),
            inb.source,
          );
        }
      });

      final wire = _buildInvite(
        callId: 'sip-in-dtmf',
        from: 'sip:+15551234@peer.example',
        to: 'sip:+18885551234@$_sipDomain',
        peerEp: peerLocalEp,
        body: _peerOfferSdp,
        branch: 'z9hG4bK-in-dtmf',
      );
      outgoingInvite =
          _parser.parse(Uint8List.fromList(utf8.encode(wire))) as SipRequest;
      await peerTransport.send(utf8.encode(wire), gwLocalEp);

      // Phone receives session-initiate; accepts.
      final init = await phone
          .awaitJingleAction('session-initiate')
          .timeout(const Duration(seconds: 3));
      final sid = init.getAttribute('sid')!;

      final acceptXml = XmlDocument.parse(_answerAccept(sid)).rootElement;
      await gw.onJingle(
        callerJid: Jid(local: alice.id, domain: _xmppDomain, resource: 'phone'),
        calleeJid: Jid(local: '+15551234', domain: _sipDomain),
        jingle: acceptXml,
      );

      // Phone injects DTMF '#'. answeredAt is set synchronously by the
      // session-accept handler above so the DTMF path is unlocked.
      final dtmfXml = XmlDocument.parse(_dtmfInfo(sid, digit: '#')).rootElement;
      await gw.onJingle(
        callerJid: Jid(local: alice.id, domain: _xmppDomain, resource: 'phone'),
        calleeJid: Jid(local: '+15551234', domain: _sipDomain),
        jingle: dtmfXml,
      );

      await _waitFor(
        () => fakeTransport.requests.any((r) =>
            r.method == 'POST' &&
            r.path == '/calls/sip-in-dtmf/dtmf' &&
            r.body?['event'] == '#'),
        const Duration(seconds: 2),
      );
      expect(
        metrics.render(),
        contains(
          'rainbow_stub_sip_dtmf_out_total{direction="inbound"} 1',
        ),
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
    try {
      final el = XmlDocument.parse(stanza).rootElement;
      if (el.localName != 'iq') return;
      final j = el.getElement('jingle', namespace: 'urn:xmpp:jingle:1');
      if (j == null) return;
      final action = j.getAttribute('action');
      if (action == null) return;
      final c = _actionSignals[action];
      if (c != null && !c.isCompleted) c.complete(j);
    } catch (_) {}
  }

  Future<XmlElement> awaitJingleAction(String action) {
    for (final stanza in stanzas) {
      try {
        final el = XmlDocument.parse(stanza).rootElement;
        if (el.localName != 'iq') continue;
        final j = el.getElement('jingle', namespace: 'urn:xmpp:jingle:1');
        if (j?.getAttribute('action') == action) return Future.value(j);
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
  if (body != null) sb.write('Content-Type: application/sdp\r\n');
  sb.write('Content-Length: ${bodyBytes.length}\r\n\r\n');
  if (body != null) sb.write(body);
  return sb.toString();
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

String _offerInitiate(String sid) => '''
<jingle xmlns="urn:xmpp:jingle:1" action="session-initiate"
        initiator="alice\@rainbow-stub.local/phone" sid="$sid">
  <content creator="initiator" name="audio" senders="both">
    <description xmlns="urn:xmpp:jingle:apps:rtp:1" media="audio">
      <payload-type id="111" name="opus" clockrate="48000" channels="2"/>
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

String _dtmfInfo(String sid, {required String digit}) => '''
<jingle xmlns="urn:xmpp:jingle:1" action="session-info" sid="$sid">
  <dtmf xmlns="urn:xmpp:jingle:dtmf:0" digit="$digit"/>
</jingle>
''';

String _holdInfo(String sid) => '''
<jingle xmlns="urn:xmpp:jingle:1" action="session-info" sid="$sid">
  <hold xmlns="urn:xmpp:jingle:apps:rtp:info:1"/>
</jingle>
''';

String _unholdInfo(String sid) => '''
<jingle xmlns="urn:xmpp:jingle:1" action="session-info" sid="$sid">
  <unhold xmlns="urn:xmpp:jingle:apps:rtp:info:1"/>
</jingle>
''';

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
