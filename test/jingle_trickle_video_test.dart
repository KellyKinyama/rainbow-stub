// M5 tests — RFC 8840 half-trickle ICE (buffered outbound INVITE) and
// multi-content (audio + video) passthrough. Extends the M2 outbound
// coverage in jingle_call_signaling_test.dart.

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
  group('SipGateway M5', () {
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
      tmp = Directory.systemTemp.createTempSync('rainbow-stub-sip-m5');
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
        // Long enough that the timer path is exercised only when tests
        // deliberately withhold end-of-candidates.
        outboundTrickleWindow: const Duration(seconds: 2),
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

    test(
        'trickle-ICE: initiate with no candidates buffers INVITE; '
        'end-of-candidates fires it', () async {
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
            utf8.encode(_buildResponse(
              req,
              200,
              'OK',
              toTag: 'peer-tag',
              body: _peerAudioAnswerSdp,
              contact: 'sip:peer@127.0.0.1:${peerLocalEp.port}',
            )),
            inb.source,
          );
        }
      });

      // Session-initiate with NO candidates: half-trickle mode.
      final initiate =
          XmlDocument.parse(_initiateNoCandidates('sid-T1')).rootElement;
      unawaited(gw.onJingle(
        callerJid: Jid(local: alice.id, domain: _xmppDomain),
        calleeJid: Jid(local: '+15551234', domain: _sipDomain),
        jingle: initiate,
      ));

      // Assert the INVITE has NOT fired yet — quick beat, then check the
      // wire is silent.
      await Future<void>.delayed(const Duration(milliseconds: 80));
      expect(peerReceived.where((r) => r.method == 'INVITE'), isEmpty,
          reason: 'INVITE should be buffered until end-of-candidates');

      // Trickle a candidate.
      final ti1 = XmlDocument.parse(_transportInfoCandidate(
        sid: 'sid-T1',
        contentName: 'audio',
        ip: '10.9.9.9',
        port: 9001,
        foundation: '2',
        eoc: false,
      )).rootElement;
      await gw.onJingle(
        callerJid: Jid(local: alice.id, domain: _xmppDomain),
        calleeJid: Jid(local: '+15551234', domain: _sipDomain),
        jingle: ti1,
      );

      // Still buffered.
      await Future<void>.delayed(const Duration(milliseconds: 40));
      expect(peerReceived.where((r) => r.method == 'INVITE'), isEmpty);

      // Now fire end-of-candidates with the last one — INVITE should go.
      final ti2 = XmlDocument.parse(_transportInfoCandidate(
        sid: 'sid-T1',
        contentName: 'audio',
        ip: '10.9.9.10',
        port: 9002,
        foundation: '3',
        eoc: true,
      )).rootElement;
      await gw.onJingle(
        callerJid: Jid(local: alice.id, domain: _xmppDomain),
        calleeJid: Jid(local: '+15551234', domain: _sipDomain),
        jingle: ti2,
      );

      // INVITE fires with both trickled candidates included in the SDP.
      await _waitFor(
        () => peerReceived.any((r) => r.method == 'INVITE'),
        const Duration(seconds: 2),
      );
      final invite = peerReceived.firstWhere((r) => r.method == 'INVITE');
      final sdp = utf8.decode(invite.bodyBytes());
      expect(sdp, contains('10.9.9.9 9001'));
      expect(sdp, contains('10.9.9.10 9002'));

      // Answer round-trip lands session-accept.
      await mock
          .awaitJingleAction('session-accept')
          .timeout(const Duration(seconds: 3));

      await sub.cancel();
    });

    test(
        'trickle-ICE: timer window elapses → INVITE fires with '
        'whatever was accumulated', () async {
      // Rebuild the gateway with a tiny window so the test is fast.
      await gw.stop();
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
        outboundTrickleWindow: const Duration(milliseconds: 150),
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
            utf8.encode(_buildResponse(
              req,
              200,
              'OK',
              toTag: 'peer-tag',
              body: _peerAudioAnswerSdp,
              contact: 'sip:peer@127.0.0.1:${peerLocalEp.port}',
            )),
            inb.source,
          );
        }
      });

      final initiate =
          XmlDocument.parse(_initiateNoCandidates('sid-T2')).rootElement;
      unawaited(gw.onJingle(
        callerJid: Jid(local: alice.id, domain: _xmppDomain),
        calleeJid: Jid(local: '+15551234', domain: _sipDomain),
        jingle: initiate,
      ));

      // No transport-info — timer should fire the INVITE.
      await _waitFor(
        () => peerReceived.any((r) => r.method == 'INVITE'),
        const Duration(seconds: 2),
      );
      expect(peerReceived.map((r) => r.method), contains('INVITE'));

      await sub.cancel();
    });

    test(
        'multi-content: audio + video session-initiate → INVITE '
        'carries both m= sections; session-accept round-trips both', () async {
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
            utf8.encode(_buildResponse(
              req,
              200,
              'OK',
              toTag: 'peer-tag',
              body: _peerAudioVideoAnswerSdp,
              contact: 'sip:peer@127.0.0.1:${peerLocalEp.port}',
            )),
            inb.source,
          );
        }
      });

      final initiate =
          XmlDocument.parse(_initiateAudioVideo('sid-V1')).rootElement;
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
      final sdp = utf8.decode(invite.bodyBytes());
      expect(sdp, contains('m=audio '));
      expect(sdp, contains('m=video '));
      expect(sdp, contains('a=mid:audio'));
      expect(sdp, contains('a=mid:video'));

      final accept = await mock
          .awaitJingleAction('session-accept')
          .timeout(const Duration(seconds: 3));
      final contentNames = accept
          .findElements('content')
          .map((c) => c.getAttribute('name'))
          .toList();
      expect(contentNames, containsAll(<String>['audio', 'video']));

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

// Trickle-mode session-initiate — no candidates in the transport, no
// end-of-candidates. Gateway is expected to buffer.
String _initiateNoCandidates(String sid) => '''
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

String _initiateAudioVideo(String sid) => '''
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
      <candidate component="1" foundation="1" generation="0" id="ca1"
                 ip="10.0.1.1" network="1" port="8998"
                 priority="2130706431" protocol="udp" type="host"/>
    </transport>
  </content>
  <content creator="initiator" name="video" senders="both">
    <description xmlns="urn:xmpp:jingle:apps:rtp:1" media="video">
      <payload-type id="96" name="VP8" clockrate="90000"/>
      <rtcp-mux/>
    </description>
    <transport xmlns="urn:xmpp:jingle:transports:ice-udp:1"
               ufrag="8hhY" pwd="asd88fgpdd777uzjYhagZg">
      <fingerprint xmlns="urn:xmpp:jingle:apps:dtls:0"
                   hash="sha-256" setup="actpass">AB:CD:EF</fingerprint>
      <candidate component="1" foundation="1" generation="0" id="cv1"
                 ip="10.0.1.1" network="1" port="8999"
                 priority="2130706431" protocol="udp" type="host"/>
    </transport>
  </content>
  <group xmlns="urn:xmpp:jingle:apps:grouping:0" semantics="BUNDLE">
    <content name="audio"/>
    <content name="video"/>
  </group>
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

const _peerAudioVideoAnswerSdp = 'v=0\r\n'
    'o=- 1234 2 IN IP4 127.0.0.1\r\n'
    's=-\r\n'
    't=0 0\r\n'
    'a=group:BUNDLE audio video\r\n'
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
    'a=candidate:1 1 udp 2130706431 127.0.0.1 40000 typ host generation 0\r\n'
    'm=video 40002 UDP/TLS/RTP/SAVPF 96\r\n'
    'c=IN IP4 127.0.0.1\r\n'
    'a=rtcp-mux\r\n'
    'a=ice-ufrag:peerU\r\n'
    'a=ice-pwd:peerPasswordXXXXXXXXXXX\r\n'
    'a=fingerprint:sha-256 12:34:56\r\n'
    'a=setup:active\r\n'
    'a=mid:video\r\n'
    'a=sendrecv\r\n'
    'a=rtpmap:96 VP8/90000\r\n'
    'a=candidate:1 1 udp 2130706431 127.0.0.1 40002 typ host generation 0\r\n';
