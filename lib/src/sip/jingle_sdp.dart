/// XEP-0166/0167/0176/0320/0338/0339 Jingle ↔ SDP (RFC 4566/5245/5763)
/// round-trip. See `rainbow-stub-sip-bridge.md` §3.2 / §M0.
///
/// This is signaling glue only — no DTLS, SRTP, or ICE state machine.
library;

import 'package:xml/xml.dart';

// ---- XML namespaces ---------------------------------------------------------

/// XEP-0166 Jingle envelope.
const jingleNs = 'urn:xmpp:jingle:1';

/// XEP-0167 Jingle RTP Sessions.
const jingleRtpNs = 'urn:xmpp:jingle:apps:rtp:1';

/// XEP-0167 §6.1 rtp-hdrext feedback (extension).
const jingleRtpHdrExtNs = 'urn:xmpp:jingle:apps:rtp:rtp-hdrext:0';

/// XEP-0293 RTCP feedback negotiation.
const jingleRtpFbNs = 'urn:xmpp:jingle:apps:rtp:rtcp-fb:0';

/// XEP-0339 source-specific attributes.
const jingleRtpSsmaNs = 'urn:xmpp:jingle:apps:rtp:ssma:0';

/// XEP-0176 Jingle ICE-UDP Transport.
const jingleIceUdpNs = 'urn:xmpp:jingle:transports:ice-udp:1';

/// XEP-0320 Jingle DTLS-SRTP.
const jingleDtlsSrtpNs = 'urn:xmpp:jingle:apps:dtls:0';

/// XEP-0338 Jingle content grouping (BUNDLE).
const jingleGroupingNs = 'urn:xmpp:jingle:apps:grouping:0';

// ---- Model ------------------------------------------------------------------

/// A whole Jingle session's media plane, protocol-agnostic. Bidirectional
/// between XEP-0167 and RFC 4566.
class JingleSession {
  JingleSession({
    required this.contents,
    this.bundleGroup = const [],
  });

  final List<JingleContent> contents;

  /// XEP-0338 group semantics="BUNDLE" list of content names.
  final List<String> bundleGroup;
}

class JingleContent {
  JingleContent({
    required this.name,
    required this.creator,
    required this.senders,
    required this.description,
    required this.transport,
  });

  /// Doubles as SDP mid.
  final String name;

  /// 'initiator' | 'responder' (XEP-0166 §7.3).
  final String creator;

  /// 'both' | 'initiator' | 'responder' | 'none' (XEP-0166 §7.3).
  final String senders;

  final JingleRtpDescription description;
  final JingleIceTransport transport;
}

class JingleRtpDescription {
  JingleRtpDescription({
    required this.media,
    required this.payloadTypes,
    this.rtcpMux = false,
    this.hdrExts = const [],
    this.ssrcs = const [],
  });

  /// 'audio' | 'video'.
  final String media;
  final List<PayloadType> payloadTypes;
  final bool rtcpMux;
  final List<RtpHdrExt> hdrExts;
  final List<SourceSsrc> ssrcs;
}

class PayloadType {
  PayloadType({
    required this.id,
    required this.name,
    required this.clockrate,
    this.channels,
    this.parameters = const {},
    this.rtcpFb = const [],
  });

  final int id;
  final String name;
  final int clockrate;
  final int? channels;

  /// Ordered fmtp `<parameter/>` pairs.
  final Map<String, String> parameters;

  final List<RtcpFb> rtcpFb;
}

class RtcpFb {
  RtcpFb({required this.type, this.subtype});

  final String type;
  final String? subtype;
}

class RtpHdrExt {
  RtpHdrExt({required this.id, required this.uri, this.direction});

  final int id;
  final String uri;

  /// 'sendrecv' | 'sendonly' | 'recvonly' | 'inactive' (RFC 5285 §5).
  final String? direction;
}

class SourceSsrc {
  SourceSsrc({required this.ssrc, this.parameters = const {}});

  final int ssrc;

  /// Ordered attribute pairs — commonly cname, msid, mslabel, label.
  final Map<String, String> parameters;
}

class JingleIceTransport {
  JingleIceTransport({
    required this.ufrag,
    required this.pwd,
    this.fingerprint,
    this.candidates = const [],
  });

  final String ufrag;
  final String pwd;
  final JingleFingerprint? fingerprint;
  final List<IceCandidate> candidates;
}

class JingleFingerprint {
  JingleFingerprint({
    required this.hash,
    required this.setup,
    required this.value,
  });

  /// e.g. 'sha-256'.
  final String hash;

  /// 'actpass' | 'active' | 'passive' | 'holdconn'.
  final String setup;

  /// Colon-separated uppercase hex.
  final String value;
}

class IceCandidate {
  IceCandidate({
    required this.component,
    required this.foundation,
    required this.ip,
    required this.port,
    required this.priority,
    required this.protocol,
    required this.type,
    this.generation = 0,
    this.network = 0,
    this.id = '',
    this.relAddr,
    this.relPort,
    this.tcpType,
  });

  final int component;
  final String foundation;
  final String ip;
  final int port;
  final int priority;

  /// 'udp' | 'tcp'.
  final String protocol;

  /// 'host' | 'srflx' | 'prflx' | 'relay'.
  final String type;

  final int generation;

  /// XEP-0176 only — not carried by SDP.
  final int network;

  /// XEP-0176 only — not carried by SDP.
  final String id;

  final String? relAddr;
  final int? relPort;

  /// TCP candidate type per RFC 6544.
  final String? tcpType;
}

// ---- Parse: Jingle → JingleSession ------------------------------------------

/// Parse an outer `<jingle>` element (XEP-0166) into a [JingleSession].
JingleSession jingleSessionFromXml(XmlElement jingle) {
  final contents = <JingleContent>[];
  for (final c in jingle.findElements('content')) {
    contents.add(_parseContent(c));
  }
  final group = jingle.getElement('group', namespace: jingleGroupingNs);
  final bundle = <String>[];
  if (group != null && group.getAttribute('semantics') == 'BUNDLE') {
    for (final c in group.findElements('content')) {
      final n = c.getAttribute('name');
      if (n != null) bundle.add(n);
    }
  }
  return JingleSession(contents: contents, bundleGroup: bundle);
}

JingleContent _parseContent(XmlElement c) {
  final desc = c.getElement('description', namespace: jingleRtpNs);
  final tp = c.getElement('transport', namespace: jingleIceUdpNs);
  if (desc == null) {
    throw FormatException('content lacks <description xmlns="$jingleRtpNs">');
  }
  if (tp == null) {
    throw FormatException('content lacks <transport xmlns="$jingleIceUdpNs">');
  }
  return JingleContent(
    name: c.getAttribute('name') ?? '',
    creator: c.getAttribute('creator') ?? 'initiator',
    senders: c.getAttribute('senders') ?? 'both',
    description: _parseDescription(desc),
    transport: _parseTransport(tp),
  );
}

JingleRtpDescription _parseDescription(XmlElement d) {
  final pts = <PayloadType>[];
  for (final p in d.findElements('payload-type')) {
    pts.add(_parsePayloadType(p));
  }
  final hdrExts = <RtpHdrExt>[];
  for (final e in d.findElements('rtp-hdrext', namespace: jingleRtpHdrExtNs)) {
    hdrExts.add(
      RtpHdrExt(
        id: int.parse(e.getAttribute('id')!),
        uri: e.getAttribute('uri') ?? '',
        direction: e.getAttribute('senders'),
      ),
    );
  }
  final ssrcs = <SourceSsrc>[];
  for (final s in d.findElements('source', namespace: jingleRtpSsmaNs)) {
    final params = <String, String>{};
    for (final p in s.findElements('parameter')) {
      final n = p.getAttribute('name');
      if (n == null) continue;
      params[n] = p.getAttribute('value') ?? '';
    }
    ssrcs.add(SourceSsrc(
        ssrc: int.parse(s.getAttribute('ssrc')!), parameters: params));
  }
  return JingleRtpDescription(
    media: d.getAttribute('media') ?? '',
    payloadTypes: pts,
    rtcpMux: d.getElement('rtcp-mux') != null,
    hdrExts: hdrExts,
    ssrcs: ssrcs,
  );
}

PayloadType _parsePayloadType(XmlElement p) {
  final params = <String, String>{};
  for (final par in p.findElements('parameter')) {
    final n = par.getAttribute('name');
    if (n == null) continue;
    params[n] = par.getAttribute('value') ?? '';
  }
  final fbs = <RtcpFb>[];
  for (final fb in p.findElements('rtcp-fb', namespace: jingleRtpFbNs)) {
    fbs.add(
      RtcpFb(
        type: fb.getAttribute('type') ?? '',
        subtype: fb.getAttribute('subtype'),
      ),
    );
  }
  final channels = p.getAttribute('channels');
  return PayloadType(
    id: int.parse(p.getAttribute('id')!),
    name: p.getAttribute('name') ?? '',
    clockrate: int.tryParse(p.getAttribute('clockrate') ?? '') ?? 0,
    channels: channels == null ? null : int.tryParse(channels),
    parameters: params,
    rtcpFb: fbs,
  );
}

JingleIceTransport _parseTransport(XmlElement t) {
  final fpEl = t.getElement('fingerprint', namespace: jingleDtlsSrtpNs);
  final fp = fpEl == null
      ? null
      : JingleFingerprint(
          hash: fpEl.getAttribute('hash') ?? '',
          setup: fpEl.getAttribute('setup') ?? 'actpass',
          value: fpEl.innerText.trim().toUpperCase(),
        );
  final cands = <IceCandidate>[];
  for (final c in t.findElements('candidate')) {
    cands.add(iceCandidateFromXml(c));
  }
  return JingleIceTransport(
    ufrag: t.getAttribute('ufrag') ?? '',
    pwd: t.getAttribute('pwd') ?? '',
    fingerprint: fp,
    candidates: cands,
  );
}

/// Parse a single XEP-0176 `<candidate/>` element into an [IceCandidate].
/// Exposed so callers assembling trickle-ICE candidate lists from
/// `transport-info` IQs can reuse the shared attribute schema.
IceCandidate iceCandidateFromXml(XmlElement c) {
  int? parseIntOrNull(String? s) => s == null ? null : int.tryParse(s);
  return IceCandidate(
    component: int.parse(c.getAttribute('component')!),
    foundation: c.getAttribute('foundation') ?? '',
    ip: c.getAttribute('ip') ?? '',
    port: int.parse(c.getAttribute('port')!),
    priority: int.parse(c.getAttribute('priority')!),
    protocol: (c.getAttribute('protocol') ?? 'udp').toLowerCase(),
    type: c.getAttribute('type') ?? 'host',
    generation: parseIntOrNull(c.getAttribute('generation')) ?? 0,
    network: parseIntOrNull(c.getAttribute('network')) ?? 0,
    id: c.getAttribute('id') ?? '',
    relAddr: c.getAttribute('rel-addr'),
    relPort: parseIntOrNull(c.getAttribute('rel-port')),
    tcpType: c.getAttribute('tcptype'),
  );
}

// ---- Emit: JingleSession → Jingle XML ---------------------------------------

/// Build an outer `<jingle xmlns="urn:xmpp:jingle:1" ...>` element with all
/// content children. Caller wraps it inside an `<iq type="set" ...>`.
XmlElement jingleSessionToXml(
  JingleSession session, {
  required String action,
  required String sid,
  required String initiator,
  String? responder,
}) {
  final b = XmlBuilder();
  b.element(
    'jingle',
    attributes: {
      'xmlns': jingleNs,
      'action': action,
      'initiator': initiator,
      if (responder != null) 'responder': responder,
      'sid': sid,
    },
    nest: () {
      for (final c in session.contents) {
        _buildContent(b, c);
      }
      if (session.bundleGroup.isNotEmpty) {
        b.element(
          'group',
          attributes: {'xmlns': jingleGroupingNs, 'semantics': 'BUNDLE'},
          nest: () {
            for (final name in session.bundleGroup) {
              b.element('content', attributes: {'name': name});
            }
          },
        );
      }
    },
  );
  return b.buildDocument().rootElement;
}

void _buildContent(XmlBuilder b, JingleContent c) {
  b.element(
    'content',
    attributes: {
      'creator': c.creator,
      'name': c.name,
      'senders': c.senders,
    },
    nest: () {
      _buildDescription(b, c.description);
      _buildTransport(b, c.transport);
    },
  );
}

void _buildDescription(XmlBuilder b, JingleRtpDescription d) {
  b.element(
    'description',
    attributes: {'xmlns': jingleRtpNs, 'media': d.media},
    nest: () {
      for (final pt in d.payloadTypes) {
        _buildPayloadType(b, pt);
      }
      for (final ext in d.hdrExts) {
        b.element(
          'rtp-hdrext',
          attributes: {
            'xmlns': jingleRtpHdrExtNs,
            'id': ext.id.toString(),
            'uri': ext.uri,
            if (ext.direction != null) 'senders': ext.direction!,
          },
        );
      }
      if (d.rtcpMux) b.element('rtcp-mux');
      for (final s in d.ssrcs) {
        b.element(
          'source',
          attributes: {
            'xmlns': jingleRtpSsmaNs,
            'ssrc': s.ssrc.toString(),
          },
          nest: () {
            s.parameters.forEach((k, v) {
              b.element('parameter', attributes: {'name': k, 'value': v});
            });
          },
        );
      }
    },
  );
}

void _buildPayloadType(XmlBuilder b, PayloadType pt) {
  b.element(
    'payload-type',
    attributes: {
      'id': pt.id.toString(),
      'name': pt.name,
      'clockrate': pt.clockrate.toString(),
      if (pt.channels != null) 'channels': pt.channels!.toString(),
    },
    nest: () {
      pt.parameters.forEach((k, v) {
        b.element('parameter', attributes: {'name': k, 'value': v});
      });
      for (final fb in pt.rtcpFb) {
        b.element(
          'rtcp-fb',
          attributes: {
            'xmlns': jingleRtpFbNs,
            'type': fb.type,
            if (fb.subtype != null) 'subtype': fb.subtype!,
          },
        );
      }
    },
  );
}

void _buildTransport(XmlBuilder b, JingleIceTransport t) {
  b.element(
    'transport',
    attributes: {
      'xmlns': jingleIceUdpNs,
      'ufrag': t.ufrag,
      'pwd': t.pwd,
    },
    nest: () {
      final fp = t.fingerprint;
      if (fp != null) {
        b.element(
          'fingerprint',
          attributes: {
            'xmlns': jingleDtlsSrtpNs,
            'hash': fp.hash,
            'setup': fp.setup,
          },
          nest: () {
            b.text(fp.value);
          },
        );
      }
      for (final c in t.candidates) {
        b.element('candidate', attributes: _iceCandidateAttrs(c));
      }
    },
  );
}

Map<String, String> _iceCandidateAttrs(IceCandidate c) => {
      'component': c.component.toString(),
      'foundation': c.foundation,
      'generation': c.generation.toString(),
      'id': c.id,
      'ip': c.ip,
      'network': c.network.toString(),
      'port': c.port.toString(),
      'priority': c.priority.toString(),
      'protocol': c.protocol,
      'type': c.type,
      if (c.relAddr != null) 'rel-addr': c.relAddr!,
      if (c.relPort != null) 'rel-port': c.relPort!.toString(),
      if (c.tcpType != null) 'tcptype': c.tcpType!,
    };

// ---- Emit: JingleSession → SDP ----------------------------------------------

/// Build an SDP string (RFC 4566) suitable for use as an INVITE offer or
/// answer body. All ICE / DTLS material lives at the media-section level per
/// current WebRTC practice; DTLS `a=setup` is copied verbatim from the Jingle
/// fingerprint.
String jingleSessionToSdp(
  JingleSession session, {
  String username = '-',
  int sessionId = 0,
  int sessionVersion = 2,
  String unicastAddress = '127.0.0.1',
}) {
  final sid =
      sessionId == 0 ? DateTime.now().microsecondsSinceEpoch : sessionId;
  final lines = <String>[
    'v=0',
    'o=$username $sid $sessionVersion IN IP4 $unicastAddress',
    's=-',
    't=0 0',
  ];
  if (session.bundleGroup.isNotEmpty) {
    lines.add('a=group:BUNDLE ${session.bundleGroup.join(' ')}');
  }
  lines.add('a=msid-semantic: WMS');

  for (final c in session.contents) {
    lines.addAll(_mediaSection(c));
  }
  return '${lines.join('\r\n')}\r\n';
}

List<String> _mediaSection(JingleContent c) {
  final d = c.description;
  final t = c.transport;
  final ptIds = d.payloadTypes.map((p) => p.id).join(' ');
  final proto = d.rtcpMux && t.fingerprint != null
      ? 'UDP/TLS/RTP/SAVPF'
      : t.fingerprint != null
          ? 'UDP/TLS/RTP/SAVP'
          : 'RTP/AVP';
  final port = _firstCandidatePort(t) ?? 9;
  final firstIp = _firstCandidateIp(t) ?? '0.0.0.0';

  final out = <String>[
    'm=${d.media} $port $proto $ptIds',
    'c=IN IP4 $firstIp',
  ];
  if (d.rtcpMux) out.add('a=rtcp-mux');
  out.add('a=rtcp:$port IN IP4 $firstIp');
  if (t.ufrag.isNotEmpty) out.add('a=ice-ufrag:${t.ufrag}');
  if (t.pwd.isNotEmpty) out.add('a=ice-pwd:${t.pwd}');
  final fp = t.fingerprint;
  if (fp != null) {
    out
      ..add('a=fingerprint:${fp.hash} ${fp.value}')
      ..add('a=setup:${fp.setup}');
  }
  out.add('a=mid:${c.name}');
  out.add('a=${_sendersToDirection(c.senders)}');

  for (final ext in d.hdrExts) {
    final dir = ext.direction == null ? '' : '/${ext.direction}';
    out.add('a=extmap:${ext.id}$dir ${ext.uri}');
  }
  for (final pt in d.payloadTypes) {
    final channels =
        pt.channels != null && pt.channels! > 1 ? '/${pt.channels}' : '';
    out.add('a=rtpmap:${pt.id} ${pt.name}/${pt.clockrate}$channels');
    if (pt.parameters.isNotEmpty) {
      final joined =
          pt.parameters.entries.map((e) => '${e.key}=${e.value}').join(';');
      out.add('a=fmtp:${pt.id} $joined');
    }
    for (final fb in pt.rtcpFb) {
      final tail = fb.subtype == null ? fb.type : '${fb.type} ${fb.subtype}';
      out.add('a=rtcp-fb:${pt.id} $tail');
    }
  }
  for (final cand in t.candidates) {
    out.add('a=${_iceCandidateToSdp(cand)}');
  }
  for (final s in d.ssrcs) {
    if (s.parameters.isEmpty) {
      out.add('a=ssrc:${s.ssrc}');
    } else {
      for (final entry in s.parameters.entries) {
        out.add('a=ssrc:${s.ssrc} ${entry.key}:${entry.value}');
      }
    }
  }
  return out;
}

int? _firstCandidatePort(JingleIceTransport t) =>
    t.candidates.isEmpty ? null : t.candidates.first.port;
String? _firstCandidateIp(JingleIceTransport t) =>
    t.candidates.isEmpty ? null : t.candidates.first.ip;

String _sendersToDirection(String senders) {
  switch (senders) {
    case 'both':
      return 'sendrecv';
    case 'initiator':
      return 'sendonly';
    case 'responder':
      return 'recvonly';
    case 'none':
      return 'inactive';
    default:
      return 'sendrecv';
  }
}

String _directionToSenders(String dir) {
  switch (dir) {
    case 'sendrecv':
      return 'both';
    case 'sendonly':
      return 'initiator';
    case 'recvonly':
      return 'responder';
    case 'inactive':
      return 'none';
    default:
      return 'both';
  }
}

String _iceCandidateToSdp(IceCandidate c) {
  final b = StringBuffer(
    'candidate:${c.foundation} ${c.component} ${c.protocol} '
    '${c.priority} ${c.ip} ${c.port} typ ${c.type}',
  );
  if (c.relAddr != null) b.write(' raddr ${c.relAddr}');
  if (c.relPort != null) b.write(' rport ${c.relPort}');
  b.write(' generation ${c.generation}');
  if (c.tcpType != null) b.write(' tcptype ${c.tcpType}');
  return b.toString();
}

// ---- Parse: SDP → JingleSession ---------------------------------------------

/// Parse an SDP body (RFC 4566) into a [JingleSession]. Session-level
/// `a=group:BUNDLE` becomes [JingleSession.bundleGroup]; media-level
/// `a=direction` becomes each content's `senders`.
JingleSession jingleSessionFromSdp(String sdp) {
  final lines =
      sdp.split(RegExp(r'\r\n|\n')).where((l) => l.isNotEmpty).toList();

  final bundle = <String>[];
  final mediaChunks = <List<String>>[];
  var current = <String>[];
  var inMedia = false;
  for (final l in lines) {
    if (l.startsWith('m=')) {
      if (inMedia) mediaChunks.add(current);
      current = <String>[l];
      inMedia = true;
      continue;
    }
    if (inMedia) {
      current.add(l);
    } else if (l.startsWith('a=group:BUNDLE')) {
      final tail = l.substring('a=group:BUNDLE'.length).trim();
      bundle.addAll(tail.split(RegExp(r'\s+')).where((s) => s.isNotEmpty));
    }
  }
  if (inMedia) mediaChunks.add(current);

  final contents = <JingleContent>[];
  for (var i = 0; i < mediaChunks.length; i++) {
    contents.add(_parseMediaSection(mediaChunks[i], fallbackName: 'm$i'));
  }
  return JingleSession(contents: contents, bundleGroup: bundle);
}

JingleContent _parseMediaSection(
  List<String> ml, {
  required String fallbackName,
}) {
  final mLine = ml.first;
  final parts = mLine.substring(2).split(RegExp(r'\s+'));
  final media = parts[0];
  final port = int.tryParse(parts[1]) ?? 0;
  final ptIds = parts.skip(3).map(int.parse).toList();

  var mid = fallbackName;
  var direction = 'sendrecv';
  var ufrag = '';
  var pwd = '';
  JingleFingerprint? fingerprint;
  var setup = 'actpass';
  var hasFingerprintSetupOverride = false;
  var rtcpMux = false;

  final rtpmaps = <int, _RtpmapTmp>{};
  final fmtps = <int, Map<String, String>>{};
  final fbByPt = <int, List<RtcpFb>>{};
  final hdrExts = <RtpHdrExt>[];
  final ssrcMap = <int, Map<String, String>>{};
  final candidates = <IceCandidate>[];
  final ssrcOrder = <int>[];
  var firstCandidateIp = '';

  for (final l in ml.skip(1)) {
    if (!l.startsWith('a=')) continue;
    final content = l.substring(2);
    final colon = content.indexOf(':');
    final key = colon < 0 ? content : content.substring(0, colon);
    final value = colon < 0 ? '' : content.substring(colon + 1);
    switch (key) {
      case 'mid':
        mid = value;
      case 'sendrecv':
      case 'sendonly':
      case 'recvonly':
      case 'inactive':
        direction = key;
      case 'ice-ufrag':
        ufrag = value;
      case 'ice-pwd':
        pwd = value;
      case 'setup':
        setup = value;
        hasFingerprintSetupOverride = true;
      case 'fingerprint':
        final sp = value.indexOf(' ');
        if (sp > 0) {
          fingerprint = JingleFingerprint(
            hash: value.substring(0, sp),
            setup: setup,
            value: value.substring(sp + 1).trim().toUpperCase(),
          );
        }
      case 'rtcp-mux':
        rtcpMux = true;
      case 'rtpmap':
        _parseRtpmap(value, rtpmaps);
      case 'fmtp':
        _parseFmtp(value, fmtps);
      case 'rtcp-fb':
        _parseRtcpFb(value, fbByPt);
      case 'extmap':
        final ext = _parseExtmap(value);
        if (ext != null) hdrExts.add(ext);
      case 'ssrc':
        _parseSsrc(value, ssrcMap, ssrcOrder);
      case 'candidate':
        final cand = _parseCandidateLine(value);
        if (cand != null) {
          candidates.add(cand);
          if (firstCandidateIp.isEmpty) firstCandidateIp = cand.ip;
        }
      default:
        break;
    }
  }

  if (fingerprint != null && hasFingerprintSetupOverride) {
    fingerprint = JingleFingerprint(
      hash: fingerprint.hash,
      setup: setup,
      value: fingerprint.value,
    );
  }
  if (candidates.isEmpty && port > 0) {
    // Session used a session-level c-line; not modeled here since we're
    // targeting the WebRTC subset which always ships ICE candidates.
  }

  final payloadTypes = ptIds.map((id) {
    final rm = rtpmaps[id];
    return PayloadType(
      id: id,
      name: rm?.name ?? '',
      clockrate: rm?.clockrate ?? 0,
      channels: rm?.channels,
      parameters: fmtps[id] ?? const {},
      rtcpFb: fbByPt[id] ?? const [],
    );
  }).toList();

  final ssrcs = ssrcOrder
      .map((id) => SourceSsrc(ssrc: id, parameters: ssrcMap[id] ?? const {}))
      .toList();

  return JingleContent(
    name: mid,
    creator: 'initiator',
    senders: _directionToSenders(direction),
    description: JingleRtpDescription(
      media: media,
      payloadTypes: payloadTypes,
      rtcpMux: rtcpMux,
      hdrExts: hdrExts,
      ssrcs: ssrcs,
    ),
    transport: JingleIceTransport(
      ufrag: ufrag,
      pwd: pwd,
      fingerprint: fingerprint,
      candidates: candidates,
    ),
  );
}

class _RtpmapTmp {
  _RtpmapTmp(this.name, this.clockrate, this.channels);
  final String name;
  final int clockrate;
  final int? channels;
}

void _parseRtpmap(String value, Map<int, _RtpmapTmp> out) {
  final sp = value.indexOf(' ');
  if (sp < 0) return;
  final id = int.tryParse(value.substring(0, sp));
  if (id == null) return;
  final desc = value.substring(sp + 1);
  final parts = desc.split('/');
  final name = parts[0];
  final clockrate = parts.length > 1 ? int.tryParse(parts[1]) ?? 0 : 0;
  final channels = parts.length > 2 ? int.tryParse(parts[2]) : null;
  out[id] = _RtpmapTmp(name, clockrate, channels);
}

void _parseFmtp(String value, Map<int, Map<String, String>> out) {
  final sp = value.indexOf(' ');
  if (sp < 0) return;
  final id = int.tryParse(value.substring(0, sp));
  if (id == null) return;
  final rest = value.substring(sp + 1);
  final params = <String, String>{};
  for (final kv in rest.split(';')) {
    final t = kv.trim();
    if (t.isEmpty) continue;
    final eq = t.indexOf('=');
    if (eq < 0) {
      params[t] = '';
    } else {
      params[t.substring(0, eq)] = t.substring(eq + 1);
    }
  }
  out[id] = params;
}

void _parseRtcpFb(String value, Map<int, List<RtcpFb>> out) {
  final sp = value.indexOf(' ');
  if (sp < 0) return;
  final ptTok = value.substring(0, sp);
  final tail = value.substring(sp + 1);
  // Wildcard `*` is not carried on Jingle payload-scoped rtcp-fb; skip.
  final pt = int.tryParse(ptTok);
  if (pt == null) return;
  final parts = tail.split(RegExp(r'\s+'));
  final type = parts.first;
  final subtype = parts.length > 1 ? parts.sublist(1).join(' ') : null;
  out
      .putIfAbsent(pt, () => <RtcpFb>[])
      .add(RtcpFb(type: type, subtype: subtype));
}

RtpHdrExt? _parseExtmap(String value) {
  final sp = value.indexOf(' ');
  if (sp < 0) return null;
  final head = value.substring(0, sp);
  final uri = value.substring(sp + 1).trim();
  final slash = head.indexOf('/');
  final idPart = slash < 0 ? head : head.substring(0, slash);
  final dir = slash < 0 ? null : head.substring(slash + 1);
  final id = int.tryParse(idPart);
  if (id == null) return null;
  return RtpHdrExt(id: id, uri: uri, direction: dir);
}

void _parseSsrc(
  String value,
  Map<int, Map<String, String>> out,
  List<int> order,
) {
  final sp = value.indexOf(' ');
  final idTok = sp < 0 ? value : value.substring(0, sp);
  final ssrc = int.tryParse(idTok);
  if (ssrc == null) return;
  if (!order.contains(ssrc)) order.add(ssrc);
  final params = out.putIfAbsent(ssrc, () => <String, String>{});
  if (sp < 0) return;
  final attr = value.substring(sp + 1);
  final colon = attr.indexOf(':');
  if (colon < 0) {
    params[attr] = '';
  } else {
    params[attr.substring(0, colon)] = attr.substring(colon + 1);
  }
}

IceCandidate? _parseCandidateLine(String value) {
  final toks = value.split(RegExp(r'\s+'));
  if (toks.length < 8) return null;
  final foundation = toks[0];
  final component = int.tryParse(toks[1]);
  final protocol = toks[2].toLowerCase();
  final priority = int.tryParse(toks[3]);
  final ip = toks[4];
  final port = int.tryParse(toks[5]);
  if (toks[6] != 'typ' ||
      component == null ||
      priority == null ||
      port == null) {
    return null;
  }
  final type = toks[7];
  String? relAddr;
  int? relPort;
  var generation = 0;
  String? tcpType;
  for (var i = 8; i < toks.length - 1; i += 2) {
    final k = toks[i];
    final v = toks[i + 1];
    switch (k) {
      case 'raddr':
        relAddr = v;
      case 'rport':
        relPort = int.tryParse(v);
      case 'generation':
        generation = int.tryParse(v) ?? 0;
      case 'tcptype':
        tcpType = v;
    }
  }
  return IceCandidate(
    component: component,
    foundation: foundation,
    ip: ip,
    port: port,
    priority: priority,
    protocol: protocol,
    type: type,
    generation: generation,
    relAddr: relAddr,
    relPort: relPort,
    tcpType: tcpType,
  );
}
