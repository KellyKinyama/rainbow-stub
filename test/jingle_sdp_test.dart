// Fixture-driven round-trip tests for lib/src/sip/jingle_sdp.dart.
// Verify that every field we care about survives Jingle → SDP → Jingle and
// SDP → Jingle → SDP with byte-for-byte fidelity on the SDP-representable
// subset.

import 'package:rainbow_stub/src/sip/jingle_sdp.dart';
import 'package:test/test.dart';
import 'package:xml/xml.dart';

void main() {
  group('Jingle → SDP → Jingle', () {
    test('audio Opus + PCMU + rtcp-mux + host ICE + DTLS fingerprint', () {
      final j = XmlDocument.parse(_audioOpusPcmuJingle).rootElement;
      final s1 = jingleSessionFromXml(j);
      expect(s1.contents, hasLength(1));
      final c = s1.contents.single;
      expect(c.name, 'audio');
      expect(c.senders, 'both');
      expect(c.description.media, 'audio');
      expect(c.description.rtcpMux, isTrue);
      expect(c.description.payloadTypes.map((p) => p.name), ['opus', 'PCMU']);
      expect(c.description.payloadTypes[0].id, 111);
      expect(c.description.payloadTypes[0].clockrate, 48000);
      expect(c.description.payloadTypes[0].channels, 2);
      expect(c.description.payloadTypes[0].parameters['minptime'], '10');
      expect(c.description.payloadTypes[0].parameters['useinbandfec'], '1');
      expect(c.description.payloadTypes[1].id, 0);
      expect(c.description.payloadTypes[1].clockrate, 8000);
      expect(c.description.payloadTypes[1].channels, isNull);
      expect(c.transport.ufrag, '8hhY');
      expect(c.transport.pwd, 'asd88fgpdd777uzjYhagZg');
      expect(c.transport.fingerprint?.hash, 'sha-256');
      expect(c.transport.fingerprint?.setup, 'actpass');
      expect(c.transport.candidates, hasLength(1));
      expect(c.transport.candidates[0].type, 'host');

      final sdp = jingleSessionToSdp(s1);
      expect(sdp, contains('m=audio 8998 UDP/TLS/RTP/SAVPF 111 0'));
      expect(sdp, contains('a=rtpmap:111 opus/48000/2'));
      expect(sdp, contains('a=rtpmap:0 PCMU/8000'));
      expect(sdp, contains('a=fmtp:111 minptime=10;useinbandfec=1'));
      expect(sdp, contains('a=rtcp-mux'));
      expect(sdp, contains('a=ice-ufrag:8hhY'));
      expect(sdp, contains('a=ice-pwd:asd88fgpdd777uzjYhagZg'));
      expect(sdp, contains('a=fingerprint:sha-256 AB:CD:EF'));
      expect(sdp, contains('a=setup:actpass'));
      expect(sdp, contains('a=mid:audio'));
      expect(sdp, contains('a=sendrecv'));
      expect(
          sdp, contains('candidate:1 1 udp 2130706431 10.0.1.1 8998 typ host'));

      final s2 = jingleSessionFromSdp(sdp);
      _assertRtpParityIgnoringXmppOnly(s1, s2);
    });

    test('video H.264 + VP8 with rtcp-fb', () {
      final j = XmlDocument.parse(_videoH264Vp8Jingle).rootElement;
      final s1 = jingleSessionFromXml(j);
      final c = s1.contents.single;
      expect(c.description.media, 'video');
      expect(c.description.payloadTypes, hasLength(2));
      expect(c.description.payloadTypes[0].name, 'H264');
      expect(c.description.payloadTypes[0].parameters['profile-level-id'],
          '42e01f');
      expect(c.description.payloadTypes[0].rtcpFb.map((f) => f.type),
          ['nack', 'nack', 'ccm', 'goog-remb']);
      expect(c.description.payloadTypes[0].rtcpFb[1].subtype, 'pli');
      expect(c.description.payloadTypes[0].rtcpFb[2].subtype, 'fir');
      expect(c.description.payloadTypes[1].name, 'VP8');

      final sdp = jingleSessionToSdp(s1);
      expect(sdp, contains('a=rtpmap:96 H264/90000'));
      expect(
          sdp,
          contains('a=fmtp:96 profile-level-id=42e01f;'
              'level-asymmetry-allowed=1;packetization-mode=1'));
      expect(sdp, contains('a=rtcp-fb:96 nack'));
      expect(sdp, contains('a=rtcp-fb:96 nack pli'));
      expect(sdp, contains('a=rtcp-fb:96 ccm fir'));
      expect(sdp, contains('a=rtcp-fb:96 goog-remb'));

      final s2 = jingleSessionFromSdp(sdp);
      _assertRtpParityIgnoringXmppOnly(s1, s2);
    });

    test('BUNDLE audio + video with hdrExts and ssrcs', () {
      final j = XmlDocument.parse(_bundleAudioVideoJingle).rootElement;
      final s1 = jingleSessionFromXml(j);
      expect(s1.bundleGroup, ['0', '1']);
      expect(s1.contents, hasLength(2));

      final audio = s1.contents[0];
      expect(audio.description.hdrExts, hasLength(1));
      expect(audio.description.hdrExts[0].id, 1);
      expect(audio.description.hdrExts[0].uri,
          'urn:ietf:params:rtp-hdrext:ssrc-audio-level');
      expect(audio.description.ssrcs, hasLength(1));
      expect(audio.description.ssrcs[0].ssrc, 3735928559);
      expect(audio.description.ssrcs[0].parameters['cname'], 'audio-cname');
      expect(
          audio.description.ssrcs[0].parameters['msid'], 'stream1 audiotrack1');

      final video = s1.contents[1];
      expect(video.description.media, 'video');
      expect(video.description.ssrcs[0].ssrc, 2882400018);

      final sdp = jingleSessionToSdp(s1);
      expect(sdp, contains('a=group:BUNDLE 0 1'));
      expect(sdp,
          contains('a=extmap:1 urn:ietf:params:rtp-hdrext:ssrc-audio-level'));
      expect(sdp, contains('a=ssrc:3735928559 cname:audio-cname'));
      expect(sdp, contains('a=ssrc:3735928559 msid:stream1 audiotrack1'));
      expect(sdp, contains('a=ssrc:2882400018 cname:video-cname'));
      expect(sdp, contains('m=audio'));
      expect(sdp, contains('m=video'));

      final s2 = jingleSessionFromSdp(sdp);
      expect(s2.bundleGroup, ['0', '1']);
      expect(s2.contents, hasLength(2));
      _assertRtpParityIgnoringXmppOnly(s1, s2);
    });

    test('full-ICE (host + srflx + relay + tcp)', () {
      final j = XmlDocument.parse(_fullIceJingle).rootElement;
      final s1 = jingleSessionFromXml(j);
      final cands = s1.contents.single.transport.candidates;
      expect(cands.map((c) => c.type), ['host', 'srflx', 'relay', 'host']);
      final srflx = cands.firstWhere((c) => c.type == 'srflx');
      expect(srflx.relAddr, '10.0.1.1');
      expect(srflx.relPort, 8998);
      final relay = cands.firstWhere((c) => c.type == 'relay');
      expect(relay.relAddr, '203.0.113.10');
      expect(relay.relPort, 60000);
      final tcp = cands.firstWhere((c) => c.protocol == 'tcp');
      expect(tcp.tcpType, 'passive');

      final sdp = jingleSessionToSdp(s1);
      expect(
          sdp, contains('candidate:1 1 udp 2130706431 10.0.1.1 8998 typ host'));
      expect(
          sdp,
          contains('candidate:2 1 udp 1694498815 198.51.100.7 40000 '
              'typ srflx raddr 10.0.1.1 rport 8998'));
      expect(
          sdp,
          contains('candidate:3 1 udp 41886719 192.0.2.5 50000 typ relay '
              'raddr 203.0.113.10 rport 60000'));
      expect(sdp, contains('typ host generation 0 tcptype passive'));

      final s2 = jingleSessionFromSdp(sdp);
      final cands2 = s2.contents.single.transport.candidates;
      expect(cands2.map((c) => c.type), ['host', 'srflx', 'relay', 'host']);
      expect(cands2.firstWhere((c) => c.type == 'srflx').relAddr, '10.0.1.1');
      expect(cands2.firstWhere((c) => c.type == 'relay').relPort, 60000);
      expect(cands2.firstWhere((c) => c.protocol == 'tcp').tcpType, 'passive');
    });

    test('direction variants sendrecv/sendonly/recvonly/inactive', () {
      for (final entry in {
        'both': 'sendrecv',
        'initiator': 'sendonly',
        'responder': 'recvonly',
        'none': 'inactive',
      }.entries) {
        final j = XmlDocument.parse(_dirJingle(entry.key)).rootElement;
        final s1 = jingleSessionFromXml(j);
        expect(s1.contents.single.senders, entry.key);
        final sdp = jingleSessionToSdp(s1);
        expect(sdp, contains('a=${entry.value}'),
            reason: 'sender ${entry.key} should map to a=${entry.value}');
        final s2 = jingleSessionFromSdp(sdp);
        expect(s2.contents.single.senders, entry.key,
            reason:
                'a=${entry.value} should round-trip to senders="${entry.key}"');
      }
    });

    test('setup="active" and setup="passive" survive round-trip', () {
      for (final setup in ['active', 'passive', 'actpass']) {
        final j = XmlDocument.parse(_setupJingle(setup)).rootElement;
        final s1 = jingleSessionFromXml(j);
        expect(s1.contents.single.transport.fingerprint?.setup, setup);
        final sdp = jingleSessionToSdp(s1);
        expect(sdp, contains('a=setup:$setup'));
        final s2 = jingleSessionFromSdp(sdp);
        expect(s2.contents.single.transport.fingerprint?.setup, setup);
      }
    });
  });

  group('SDP → Jingle → SDP', () {
    test('Chrome-shape audio SDP round-trips through Jingle XML', () {
      final s1 = jingleSessionFromSdp(_chromeAudioSdp);
      expect(s1.contents, hasLength(1));
      final c = s1.contents.single;
      expect(c.name, '0');
      expect(c.description.media, 'audio');
      expect(c.description.rtcpMux, isTrue);
      expect(c.transport.ufrag, 'F7gI');
      expect(c.transport.pwd, 'x9cml/YzichV2+XlhiMu8g');
      expect(c.transport.fingerprint?.hash, 'sha-256');
      expect(c.transport.fingerprint?.setup, 'actpass');
      expect(c.transport.candidates, hasLength(2));

      final xml = jingleSessionToXml(
        s1,
        action: 'session-initiate',
        sid: 'test-sid',
        initiator: 'alice@example/phone',
      );
      expect(xml.getAttribute('action'), 'session-initiate');
      expect(xml.getAttribute('sid'), 'test-sid');
      final ct = xml.findElements('content').single;
      expect(ct.getAttribute('name'), '0');
      final desc = ct.getElement('description', namespace: jingleRtpNs);
      expect(desc, isNotNull);
      expect(
          desc!
              .findElements('payload-type')
              .map((p) => p.getAttribute('name'))
              .toList(),
          ['opus', 'PCMU', 'PCMA']);
      expect(desc.getElement('rtcp-mux'), isNotNull);
      final tp = ct.getElement('transport', namespace: jingleIceUdpNs);
      expect(tp, isNotNull);
      expect(tp!.getAttribute('ufrag'), 'F7gI');
      expect(tp.findElements('candidate'), hasLength(2));

      final s2 = jingleSessionFromXml(xml);
      final sdp2 = jingleSessionToSdp(s2);
      // Re-parse to compare against the original semantically.
      final s3 = jingleSessionFromSdp(sdp2);
      _assertRtpParityIgnoringXmppOnly(s1, s3);
      expect(s3.contents.single.transport.candidates.length, 2);
    });
  });
}

/// Round-trip check that ignores fields carried only in XMPP (candidate `id`,
/// `network`) and any session-level cosmetic differences from re-encoding.
void _assertRtpParityIgnoringXmppOnly(JingleSession a, JingleSession b) {
  expect(b.contents.length, a.contents.length);
  for (var i = 0; i < a.contents.length; i++) {
    final ca = a.contents[i];
    final cb = b.contents[i];
    expect(cb.name, ca.name);
    expect(cb.senders, ca.senders);
    expect(cb.description.media, ca.description.media);
    expect(cb.description.rtcpMux, ca.description.rtcpMux);
    expect(cb.description.payloadTypes.map((p) => p.id),
        ca.description.payloadTypes.map((p) => p.id));
    expect(cb.description.payloadTypes.map((p) => p.name),
        ca.description.payloadTypes.map((p) => p.name));
    expect(cb.description.payloadTypes.map((p) => p.clockrate),
        ca.description.payloadTypes.map((p) => p.clockrate));
    for (var k = 0; k < ca.description.payloadTypes.length; k++) {
      expect(cb.description.payloadTypes[k].parameters,
          ca.description.payloadTypes[k].parameters,
          reason: 'fmtp params on pt=${ca.description.payloadTypes[k].id}');
      expect(cb.description.payloadTypes[k].rtcpFb.map((f) => f.type),
          ca.description.payloadTypes[k].rtcpFb.map((f) => f.type));
      expect(cb.description.payloadTypes[k].rtcpFb.map((f) => f.subtype),
          ca.description.payloadTypes[k].rtcpFb.map((f) => f.subtype));
    }
    expect(cb.description.hdrExts.map((h) => h.uri),
        ca.description.hdrExts.map((h) => h.uri));
    expect(cb.description.ssrcs.map((s) => s.ssrc),
        ca.description.ssrcs.map((s) => s.ssrc));
    expect(cb.transport.ufrag, ca.transport.ufrag);
    expect(cb.transport.pwd, ca.transport.pwd);
    expect(cb.transport.fingerprint?.hash, ca.transport.fingerprint?.hash);
    expect(cb.transport.fingerprint?.setup, ca.transport.fingerprint?.setup);
    expect(cb.transport.fingerprint?.value, ca.transport.fingerprint?.value);
    expect(cb.transport.candidates.length, ca.transport.candidates.length);
    for (var k = 0; k < ca.transport.candidates.length; k++) {
      final da = ca.transport.candidates[k];
      final db = cb.transport.candidates[k];
      expect(db.foundation, da.foundation);
      expect(db.component, da.component);
      expect(db.protocol, da.protocol);
      expect(db.ip, da.ip);
      expect(db.port, da.port);
      expect(db.priority, da.priority);
      expect(db.type, da.type);
      expect(db.relAddr, da.relAddr);
      expect(db.relPort, da.relPort);
      expect(db.tcpType, da.tcpType);
    }
  }
}

// ============================================================================
// Fixtures — real WebRTC-shape Jingle stanzas.
// ============================================================================

const _audioOpusPcmuJingle = '''
<jingle xmlns="urn:xmpp:jingle:1" action="session-initiate"
        initiator="alice@example.com/phone" sid="sid-1">
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

const _videoH264Vp8Jingle = '''
<jingle xmlns="urn:xmpp:jingle:1" action="session-initiate"
        initiator="alice@example.com/phone" sid="sid-v">
  <content creator="initiator" name="video" senders="both">
    <description xmlns="urn:xmpp:jingle:apps:rtp:1" media="video">
      <payload-type id="96" name="H264" clockrate="90000">
        <parameter name="profile-level-id" value="42e01f"/>
        <parameter name="level-asymmetry-allowed" value="1"/>
        <parameter name="packetization-mode" value="1"/>
        <rtcp-fb xmlns="urn:xmpp:jingle:apps:rtp:rtcp-fb:0" type="nack"/>
        <rtcp-fb xmlns="urn:xmpp:jingle:apps:rtp:rtcp-fb:0" type="nack"
                 subtype="pli"/>
        <rtcp-fb xmlns="urn:xmpp:jingle:apps:rtp:rtcp-fb:0" type="ccm"
                 subtype="fir"/>
        <rtcp-fb xmlns="urn:xmpp:jingle:apps:rtp:rtcp-fb:0" type="goog-remb"/>
      </payload-type>
      <payload-type id="97" name="VP8" clockrate="90000">
        <rtcp-fb xmlns="urn:xmpp:jingle:apps:rtp:rtcp-fb:0" type="nack"/>
      </payload-type>
      <rtcp-mux/>
    </description>
    <transport xmlns="urn:xmpp:jingle:transports:ice-udp:1"
               ufrag="vufr" pwd="vpwd0000000000000000000">
      <fingerprint xmlns="urn:xmpp:jingle:apps:dtls:0"
                   hash="sha-256" setup="actpass">11:22:33</fingerprint>
      <candidate component="1" foundation="1" generation="0" id="v1"
                 ip="10.0.1.2" network="1" port="9002"
                 priority="2130706431" protocol="udp" type="host"/>
    </transport>
  </content>
</jingle>
''';

const _bundleAudioVideoJingle = '''
<jingle xmlns="urn:xmpp:jingle:1" action="session-initiate"
        initiator="alice@example.com/phone" sid="sid-b">
  <content creator="initiator" name="0" senders="both">
    <description xmlns="urn:xmpp:jingle:apps:rtp:1" media="audio">
      <payload-type id="111" name="opus" clockrate="48000" channels="2"/>
      <rtp-hdrext xmlns="urn:xmpp:jingle:apps:rtp:rtp-hdrext:0" id="1"
                  uri="urn:ietf:params:rtp-hdrext:ssrc-audio-level"/>
      <rtcp-mux/>
      <source xmlns="urn:xmpp:jingle:apps:rtp:ssma:0" ssrc="3735928559">
        <parameter name="cname" value="audio-cname"/>
        <parameter name="msid" value="stream1 audiotrack1"/>
      </source>
    </description>
    <transport xmlns="urn:xmpp:jingle:transports:ice-udp:1"
               ufrag="uf" pwd="pw000000000000000000000">
      <fingerprint xmlns="urn:xmpp:jingle:apps:dtls:0"
                   hash="sha-256" setup="actpass">AA:BB</fingerprint>
      <candidate component="1" foundation="1" generation="0" id="a1"
                 ip="10.0.1.1" network="1" port="9001"
                 priority="2130706431" protocol="udp" type="host"/>
    </transport>
  </content>
  <content creator="initiator" name="1" senders="both">
    <description xmlns="urn:xmpp:jingle:apps:rtp:1" media="video">
      <payload-type id="96" name="VP8" clockrate="90000"/>
      <rtcp-mux/>
      <source xmlns="urn:xmpp:jingle:apps:rtp:ssma:0" ssrc="2882400018">
        <parameter name="cname" value="video-cname"/>
      </source>
    </description>
    <transport xmlns="urn:xmpp:jingle:transports:ice-udp:1"
               ufrag="uf" pwd="pw000000000000000000000">
      <fingerprint xmlns="urn:xmpp:jingle:apps:dtls:0"
                   hash="sha-256" setup="actpass">AA:BB</fingerprint>
      <candidate component="1" foundation="1" generation="0" id="v1"
                 ip="10.0.1.1" network="1" port="9002"
                 priority="2130706431" protocol="udp" type="host"/>
    </transport>
  </content>
  <group xmlns="urn:xmpp:jingle:apps:grouping:0" semantics="BUNDLE">
    <content name="0"/>
    <content name="1"/>
  </group>
</jingle>
''';

const _fullIceJingle = '''
<jingle xmlns="urn:xmpp:jingle:1" action="session-initiate"
        initiator="alice@example.com/phone" sid="sid-i">
  <content creator="initiator" name="audio" senders="both">
    <description xmlns="urn:xmpp:jingle:apps:rtp:1" media="audio">
      <payload-type id="111" name="opus" clockrate="48000" channels="2"/>
      <rtcp-mux/>
    </description>
    <transport xmlns="urn:xmpp:jingle:transports:ice-udp:1"
               ufrag="uf" pwd="pw000000000000000000000">
      <fingerprint xmlns="urn:xmpp:jingle:apps:dtls:0"
                   hash="sha-256" setup="actpass">AA:BB</fingerprint>
      <candidate component="1" foundation="1" generation="0" id="h1"
                 ip="10.0.1.1" network="1" port="8998"
                 priority="2130706431" protocol="udp" type="host"/>
      <candidate component="1" foundation="2" generation="0" id="s1"
                 ip="198.51.100.7" network="1" port="40000"
                 priority="1694498815" protocol="udp" type="srflx"
                 rel-addr="10.0.1.1" rel-port="8998"/>
      <candidate component="1" foundation="3" generation="0" id="r1"
                 ip="192.0.2.5" network="1" port="50000"
                 priority="41886719" protocol="udp" type="relay"
                 rel-addr="203.0.113.10" rel-port="60000"/>
      <candidate component="1" foundation="4" generation="0" id="t1"
                 ip="10.0.1.1" network="1" port="9010"
                 priority="1518280447" protocol="tcp" type="host"
                 tcptype="passive"/>
    </transport>
  </content>
</jingle>
''';

String _dirJingle(String senders) => '''
<jingle xmlns="urn:xmpp:jingle:1" action="session-initiate"
        initiator="alice@example.com/phone" sid="sid-d">
  <content creator="initiator" name="audio" senders="$senders">
    <description xmlns="urn:xmpp:jingle:apps:rtp:1" media="audio">
      <payload-type id="111" name="opus" clockrate="48000" channels="2"/>
      <rtcp-mux/>
    </description>
    <transport xmlns="urn:xmpp:jingle:transports:ice-udp:1"
               ufrag="uf" pwd="pw000000000000000000000">
      <fingerprint xmlns="urn:xmpp:jingle:apps:dtls:0"
                   hash="sha-256" setup="actpass">AA:BB</fingerprint>
      <candidate component="1" foundation="1" generation="0" id="h1"
                 ip="10.0.1.1" network="1" port="8998"
                 priority="2130706431" protocol="udp" type="host"/>
    </transport>
  </content>
</jingle>
''';

String _setupJingle(String setup) => '''
<jingle xmlns="urn:xmpp:jingle:1" action="session-initiate"
        initiator="alice@example.com/phone" sid="sid-s">
  <content creator="initiator" name="audio" senders="both">
    <description xmlns="urn:xmpp:jingle:apps:rtp:1" media="audio">
      <payload-type id="111" name="opus" clockrate="48000" channels="2"/>
      <rtcp-mux/>
    </description>
    <transport xmlns="urn:xmpp:jingle:transports:ice-udp:1"
               ufrag="uf" pwd="pw000000000000000000000">
      <fingerprint xmlns="urn:xmpp:jingle:apps:dtls:0"
                   hash="sha-256" setup="$setup">AA:BB</fingerprint>
      <candidate component="1" foundation="1" generation="0" id="h1"
                 ip="10.0.1.1" network="1" port="8998"
                 priority="2130706431" protocol="udp" type="host"/>
    </transport>
  </content>
</jingle>
''';

/// A trimmed-down Chrome-style SDP offer (audio only). Preserves the
/// realistic order: c/rtcp/mid/direction/rtcp-mux/hdrext/rtpmaps/candidates/ssrcs.
const _chromeAudioSdp = '''v=0\r
o=- 5678901234567890123 2 IN IP4 127.0.0.1\r
s=-\r
t=0 0\r
a=group:BUNDLE 0\r
a=msid-semantic: WMS stream1\r
m=audio 9 UDP/TLS/RTP/SAVPF 111 0 8\r
c=IN IP4 0.0.0.0\r
a=rtcp:9 IN IP4 0.0.0.0\r
a=ice-ufrag:F7gI\r
a=ice-pwd:x9cml/YzichV2+XlhiMu8g\r
a=fingerprint:sha-256 12:34:56:78:9A:BC:DE:F0\r
a=setup:actpass\r
a=mid:0\r
a=sendrecv\r
a=extmap:1 urn:ietf:params:rtp-hdrext:ssrc-audio-level\r
a=rtcp-mux\r
a=rtpmap:111 opus/48000/2\r
a=fmtp:111 minptime=10;useinbandfec=1\r
a=rtpmap:0 PCMU/8000\r
a=rtpmap:8 PCMA/8000\r
a=candidate:1 1 udp 2130706431 10.0.1.4 40001 typ host generation 0\r
a=candidate:2 1 udp 1694498815 198.51.100.9 40002 typ srflx raddr 10.0.1.4 rport 40001 generation 0\r
a=ssrc:1111111111 cname:chrome-cname\r
a=ssrc:1111111111 msid:stream1 audiotrack1\r
''';
