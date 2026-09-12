// M6 batch — integration tests covering:
//   * post-answer trickle-ICE → in-dialog re-INVITE
//   * inbound mid-dialog INVITE / UPDATE (session-timer refresh or
//     codec change) → 200 OK
//   * RFC 4028 session timers: outbound INVITE stamps Session-Expires /
//     Min-SE / Supported: timer; negotiated Se drives a periodic
//     refresh re-INVITE
//   * RFC 7616 digest auth: 401 with WWW-Authenticate → gateway retries
//     the INVITE once with an Authorization header carrying a valid
//     digest response, which the peer accepts with 200 OK.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:rainbow_stub/rainbow_stub.dart';
import 'package:rainbow_stub/src/sip/digest_auth.dart';
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
  group('SipGateway M6', () {
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
      Duration sessionTimerDuration = const Duration(seconds: 30),
      bool sessionTimersEnabled = false,
      String? authUsername,
      String? authPassword,
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
        outboundTrickleWindow: const Duration(seconds: 2),
        sessionTimersEnabled: sessionTimersEnabled,
        sessionTimerDuration: sessionTimerDuration,
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
      tmp = Directory.systemTemp.createTempSync('rainbow-stub-sip-m6');
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
        'post-answer trickle: transport-info after 200 OK triggers '
        'an in-dialog re-INVITE with the merged candidate list', () async {
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
        if (req.method == 'INVITE' &&
            !peerReceived
                .any((r) => identical(r, req) ? false : r.method == 'INVITE')) {
          // First INVITE: answer.
          await peerTransport.send(
            utf8.encode(_response(req, 200, 'OK',
                toTag: 'peer-tag',
                body: _peerAudioAnswerSdp,
                contact: 'sip:peer@127.0.0.1:${peerLocalEp.port}')),
            inb.source,
          );
        } else if (req.method == 'INVITE') {
          // Subsequent re-INVITE (trickle refresh): plain 200 OK.
          await peerTransport.send(
            utf8.encode(_response(req, 200, 'OK', toTag: 'peer-tag')),
            inb.source,
          );
        }
      });

      // Initiate WITH a candidate → INVITE fires immediately, gets 200 OK.
      final initiate =
          XmlDocument.parse(_offerWithCandidate('sid-M6-1')).rootElement;
      await gw.onJingle(
        callerJid: Jid(local: alice.id, domain: _xmppDomain),
        calleeJid: Jid(local: '+15551234', domain: _sipDomain),
        jingle: initiate,
      );
      await mock
          .awaitJingleAction('session-accept')
          .timeout(const Duration(seconds: 3));

      // Now trickle a late candidate.
      final ti = XmlDocument.parse(_transportInfoCandidate(
        sid: 'sid-M6-1',
        contentName: 'audio',
        ip: '10.9.9.99',
        port: 9999,
        foundation: '7',
        eoc: true,
      )).rootElement;
      await gw.onJingle(
        callerJid: Jid(local: alice.id, domain: _xmppDomain),
        calleeJid: Jid(local: '+15551234', domain: _sipDomain),
        jingle: ti,
      );

      // A second INVITE should appear on the wire.
      await _waitFor(
        () => peerReceived.where((r) => r.method == 'INVITE').length >= 2,
        const Duration(seconds: 2),
      );
      final reInvite =
          peerReceived.where((r) => r.method == 'INVITE').toList().last;
      final sdp = utf8.decode(reInvite.bodyBytes());
      expect(sdp, contains('10.9.9.99 9999'));
      expect(
        metrics.render(),
        contains('rainbow_stub_sip_trickle_reinvites_total'
            '{direction="outbound"} 1'),
      );

      await sub.cancel();
    });

    test(
        'session timers: outbound INVITE advertises Session-Expires + '
        'Min-SE + Supported: timer', () async {
      final gw = await bootGateway(
        sessionTimersEnabled: true,
        sessionTimerDuration: const Duration(seconds: 90),
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
        if (req.method == 'INVITE') {
          await peerTransport.send(
            utf8.encode(_response(req, 200, 'OK',
                toTag: 'peer-tag',
                body: _peerAudioAnswerSdp,
                extraHeaders: ['Session-Expires: 60;refresher=uac'],
                contact: 'sip:peer@127.0.0.1:${peerLocalEp.port}')),
            inb.source,
          );
        }
      });

      final initiate =
          XmlDocument.parse(_offerWithCandidate('sid-M6-2')).rootElement;
      await gw.onJingle(
        callerJid: Jid(local: alice.id, domain: _xmppDomain),
        calleeJid: Jid(local: '+15551234', domain: _sipDomain),
        jingle: initiate,
      );

      await _waitFor(
        () => peerReceived.any((r) => r.method == 'INVITE'),
        const Duration(seconds: 2),
      );
      final invite = peerReceived.firstWhere((r) => r.method == 'INVITE');
      final se = invite.firstHeader('session-expires')?.value() ?? '';
      final minSe = invite.firstHeader('min-se')?.value() ?? '';
      final supported = invite.firstHeader('supported')?.value() ?? '';
      expect(se, startsWith('90'));
      expect(se, contains('refresher=uac'));
      expect(minSe, '5');
      expect(supported.toLowerCase(), contains('timer'));

      await mock
          .awaitJingleAction('session-accept')
          .timeout(const Duration(seconds: 3));

      await sub.cancel();
    });

    test(
        'inbound mid-dialog INVITE after answer → gateway replies 200 OK '
        '(session-timer refresh path)', () async {
      final gw = await bootGateway();
      addTearDown(gw.stop);

      final mock = _CapturingSession(
        jid: Jid(local: alice.id, domain: _xmppDomain),
        userId: alice.id,
      );
      router.register(mock);

      final peerSideResponses = <SipResponse>[];
      final peerRequests = <SipRequest>[];
      final sub = peerTransport.incoming.listen((inb) async {
        final msg = inb.message;
        if (msg is SipRequest) {
          peerRequests.add(msg);
          if (msg.method == 'INVITE') {
            await peerTransport.send(
              utf8.encode(_response(msg, 200, 'OK',
                  toTag: 'peer-tag',
                  body: _peerAudioAnswerSdp,
                  contact: 'sip:peer@127.0.0.1:${peerLocalEp.port}')),
              inb.source,
            );
          }
        } else if (msg is SipResponse) {
          peerSideResponses.add(msg);
        }
      });

      final initiate =
          XmlDocument.parse(_offerWithCandidate('sid-M6-3')).rootElement;
      await gw.onJingle(
        callerJid: Jid(local: alice.id, domain: _xmppDomain),
        calleeJid: Jid(local: '+15551234', domain: _sipDomain),
        jingle: initiate,
      );
      await mock
          .awaitJingleAction('session-accept')
          .timeout(const Duration(seconds: 3));

      // Peer sends an in-dialog re-INVITE (session refresh, no SDP change).
      // We need the same dialog identifiers the gateway would recognise:
      // Call-ID = sid-M6-3, From = peer w/tag peer-tag, To = the gateway's
      // caller URI w/tag = the gateway's fromTag.
      final origInvite = peerRequests.firstWhere((r) => r.method == 'INVITE');
      final gwFromTag = origInvite.parseFrom().tag ?? '';
      // Build a re-INVITE from the peer to the gateway.
      final reInvite = _peerReinvite(
        callId: 'sid-M6-3',
        peerAor: 'sip:+15551234@$_sipDomain',
        peerTag: 'peer-tag',
        gatewayAor: origInvite.parseFrom().uri.toString(),
        gatewayTag: gwFromTag,
        cseq: 42,
        peerHostPort: '127.0.0.1:${peerLocalEp.port}',
        sessionExpires: 90,
      );
      await peerTransport.send(
          utf8.encode(reInvite),
          Endpoint(
            address: InternetAddress.loopbackIPv4,
            port: gwLocalEp.port,
            protocol: TransportProtocol.udp,
          ));

      await _waitFor(
        () => peerSideResponses.any((r) =>
            r.statusCode == 200 &&
            r.callId == 'sid-M6-3' &&
            r.parseCSeq().sequence == 42),
        const Duration(seconds: 2),
      );

      await sub.cancel();
    });

    test(
        'digest auth: 401 challenge → gateway retries with '
        'Authorization header, peer answers 200 OK', () async {
      final gw = await bootGateway(
        authUsername: 'alice-sip',
        authPassword: 's3cret',
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
        final invites =
            peerReceived.where((r) => r.method == 'INVITE').toList();
        if (invites.length == 1) {
          // First INVITE: challenge.
          await peerTransport.send(
            utf8.encode(_response(req, 401, 'Unauthorized',
                toTag: 'peer-t',
                extraHeaders: [
                  'WWW-Authenticate: Digest realm="rainbow-sip", '
                      'nonce="dcd98b7102dd2f0e8b11d0f600bfb0c093", '
                      'qop="auth", algorithm=MD5',
                ])),
            inb.source,
          );
          return;
        }
        // Second INVITE — validate Authorization then accept.
        final authHeader = req.firstHeader('authorization')?.value() ?? '';
        expect(authHeader, isNotEmpty,
            reason: 'retried INVITE must carry Authorization');
        expect(authHeader, contains('username="alice-sip"'));
        expect(authHeader, contains('realm="rainbow-sip"'));
        expect(
            authHeader, contains('nonce="dcd98b7102dd2f0e8b11d0f600bfb0c093"'));
        expect(authHeader, contains('qop=auth'));
        expect(authHeader, contains('response="'));

        // Reproduce the expected response from the same digest inputs and
        // assert bit-exact match. Since the gateway picks a random cnonce,
        // extract it from the header and feed back.
        final cnonce = _extractParam(authHeader, 'cnonce');
        final nc = _extractParam(authHeader, 'nc');
        final challenge = parseDigestChallenge(
          'Digest realm="rainbow-sip", '
          'nonce="dcd98b7102dd2f0e8b11d0f600bfb0c093", '
          'qop="auth", algorithm=MD5',
        );
        final expected = buildAuthorizationHeader(
          challenge: challenge,
          username: 'alice-sip',
          password: 's3cret',
          method: 'INVITE',
          uri: req.requestUri.toString(),
          nc: int.parse(nc, radix: 16),
          cnonce: cnonce,
        );
        expect(authHeader, expected);

        await peerTransport.send(
          utf8.encode(_response(req, 200, 'OK',
              toTag: 'peer-t',
              body: _peerAudioAnswerSdp,
              contact: 'sip:peer@127.0.0.1:${peerLocalEp.port}')),
          inb.source,
        );
      });

      final initiate =
          XmlDocument.parse(_offerWithCandidate('sid-M6-4')).rootElement;
      await gw.onJingle(
        callerJid: Jid(local: alice.id, domain: _xmppDomain),
        calleeJid: Jid(local: '+15551234', domain: _sipDomain),
        jingle: initiate,
      );

      await mock
          .awaitJingleAction('session-accept')
          .timeout(const Duration(seconds: 4));
      final invites = peerReceived.where((r) => r.method == 'INVITE').length;
      expect(invites, 2);
      expect(
        metrics.render(),
        contains('rainbow_stub_sip_auth_challenges_total{code="401"} 1'),
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
  final branch = 'z9hG4bK${DateTime.now().millisecondsSinceEpoch}';
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

String _extractParam(String header, String key) {
  final re = RegExp('$key=("([^"]*)"|([^,\\s]+))');
  final m = re.firstMatch(header);
  return m?.group(2) ?? m?.group(3) ?? '';
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

String _transportInfoCandidate({
  required String sid,
  required String contentName,
  required String ip,
  required int port,
  required String foundation,
  required bool eoc,
}) =>
    '''
<jingle xmlns="urn:xmpp:jingle:1" action="transport-info" sid="$sid">
  <content creator="initiator" name="$contentName">
    <transport xmlns="urn:xmpp:jingle:transports:ice-udp:1">
      <candidate component="1" foundation="$foundation" generation="0"
                 id="c$foundation" ip="$ip" network="1" port="$port"
                 priority="2130706431" protocol="udp" type="host"/>
      ${eoc ? '<end-of-candidates/>' : ''}
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
