// M8 batch — RFC 4028 session-timer hardening:
//   * outbound call, peer is refresher (refresher=uas) but never
//     refreshes → gateway's guard timer fires → BYE + Jingle timeout
//   * inbound call refreshed once (peer INVITE with Se), then peer goes
//     silent → gateway tears the call down toward the peer + client
//   * a refresh INVITE whose Session-Expires is below our Min-SE →
//     gateway answers 422 Session Interval Too Small + Min-SE header

import 'dart:async';
import 'dart:convert';
import 'dart:io';

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

void main() {
  group('SipGateway M8 — session-timer hardening', () {
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

    Future<SipGateway> bootGateway({
      Duration sessionTimerMinSe = const Duration(seconds: 5),
    }) async {
      final config = SipConfig(
        enabled: true,
        domain: _sipDomain,
        bindAddress: '127.0.0.1',
        bindPort: gwLocalEp.port,
        outboundProxyHost: '127.0.0.1',
        outboundProxyPort: peerLocalEp.port,
        localContactUri: 'sip:b2bua@127.0.0.1:${gwLocalEp.port}',
        b2buaFromUri: 'sip:rainbow-stub@$_xmppDomain',
        sessionTimersEnabled: true,
        sessionTimerDuration: const Duration(seconds: 90),
        sessionTimerMinSe: sessionTimerMinSe,
        dids: const {'+15551234': 'target-user'},
      );
      return SipGateway.forTesting(
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

    setUp(() async {
      tmp = Directory.systemTemp.createTempSync('rainbow-stub-sip-m8');
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
      users.create(
        loginEmail: 'target@rainbow-stub.local',
        password: 'password',
        firstName: 'Target',
        lastName: 'User',
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
    });

    tearDown(() async {
      await peerTransport.close();
      db.close();
      tmp.deleteSync(recursive: true);
    });

    test(
        'outbound: peer is refresher (refresher=uas) but stays silent → '
        'guard timer fires → BYE + Jingle timeout + metric', () async {
      final gw = await bootGateway();
      addTearDown(gw.stop);

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
          // Answer, declaring the PEER as refresher with a very short Se
          // so the gateway's guard fires quickly.
          await peerTransport.send(
            utf8.encode(_response(req, 200, 'OK',
                toTag: 'peer-t',
                body: _peerAudioAnswerSdp,
                extraHeaders: ['Session-Expires: 1;refresher=uas'],
                contact: 'sip:peer@127.0.0.1:${peerLocalEp.port}')),
            inb.source,
          );
        }
      });

      final initiate =
          XmlDocument.parse(_offerWithCandidate('sid-M8-1')).rootElement;
      await gw.onJingle(
        callerJid: Jid(local: alice.id, domain: _xmppDomain),
        calleeJid: Jid(local: '+15551234', domain: _sipDomain),
        jingle: initiate,
      );
      await mock
          .awaitJingleAction('session-accept')
          .timeout(const Duration(seconds: 3));

      // Guard timer = full Se (1s). Wait for the BYE.
      await _waitFor(
        () => peerReceived.any((r) => r.method == 'BYE'),
        const Duration(seconds: 3),
      );
      final terminate = await mock
          .awaitJingleAction('session-terminate')
          .timeout(const Duration(seconds: 2));
      final reason = terminate.getElement('reason');
      expect(
          reason!.children.whereType<XmlElement>().first.name.local, 'timeout');
      expect(
        metrics.render(),
        contains('rainbow_stub_sip_session_expired_total'
            '{direction="outbound"} 1'),
      );

      await sub.cancel();
    });

    test(
        'outbound: peer refreshes in time → guard is re-armed, no '
        'premature teardown', () async {
      final gw = await bootGateway();
      addTearDown(gw.stop);

      final mock = _CapturingSession(
        jid: Jid(local: alice.id, domain: _xmppDomain),
        userId: alice.id,
      );
      router.register(mock);

      final peerReceived = <SipRequest>[];
      var gwFromTag = '';
      final sub = peerTransport.incoming.listen((inb) async {
        if (inb.message is! SipRequest) return;
        final req = inb.message as SipRequest;
        peerReceived.add(req);
        if (req.method == 'INVITE' &&
            peerReceived.where((r) => r.method == 'INVITE').length == 1) {
          gwFromTag = req.parseFrom().tag ?? '';
          await peerTransport.send(
            utf8.encode(_response(req, 200, 'OK',
                toTag: 'peer-t',
                body: _peerAudioAnswerSdp,
                extraHeaders: ['Session-Expires: 1;refresher=uas'],
                contact: 'sip:peer@127.0.0.1:${peerLocalEp.port}')),
            inb.source,
          );
        }
      });

      final initiate =
          XmlDocument.parse(_offerWithCandidate('sid-M8-2')).rootElement;
      await gw.onJingle(
        callerJid: Jid(local: alice.id, domain: _xmppDomain),
        calleeJid: Jid(local: '+15551234', domain: _sipDomain),
        jingle: initiate,
      );
      final accept = await mock
          .awaitJingleAction('session-accept')
          .timeout(const Duration(seconds: 3));
      expect(accept, isNotNull);

      // Peer refreshes just before the 1s guard fires.
      await Future<void>.delayed(const Duration(milliseconds: 600));
      final origInvite = peerReceived.firstWhere((r) => r.method == 'INVITE');
      final reInvite = _peerReinvite(
        callId: origInvite.callId!,
        peerAor: 'sip:+15551234@$_sipDomain',
        peerTag: 'peer-t',
        gatewayAor: origInvite.parseFrom().uri.toString(),
        gatewayTag: gwFromTag,
        cseq: 2,
        peerHostPort: '127.0.0.1:${peerLocalEp.port}',
        sessionExpires: 1,
      );
      await peerTransport.send(
        utf8.encode(reInvite),
        Endpoint(
          address: InternetAddress.loopbackIPv4,
          port: gwLocalEp.port,
          protocol: TransportProtocol.udp,
        ),
      );

      // Give the gateway a moment to answer + re-arm; no BYE should appear
      // before the fresh 1s guard elapses.
      await Future<void>.delayed(const Duration(milliseconds: 300));
      expect(peerReceived.any((r) => r.method == 'BYE'), isFalse,
          reason: 'refresh should re-arm the guard, not tear down');

      await sub.cancel();
    });

    test(
        'refresh below Min-SE → gateway answers 422 Session Interval Too '
        'Small with a Min-SE header', () async {
      final gw =
          await bootGateway(sessionTimerMinSe: const Duration(seconds: 90));
      addTearDown(gw.stop);

      final mock = _CapturingSession(
        jid: Jid(local: alice.id, domain: _xmppDomain),
        userId: alice.id,
      );
      router.register(mock);

      final peerRequests = <SipRequest>[];
      final peerResponses = <SipResponse>[];
      var gwFromTag = '';
      final sub = peerTransport.incoming.listen((inb) async {
        final msg = inb.message;
        if (msg is SipRequest) {
          peerRequests.add(msg);
          if (msg.method == 'INVITE' &&
              peerRequests.where((r) => r.method == 'INVITE').length == 1) {
            gwFromTag = msg.parseFrom().tag ?? '';
            await peerTransport.send(
              utf8.encode(_response(msg, 200, 'OK',
                  toTag: 'peer-t',
                  body: _peerAudioAnswerSdp,
                  contact: 'sip:peer@127.0.0.1:${peerLocalEp.port}')),
              inb.source,
            );
          }
        } else if (msg is SipResponse) {
          peerResponses.add(msg);
        }
      });

      final initiate =
          XmlDocument.parse(_offerWithCandidate('sid-M8-3')).rootElement;
      await gw.onJingle(
        callerJid: Jid(local: alice.id, domain: _xmppDomain),
        calleeJid: Jid(local: '+15551234', domain: _sipDomain),
        jingle: initiate,
      );
      await mock
          .awaitJingleAction('session-accept')
          .timeout(const Duration(seconds: 3));

      // Peer sends a refresh with Se=10, below our Min-SE=90.
      final origInvite = peerRequests.firstWhere((r) => r.method == 'INVITE');
      final reInvite = _peerReinvite(
        callId: origInvite.callId!,
        peerAor: 'sip:+15551234@$_sipDomain',
        peerTag: 'peer-t',
        gatewayAor: origInvite.parseFrom().uri.toString(),
        gatewayTag: gwFromTag,
        cseq: 2,
        peerHostPort: '127.0.0.1:${peerLocalEp.port}',
        sessionExpires: 10,
      );
      await peerTransport.send(
        utf8.encode(reInvite),
        Endpoint(
          address: InternetAddress.loopbackIPv4,
          port: gwLocalEp.port,
          protocol: TransportProtocol.udp,
        ),
      );

      await _waitFor(
        () => peerResponses
            .any((r) => r.statusCode == 422 && r.parseCSeq().sequence == 2),
        const Duration(seconds: 2),
      );
      final r422 = peerResponses.firstWhere((r) => r.statusCode == 422);
      expect(r422.firstHeader('min-se')?.value(), '90');
      expect(
        metrics.render(),
        contains('rainbow_stub_sip_session_422_total'),
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

String _response(
  SipRequest req,
  int code,
  String reason, {
  String? toTag,
  String? body,
  String? contact,
  List<String> extraHeaders = const [],
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
  for (final h in extraHeaders) {
    sb.write('$h\r\n');
  }
  if (contact != null) sb.write('Contact: <$contact>\r\n');
  if (body != null) sb.write('Content-Type: application/sdp\r\n');
  sb.write('Content-Length: ${bodyBytes.length}\r\n\r\n');
  if (body != null) sb.write(body);
  return sb.toString();
}

String _peerReinvite({
  required String callId,
  required String peerAor,
  required String peerTag,
  required String gatewayAor,
  required String gatewayTag,
  required int cseq,
  required String peerHostPort,
  int? sessionExpires,
}) {
  final branch = 'z9hG4bK${DateTime.now().microsecondsSinceEpoch}';
  final sb = StringBuffer()
    ..write('INVITE $gatewayAor SIP/2.0\r\n')
    ..write('Via: SIP/2.0/UDP $peerHostPort;branch=$branch\r\n')
    ..write('From: <$peerAor>;tag=$peerTag\r\n')
    ..write('To: <$gatewayAor>;tag=$gatewayTag\r\n')
    ..write('Call-ID: $callId\r\n')
    ..write('CSeq: $cseq INVITE\r\n')
    ..write('Max-Forwards: 70\r\n')
    ..write('Contact: <sip:peer@$peerHostPort>\r\n');
  if (sessionExpires != null) {
    sb.write('Session-Expires: $sessionExpires;refresher=uas\r\n');
    sb.write('Supported: timer\r\n');
  }
  sb.write('Content-Length: 0\r\n\r\n');
  return sb.toString();
}

String _offerWithCandidate(String sid) => '''
<jingle xmlns="urn:xmpp:jingle:1" action="session-initiate"
        initiator="alice@rainbow-stub.local/phone" sid="$sid">
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

const _peerAudioAnswerSdp = 'v=0\r\n'
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
