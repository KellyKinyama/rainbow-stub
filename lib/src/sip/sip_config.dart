import 'dart:io';

import 'package:sip_transport/sip_transport.dart';

/// Runtime config for the XMPP↔SIP gateway (M1+).
///
/// Kept intentionally minimal: the bridge lives on one UDP transport bound
/// to [bindAddress]:[bindPort] and forwards every outbound request through
/// [outboundProxyHost]:[outboundProxyPort]. Real RFC 3263 NAPTR/SRV
/// resolution is a later phase — for now the gateway resolves the proxy
/// hostname once at boot and reuses the address.
class SipConfig {
  const SipConfig({
    required this.enabled,
    required this.domain,
    required this.bindAddress,
    required this.bindPort,
    required this.outboundProxyHost,
    required this.outboundProxyPort,
    required this.localContactUri,
    required this.b2buaFromUri,
    this.mediaAnchor,
    this.dids = const <String, String>{},
    this.inboundRingTimeout = const Duration(seconds: 45),
    this.outboundTrickleWindow = const Duration(milliseconds: 500),
    this.sessionTimersEnabled = false,
    this.sessionTimerDuration = const Duration(minutes: 30),
    this.sessionTimerMinSe = const Duration(seconds: 90),
    this.authUsername,
    this.authPassword,
    this.transport = TransportProtocol.udp,
    this.tlsCertPath,
    this.tlsKeyPath,
    this.tlsAllowSelfSigned = false,
    this.registrar,
  });

  /// Disable the gateway from bootstrapping.
  static const disabled = SipConfig(
    enabled: false,
    domain: 'sip.invalid',
    bindAddress: '127.0.0.1',
    bindPort: 0,
    outboundProxyHost: '127.0.0.1',
    outboundProxyPort: 0,
    localContactUri: 'sip:disabled@127.0.0.1',
    b2buaFromUri: 'sip:disabled@127.0.0.1',
  );

  final bool enabled;

  /// XMPP domain suffix that routes to this gateway. Any stanza whose
  /// `to` JID sits in this domain (e.g. `+15551234@sip.rainbow-stub.local`)
  /// gets dispatched here instead of `StanzaRouter.fanOut(...)`.
  final String domain;

  /// Local UDP bind for the SIP listener.
  final String bindAddress;
  final int bindPort;

  /// Where every outbound request is sent (the SIP trunk or Asterisk).
  /// Resolved once at boot; no per-request DNS in M1.
  final String outboundProxyHost;
  final int outboundProxyPort;

  /// `Contact:` URI stamped on outbound requests.
  final String localContactUri;

  /// `From:` URI used when the gateway sends on its own behalf (e.g. when a
  /// caller JID cannot be mapped cleanly). Per-user text traffic uses the
  /// caller's own JID-mapped URI.
  final String b2buaFromUri;

  /// Optional rtpengine anchor. When null the gateway bridges SDP
  /// verbatim (suitable for Asterisk `webrtc=yes` endpoints).
  final MediaAnchorConfig? mediaAnchor;

  /// Inbound DID → Rainbow user id. Used to resolve the recipient of an
  /// incoming SIP call by the To-URI's user part.
  final Map<String, String> dids;

  /// How long to wait for any of the target user's XMPP sessions to
  /// answer an inbound call before returning 408 to the SIP peer.
  final Duration inboundRingTimeout;

  /// Half-trickle buffering window for outbound INVITEs (RFC 8840).
  /// If a `session-initiate` arrives with no ICE candidates, the
  /// gateway holds the INVITE for at most this long, accumulating
  /// candidates from subsequent `transport-info` IQs. Sending stops
  /// early on `<end-of-candidates/>`.
  final Duration outboundTrickleWindow;

  /// RFC 4028 session timers. When true, outbound INVITEs advertise
  /// `Session-Expires`, `Min-SE`, `Supported: timer`; the negotiated
  /// value from a 2xx response drives an in-dialog re-INVITE refresh
  /// at duration/2. Inbound peer refresh INVITEs are honored (200 OK
  /// with the same SDP).
  final bool sessionTimersEnabled;
  final Duration sessionTimerDuration;
  final Duration sessionTimerMinSe;

  /// RFC 7616 Digest credentials for outbound INVITE / REGISTER 401/407
  /// challenges. When null, a challenge is treated as a request failure.
  /// Up to 3 retries per request; multi-realm responses (proxy + endpoint
  /// challenging simultaneously) are answered with both `Authorization`
  /// and `Proxy-Authorization` headers.
  final String? authUsername;
  final String? authPassword;

  /// SIP transport for the local bind and outbound dial. UDP (default)
  /// is fine for lab / local Asterisk; TCP or TLS is required for
  /// production trunks that mandate connection-oriented transport
  /// (message size > MTU or peer policy).
  final TransportProtocol transport;

  /// TLS server certificate (PEM) and private key. Only consulted when
  /// [transport] is [TransportProtocol.tls]. When either is null the
  /// TLS transport falls back to the platform default context — usable
  /// for outbound-only mutual TLS.
  final String? tlsCertPath;
  final String? tlsKeyPath;

  /// Accept self-signed peer certificates on outbound TLS dials.
  /// Off by default; production trunks should ship a proper chain.
  final bool tlsAllowSelfSigned;

  /// Optional REGISTER-side account. When non-null, the gateway sends
  /// REGISTER on boot and refreshes at 0.75×`Expires`.
  final SipRegistrarConfig? registrar;
}

/// SIP registrar config — the gateway registers itself with an
/// upstream server so inbound INVITEs from arbitrary peers reach it
/// without a static route.
class SipRegistrarConfig {
  const SipRegistrarConfig({
    required this.aor,
    required this.registrarHost,
    this.registrarPort,
    this.expiresSeconds = 3600,
  });

  /// Address-of-record — `sip:alice@registrar.example.com`.
  final String aor;

  /// Registrar host used to build the Request-URI and outbound socket.
  final String registrarHost;

  /// Optional override; falls back to the transport's default port.
  final int? registrarPort;

  /// Requested registration lifetime in seconds.
  final int expiresSeconds;
}

/// rtpengine_dart REST anchor config for the media plane.
class MediaAnchorConfig {
  const MediaAnchorConfig({required this.baseUri, this.authToken});
  final String baseUri;
  final String? authToken;
}

/// Resolve [SipConfig.outboundProxyHost] to a concrete [InternetAddress].
/// Falls back to a literal parse if DNS returns nothing.
Future<InternetAddress> resolveOutboundProxy(SipConfig c) async {
  try {
    return InternetAddress(c.outboundProxyHost);
  } on ArgumentError {
    final r = await InternetAddress.lookup(c.outboundProxyHost);
    if (r.isEmpty) {
      throw StateError('cannot resolve SIP outbound proxy '
          '"${c.outboundProxyHost}"');
    }
    return r.first;
  }
}
