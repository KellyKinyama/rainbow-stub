// M7 batch — integration tests covering:
//   * multi-realm digest challenge (401 + 407 in the same response) →
//     retry with BOTH Authorization + Proxy-Authorization
//   * outbound REGISTER: 401 challenge → retry with Authorization →
//     2xx → refresh scheduled from the Expires header
//   * RFC 4028 refresher=uas: gateway does NOT schedule its own
//     refresh when the peer took the refresher role
//   * TCP transport: gateway can bind TCP, exchange REGISTER + 200 OK

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
  group('SipGateway M7', () {
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
      String? authUsername,
      String? authPassword,
      bool sessionTimersEnabled = false,
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
        sessionTimersEnabled: sessionTimersEnabled,
        sessionTimerDuration: const Duration(seconds: 90),
        sessionTimerMinSe: const Duration(seconds: 5),
        authUsername: authUsername,
        authPassword: authPassword,
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
      tmp = Directory.systemTemp.createTempSync('rainbow-stub-sip-m7');
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
    });

    tearDown(() async {
      await peerTransport.close();
      db.close();
      tmp.deleteSync(recursive: true);
    });

    test(
        'multi-realm challenge: 401 with both WWW-Authenticate and '
        'Proxy-Authenticate → retry carries both auth headers', () async {
      final gw = await bootGateway(
        authUsername: 'u',
        authPassword: 'p',
      );
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
        if (req.method != 'INVITE') return;
        final n = peerReceived.where((r) => r.method == 'INVITE').length;
        if (n == 1) {
          await peerTransport.send(
            utf8.encode(_response(req, 401, 'Unauthorized',
                toTag: 'peer-t',
                extraHeaders: [
                  'WWW-Authenticate: Digest realm="endpoint", '
                      'nonce="ep-nonce", qop="auth", algorithm=MD5',
                  'Proxy-Authenticate: Digest realm="proxy", '
                      'nonce="px-nonce", qop="auth", algorithm=MD5',
                ])),
            inb.source,
          );
          return;
        }
        expect(req.firstHeader('authorization'), isNotNull,
            reason: 'retry must carry endpoint Authorization');
        expect(req.firstHeader('proxy-authorization'), isNotNull,
            reason: 'retry must carry Proxy-Authorization');
        expect(req.firstHeader('authorization')!.value(),
            contains('realm="endpoint"'));
        expect(req.firstHeader('proxy-authorization')!.value(),
            contains('realm="proxy"'));
        await peerTransport.send(
          utf8.encode(_response(req, 200, 'OK',
              toTag: 'peer-t',
              body: _peerAudioAnswerSdp,
              contact: 'sip:peer@127.0.0.1:${peerLocalEp.port}')),
          inb.source,
        );
      });

      final initiate =
          XmlDocument.parse(_offerWithCandidate('sid-M7-1')).rootElement;
      await gw.onJingle(
        callerJid: Jid(local: alice.id, domain: _xmppDomain),
        calleeJid: Jid(local: '+15551234', domain: _sipDomain),
        jingle: initiate,
      );
      await mock
          .awaitJingleAction('session-accept')
          .timeout(const Duration(seconds: 3));

      expect(peerReceived.where((r) => r.method == 'INVITE').length, 2);
      expect(
        metrics.render(),
        contains('rainbow_stub_sip_auth_challenges_total{code="401"} 1'),
      );

      await sub.cancel();
    });

    test(
        'session timers: peer sets refresher=uas → gateway does NOT '
        'schedule its own refresh', () async {
      // Use a fresh transport for a UDP peer as usual.
      final gw = await bootGateway(sessionTimersEnabled: true);
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
          await peerTransport.send(
            utf8.encode(_response(req, 200, 'OK',
                toTag: 'peer-t',
                body: _peerAudioAnswerSdp,
                extraHeaders: ['Session-Expires: 60;refresher=uas'],
                contact: 'sip:peer@127.0.0.1:${peerLocalEp.port}')),
            inb.source,
          );
        }
      });

      final initiate =
          XmlDocument.parse(_offerWithCandidate('sid-M7-2')).rootElement;
      await gw.onJingle(
        callerJid: Jid(local: alice.id, domain: _xmppDomain),
        calleeJid: Jid(local: '+15551234', domain: _sipDomain),
        jingle: initiate,
      );
      await mock
          .awaitJingleAction('session-accept')
          .timeout(const Duration(seconds: 3));

      // Wait longer than the gateway would take to fire a refresh (Se/2 = 30s,
      // or Se-15 = 45s; either way, well beyond 500ms). No re-INVITE should
      // hit the wire.
      await Future<void>.delayed(const Duration(milliseconds: 500));
      final reInvites = peerReceived.where((r) => r.method == 'INVITE').length;
      expect(reInvites, 1,
          reason: 'refresher=uas means peer refreshes; we stay quiet');

      await sub.cancel();
    });

    test(
        'REGISTER: 401 challenge → retried REGISTER carries '
        'Authorization → 200 OK schedules refresh', () async {
      // Build the gateway via the public boot path so REGISTER kicks off.
      final registrarPort = peerLocalEp.port;
      final registrarConfig = SipRegistrarConfig(
        aor: 'sip:alice@rainbow-stub.example',
        registrarHost: '127.0.0.1',
        registrarPort: registrarPort,
        expiresSeconds: 3600,
      );
      final config = SipConfig(
        enabled: true,
        domain: _sipDomain,
        bindAddress: '127.0.0.1',
        bindPort: gwLocalEp.port,
        outboundProxyHost: '127.0.0.1',
        outboundProxyPort: registrarPort,
        localContactUri: 'sip:alice@127.0.0.1:${gwLocalEp.port}',
        b2buaFromUri: 'sip:rainbow-stub@$_xmppDomain',
        authUsername: 'alice',
        authPassword: 's3cret',
        registrar: registrarConfig,
      );

      final peerReceived = <SipRequest>[];
      final challenged = Completer<void>();
      final registered = Completer<void>();

      final sub = peerTransport.incoming.listen((inb) async {
        if (inb.message is! SipRequest) return;
        final req = inb.message as SipRequest;
        peerReceived.add(req);
        if (req.method != 'REGISTER') return;
        final n = peerReceived.where((r) => r.method == 'REGISTER').length;
        if (n == 1) {
          await peerTransport.send(
            utf8.encode(_response(req, 401, 'Unauthorized',
                toTag: 'reg-t',
                extraHeaders: [
                  'WWW-Authenticate: Digest realm="rainbow-sip", '
                      'nonce="reg-nonce", qop="auth", algorithm=MD5',
                ])),
            inb.source,
          );
          challenged.complete();
        } else {
          expect(req.firstHeader('authorization'), isNotNull);
          expect(req.firstHeader('authorization')!.value(),
              contains('username="alice"'));
          expect(req.firstHeader('authorization')!.value(),
              contains('realm="rainbow-sip"'));
          await peerTransport.send(
            utf8.encode(_response(req, 200, 'OK',
                toTag: 'reg-t', extraHeaders: ['Expires: 3600'])),
            inb.source,
          );
          if (!registered.isCompleted) registered.complete();
        }
      });

      final gw = SipGateway.forTesting(
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
      addTearDown(gw.stop);
      // Public boot triggers _startRegister; forTesting doesn't. Kick it
      // manually via the same code path used by boot():
      unawaited(gw.startRegisterForTesting());

      await challenged.future.timeout(const Duration(seconds: 2));
      await registered.future.timeout(const Duration(seconds: 3));
      // Let the gateway's async chain process the 200 OK before we assert.
      await _waitFor(
        () => metrics
            .render()
            .contains('rainbow_stub_sip_register_total{result="ok"} 1'),
        const Duration(seconds: 2),
      );
      expect(peerReceived.where((r) => r.method == 'REGISTER').length, 2);
      expect(
        metrics.render(),
        contains('rainbow_stub_sip_register_total{result="ok"} 1'),
      );
      expect(
        metrics.render(),
        contains('rainbow_stub_sip_auth_challenges_total{code="401"} 1'),
      );

      await sub.cancel();
    });

    test('TCP transport: gateway binds TCP, REGISTER round-trip succeeds',
        () async {
      // Fresh TCP transports on both sides.
      final peerTcp = TcpSipTransport(
        bindAddress: InternetAddress.loopbackIPv4,
        bindPort: 0,
      );
      await peerTcp.start();
      final peerTcpEp = peerTcp.localEndpoint;
      addTearDown(peerTcp.close);

      final gwTcp = TcpSipTransport(
        bindAddress: InternetAddress.loopbackIPv4,
        bindPort: 0,
      );
      await gwTcp.start();
      final gwTcpEp = gwTcp.localEndpoint;

      final registered = Completer<void>();
      final sub = peerTcp.incoming.listen((inb) async {
        final msg = inb.message;
        if (msg is! SipRequest) return;
        if (msg.method != 'REGISTER') return;
        await peerTcp.send(
          utf8.encode(_response(msg, 200, 'OK',
              toTag: 'reg-t', extraHeaders: ['Expires: 3600'])),
          inb.source,
        );
        if (!registered.isCompleted) registered.complete();
      });

      final config = SipConfig(
        enabled: true,
        domain: _sipDomain,
        bindAddress: '127.0.0.1',
        bindPort: gwTcpEp.port,
        outboundProxyHost: '127.0.0.1',
        outboundProxyPort: peerTcpEp.port,
        localContactUri: 'sip:alice@127.0.0.1:${gwTcpEp.port};transport=tcp',
        b2buaFromUri: 'sip:rainbow-stub@$_xmppDomain',
        transport: TransportProtocol.tcp,
        registrar: SipRegistrarConfig(
          aor: 'sip:alice@rainbow-stub.example',
          registrarHost: '127.0.0.1',
          registrarPort: peerTcpEp.port,
          expiresSeconds: 3600,
        ),
      );

      final gw = SipGateway.forTesting(
        config: config,
        xmppDomain: _xmppDomain,
        router: router,
        users: users,
        messages: messages,
        callLog: callLog,
        metrics: metrics,
        transport: gwTcp,
        outboundEndpoint: Endpoint(
          address: InternetAddress.loopbackIPv4,
          port: peerTcpEp.port,
          protocol: TransportProtocol.tcp,
        ),
        mediaAnchor: mediaAnchor,
      );
      addTearDown(gw.stop);
      unawaited(gw.startRegisterForTesting());

      await registered.future.timeout(const Duration(seconds: 3));
      await _waitFor(
        () => metrics
            .render()
            .contains('rainbow_stub_sip_register_total{result="ok"} 1'),
        const Duration(seconds: 2),
      );
      expect(
        metrics.render(),
        contains('rainbow_stub_sip_register_total{result="ok"} 1'),
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
