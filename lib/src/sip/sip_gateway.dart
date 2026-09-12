import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:logging/logging.dart';
import 'package:sip_core/sip_core.dart';
import 'package:sip_dialog/sip_dialog.dart';
import 'package:sip_dns/sip_dns.dart';
import 'package:sip_media/sip_media.dart';
import 'package:sip_transport/sip_transport.dart';
import 'package:sip_uac/sip_uac.dart';
import 'package:sip_uas/sip_uas.dart';
import 'package:xml/xml.dart';

import '../calllog/calllog_repository.dart';
import '../messages/message_repository.dart';
import '../metrics/metrics.dart';
import '../users/user_repository.dart';
import '../xmpp/jid.dart';
import '../xmpp/router.dart';
import 'digest_auth.dart';
import 'jingle_sdp.dart';
import 'sip_config.dart';
import 'sip_jid.dart';

final _log = Logger('sip.gateway');

const _dtmfNs = 'urn:xmpp:jingle:dtmf:0';
const _rtpInfoNs = 'urn:xmpp:jingle:apps:rtp:info:1';

/// XMPP↔SIP bridge — M1: text only (`<message type="chat">` ↔ SIP MESSAGE).
///
/// Boots one [UdpSipTransport] on the configured bind and wires:
///   * a [TransactionalUacRunner] for outbound MESSAGE traffic
///   * a [TransactionalUasRunner] whose `onNonDialogRequest` accepts
///     inbound MESSAGE, persists it via [MessageRepository], and fans it
///     out via [StanzaRouter].
/// INVITE / dialog handling arrives in M2+.
class SipGateway {
  SipGateway._({
    required this.config,
    required this.xmppDomain,
    required this.router,
    required this.users,
    required this.messages,
    required this.callLog,
    required this.metrics,
    required SipTransport transport,
    required List<Endpoint> outboundEndpoints,
    MediaAnchor? mediaAnchor,
    RtpengineClient? rtpengineClient,
    Random? random,
  })  : _transport = transport,
        _outboundEndpoints = outboundEndpoints,
        _mediaAnchor = mediaAnchor,
        _rtpengineClient = rtpengineClient,
        _rng = random ?? Random.secure() {
    assert(outboundEndpoints.isNotEmpty, 'need at least one outbound endpoint');
    final localContact = NameAddr.parse('<${config.localContactUri}>');
    _dialogStore = InMemoryDialogStore();
    _uac = TransactionalUacRunner(
      transport: _transport,
      localContact: localContact,
      dialogStore: _dialogStore,
      onError: _onError,
    );
    _uas = TransactionalUasRunner(
      transport: _transport,
      dialogStore: _dialogStore,
      localContact: localContact,
      onInvite: _onInboundInvite,
      onInDialogRequest: _onInDialogRequest,
      onNonDialogRequest: _onNonDialogRequest,
      onError: _onError,
    );
  }

  final SipConfig config;
  final String xmppDomain;
  final StanzaRouter router;
  final UserRepository users;
  final MessageRepository messages;
  final CallLogRepository callLog;
  final MetricsRegistry metrics;

  final SipTransport _transport;

  /// RFC 3263-ordered outbound targets: head is primary, the rest are
  /// failover candidates tried in order when a transaction fails at the
  /// transport level (timeout / connectivity).
  final List<Endpoint> _outboundEndpoints;
  final MediaAnchor? _mediaAnchor;
  final RtpengineClient? _rtpengineClient;
  final Random _rng;
  late final DialogStore _dialogStore;
  late final TransactionalUacRunner _uac;
  late final TransactionalUasRunner _uas;
  final Map<String, _OutboundCall> _callsBySid = {};
  final Map<String, _InboundCall> _inboundCallsBySid = {};
  final Map<String, _InboundCall> _inboundCallsByCallId = {};
  var _running = false;

  /// Primary outbound endpoint — head of the RFC 3263-ordered list.
  /// Used for out-of-dialog MESSAGE, REGISTER, and as the default for
  /// in-dialog requests whose call hasn't recorded a winning endpoint.
  Endpoint get _outboundEndpoint => _outboundEndpoints.first;

  /// SIP-domain suffix that routes to this gateway.
  String get sipDomain => config.domain;

  /// Boot a live UDP gateway. Throws if the transport can't bind or the
  /// outbound proxy can't be resolved.
  static Future<SipGateway> boot({
    required SipConfig config,
    required String xmppDomain,
    required StanzaRouter router,
    required UserRepository users,
    required MessageRepository messages,
    required CallLogRepository callLog,
    required MetricsRegistry metrics,
    DnsResolver? dnsResolver,
  }) async {
    final transport = _buildTransport(config);
    await transport.start();
    final outboundEps = await _resolveOutboundEndpoints(
      config,
      dnsResolver ?? const SystemDnsResolver(),
    );
    MediaAnchor? anchor;
    RtpengineClient? rtpClient;
    final ac = config.mediaAnchor;
    if (ac != null) {
      rtpClient = RtpengineClient.http(
        baseUri: Uri.parse(ac.baseUri),
        authToken: ac.authToken,
      );
      anchor = MediaAnchor(client: rtpClient);
    }
    final gw = SipGateway._(
      config: config,
      xmppDomain: xmppDomain,
      router: router,
      users: users,
      messages: messages,
      callLog: callLog,
      metrics: metrics,
      transport: transport,
      outboundEndpoints: outboundEps,
      mediaAnchor: anchor,
      rtpengineClient: rtpClient,
    );
    gw._start();
    _log.info('SIP gateway up at ${transport.localEndpoint} '
        '→ ${outboundEps.first} (+${outboundEps.length - 1} failover) '
        'domain="${config.domain}" '
        'media=${anchor == null ? 'passthrough' : 'rtpengine'}');
    if (config.registrar != null) {
      unawaited(gw._startRegister());
    }
    metrics
      ..registerHelp(
        name: 'rainbow_stub_sip_gateway_up',
        help: 'SIP gateway boot state.',
        type: 'gauge',
      )
      ..registerHelp(
        name: 'rainbow_stub_sip_messages_out_total',
        help: 'SIP MESSAGE requests emitted by the gateway.',
        type: 'counter',
      )
      ..registerHelp(
        name: 'rainbow_stub_sip_messages_in_total',
        help: 'SIP MESSAGE requests accepted from a SIP peer.',
        type: 'counter',
      )
      ..registerHelp(
        name: 'rainbow_stub_sip_calls_active',
        help: 'Currently-active SIP dialogs the gateway is bridging.',
        type: 'gauge',
      )
      ..registerHelp(
        name: 'rainbow_stub_sip_calls_total',
        help: 'Cumulative SIP calls handled by the gateway, by outcome.',
        type: 'counter',
      )
      ..registerHelp(
        name: 'rainbow_stub_sip_dtmf_out_total',
        help: 'DTMF digits injected via rtpengine.',
        type: 'counter',
      )
      ..registerHelp(
        name: 'rainbow_stub_sip_holds_total',
        help: 'Hold / unhold re-INVITEs emitted by the gateway.',
        type: 'counter',
      )
      ..registerHelp(
        name: 'rainbow_stub_sip_session_expired_total',
        help: 'Calls torn down after a missed RFC 4028 session refresh.',
        type: 'counter',
      )
      ..registerHelp(
        name: 'rainbow_stub_sip_session_422_total',
        help: 'Refresh requests rejected with 422 (Se below Min-SE).',
        type: 'counter',
      )
      ..setGauge('rainbow_stub_sip_gateway_up', 1)
      ..setGauge('rainbow_stub_sip_calls_active', 0);
    return gw;
  }

  static SipTransport _buildTransport(SipConfig config) {
    final addr = InternetAddress(config.bindAddress);
    switch (config.transport) {
      case TransportProtocol.udp:
        return UdpSipTransport(bindAddress: addr, bindPort: config.bindPort);
      case TransportProtocol.tcp:
        return TcpSipTransport(bindAddress: addr, bindPort: config.bindPort);
      case TransportProtocol.tls:
        final ctx = SecurityContext();
        final certPath = config.tlsCertPath;
        final keyPath = config.tlsKeyPath;
        if (certPath != null && keyPath != null) {
          ctx
            ..useCertificateChain(certPath)
            ..usePrivateKey(keyPath);
        }
        return TlsSipTransport(
          bindAddress: addr,
          bindPort: config.bindPort,
          serverContext: ctx,
          onBadCertificate: config.tlsAllowSelfSigned ? (_) => true : null,
        );
      case TransportProtocol.ws:
      case TransportProtocol.wss:
        throw ArgumentError.value(
          config.transport,
          'transport',
          'WS/WSS not yet supported by the gateway (use xmpp WS instead)',
        );
    }
  }

  /// RFC 3263 §4 — resolve the outbound proxy target into an ordered
  /// endpoint list (primary + failover). Falls back to a single
  /// literal/A-record endpoint when SRV/NAPTR yield nothing.
  static Future<List<Endpoint>> _resolveOutboundEndpoints(
    SipConfig config,
    DnsResolver dnsResolver,
  ) async {
    final scheme = config.transport == TransportProtocol.tls ? 'sips' : 'sip';
    final transportParam = switch (config.transport) {
      TransportProtocol.udp => 'udp',
      TransportProtocol.tcp => 'tcp',
      TransportProtocol.tls => 'tls',
      _ => null,
    };
    // An explicit port pins the target (RFC 3263 §4.2 — skip NAPTR/SRV).
    // Port 0 means "unset" in our config, so omit it to allow SRV.
    final hasPort = config.outboundProxyPort > 0;
    final host = config.outboundProxyHost;
    final uriStr = StringBuffer('$scheme:$host');
    if (hasPort) uriStr.write(':${config.outboundProxyPort}');
    if (transportParam != null) uriStr.write(';transport=$transportParam');

    try {
      final resolver = SipResolver(resolver: dnsResolver);
      final endpoints = await resolver.resolve(SipUri.parse(uriStr.toString()));
      if (endpoints.isNotEmpty) return endpoints;
    } catch (e, st) {
      _log.warning(
          'RFC 3263 resolve failed for "$uriStr" — '
          'falling back to literal',
          e,
          st);
    }
    // Fallback: single endpoint from the legacy one-shot resolver.
    final addr = await resolveOutboundProxy(config);
    return [
      Endpoint(
        address: addr,
        port: hasPort ? config.outboundProxyPort : config.transport.defaultPort,
        protocol: config.transport,
      ),
    ];
  }

  /// Test hook: wrap pre-built collaborators. Skips the UDP bind + DNS.
  static SipGateway forTesting({
    required SipConfig config,
    required String xmppDomain,
    required StanzaRouter router,
    required UserRepository users,
    required MessageRepository messages,
    required CallLogRepository callLog,
    required MetricsRegistry metrics,
    required SipTransport transport,
    required Endpoint outboundEndpoint,
    List<Endpoint>? outboundEndpoints,
    MediaAnchor? mediaAnchor,
    RtpengineClient? rtpengineClient,
    Random? random,
  }) {
    metrics
      ..registerHelp(
        name: 'rainbow_stub_sip_calls_active',
        help: 'Currently-active SIP dialogs the gateway is bridging.',
        type: 'gauge',
      )
      ..registerHelp(
        name: 'rainbow_stub_sip_calls_total',
        help: 'Cumulative SIP calls handled by the gateway, by outcome.',
        type: 'counter',
      )
      ..setGauge('rainbow_stub_sip_calls_active', 0);
    final gw = SipGateway._(
      config: config,
      xmppDomain: xmppDomain,
      router: router,
      users: users,
      messages: messages,
      callLog: callLog,
      metrics: metrics,
      transport: transport,
      outboundEndpoints: outboundEndpoints ?? [outboundEndpoint],
      mediaAnchor: mediaAnchor,
      rtpengineClient: rtpengineClient,
      random: random,
    );
    gw._start();
    return gw;
  }

  void _start() {
    if (_running) return;
    _running = true;
    _uac.start();
    // TransactionalUasRunner.start is async; kick it and fail loud on error.
    unawaited(_uas.start().catchError((Object e, StackTrace st) {
      _log.severe('SIP UAS runner failed to start', e, st);
    }));
  }

  Future<void> stop() async {
    if (!_running) return;
    _running = false;
    _registerRefresh?.cancel();
    await _uas.stop();
    await _uac.stop();
    await _transport.close();
    metrics.setGauge('rainbow_stub_sip_gateway_up', 0);
  }

  // ---- XMPP → SIP: outbound MESSAGE (RFC 3428) -----------------------------

  /// Send a chat body from a Rainbow user to a SIP peer. Returns `true` on
  /// a 2xx response, `false` on any other final response or transport
  /// failure. Blocks until the client transaction terminates.
  Future<bool> sendText({
    required Jid from,
    required Jid to,
    required String body,
    required String stanzaId,
  }) async {
    if (!_running) {
      _log.warning('sendText called on stopped SipGateway');
      return false;
    }
    final fromUri = SipJid.toSipUri(from);
    final toUri = SipJid.toSipUri(to);
    final req = OutboundRequest(
      method: 'MESSAGE',
      requestUri: toUri,
      from: SipJid.toNameAddr(fromUri),
      to: SipJid.toNameAddr(toUri),
      callId: stanzaId,
      body: utf8.encode(body),
      contentType: 'text/plain; charset=utf-8',
    );
    try {
      final handle = await _uac.send(req, _outboundEndpoint);
      final fin = await handle.finalResponse;
      final ok = fin.statusCode >= 200 && fin.statusCode < 300;
      _log.info('MESSAGE out to $to → ${fin.statusCode} ${fin.reasonPhrase}');
      metrics.inc(
        'rainbow_stub_sip_messages_out_total',
        labels: {'status': ok ? 'ok' : 'err'},
      );
      return ok;
    } on UacTransactionTimeoutException catch (e) {
      _log.warning('MESSAGE to $to timed out: $e');
      metrics.inc(
        'rainbow_stub_sip_messages_out_total',
        labels: {'status': 'timeout'},
      );
      return false;
    } catch (e, st) {
      _log.warning('MESSAGE to $to failed', e, st);
      metrics.inc(
        'rainbow_stub_sip_messages_out_total',
        labels: {'status': 'err'},
      );
      return false;
    }
  }

  // ---- SIP → XMPP: inbound MESSAGE handler ---------------------------------

  FutureOr<UasReply> _onNonDialogRequest(InboundSipMessage inbound) {
    final req = inbound.message as SipRequest;
    final method = req.method.toUpperCase();
    if (method == 'OPTIONS') {
      return UasReply.status(200, 'OK');
    }
    if (method != 'MESSAGE') {
      return UasReply.status(405, 'Method Not Allowed');
    }
    return _handleInboundMessage(req);
  }

  UasReply _handleInboundMessage(SipRequest req) {
    final NameAddr fromAddr;
    final NameAddr toAddr;
    try {
      fromAddr = req.parseFrom();
      toAddr = req.parseTo();
    } catch (e) {
      _log.warning('malformed inbound MESSAGE: $e');
      metrics.inc(
        'rainbow_stub_sip_messages_in_total',
        labels: {'status': 'err'},
      );
      return UasReply.status(400, 'Bad Request');
    }

    // Recipient user resolution: `sip:<userId>@<xmppDomain>` maps to the
    // Rainbow user with id=<userId>. Anything else is out of the bridge's
    // routable set for M1.
    final rcptJid = SipJid.fromSipUri(toAddr.uri);
    if (rcptJid.domain != xmppDomain ||
        rcptJid.local.isEmpty ||
        users.findById(rcptJid.local) == null) {
      metrics.inc(
        'rainbow_stub_sip_messages_in_total',
        labels: {'status': 'err'},
      );
      return UasReply.status(404, 'Not Found');
    }

    // Sender: preserve the SIP identity as a pseudo-JID under the SIP
    // subdomain (`sip:+15551234@sip.rainbow-stub.local`). MAM persists it
    // so it shows up in the recipient's Recent chat unchanged across
    // reconnects.
    final peerLocal = SipJid.normalizeLocal(fromAddr.uri.user ?? '');
    if (peerLocal.isEmpty) {
      metrics.inc(
        'rainbow_stub_sip_messages_in_total',
        labels: {'status': 'err'},
      );
      return UasReply.status(400, 'Bad Request');
    }
    final peerJid = Jid(local: peerLocal, domain: sipDomain);
    final rcptFullJid = Jid(local: rcptJid.local, domain: xmppDomain);

    final contentType = req.firstHeader('content-type')?.value() ?? '';
    if (!contentType.trim().toLowerCase().startsWith('text/')) {
      metrics.inc(
        'rainbow_stub_sip_messages_in_total',
        labels: {'status': 'err'},
      );
      return UasReply.status(415, 'Unsupported Media Type');
    }

    final bodyBytes = req.bodyBytes();
    final body = utf8.decode(bodyBytes, allowMalformed: true);
    final stanzaId = req.callId ?? _fallbackStanzaId(req);

    final saved = messages.insert(
      from: peerJid,
      to: rcptFullJid,
      stanzaId: stanzaId,
      body: body,
    );
    final xml = _buildIncomingMessageStanza(
      from: peerJid,
      to: rcptFullJid,
      stanzaId: saved.stanzaId,
      body: body,
    );
    router.fanOut(rcptFullJid.local, xml);
    metrics.inc(
      'rainbow_stub_sip_messages_in_total',
      labels: {'status': 'ok'},
    );
    _log.info('MESSAGE in from $peerJid → $rcptFullJid (${body.length}B)');
    return UasReply.status(200, 'OK');
  }

  String _fallbackStanzaId(SipRequest req) {
    // Best effort — Call-ID is required per RFC 3261 §8.1.1.4, but we
    // don't want to panic if a peer omits it.
    return 'sip-${DateTime.now().microsecondsSinceEpoch}';
  }

  String _buildIncomingMessageStanza({
    required Jid from,
    required Jid to,
    required String stanzaId,
    required String body,
  }) {
    return '<message xmlns="jabber:client" '
        'from="${_esc(from.toString())}" '
        'to="${_esc(to.toString())}" '
        'type="chat" id="${_esc(stanzaId)}">'
        '<body>${_esc(body)}</body>'
        '</message>';
  }

  void _onError(Object error, StackTrace stack) {
    _log.warning('sip transport/tx error', error, stack);
  }

  // ---- XMPP → SIP: outbound Jingle (XEP-0166) ------------------------------

  /// Entry point from `XmppWsSession._handleJingle` when the target JID sits
  /// in the SIP subdomain. Handled asynchronously; the caller has already
  /// sent an `<iq type="result"/>` to the client to unwind their IQ
  /// bookkeeping (XEP-0166 §7.2 — Jingle IQs are stateless).
  Future<void> onJingle({
    required Jid callerJid,
    required Jid calleeJid,
    required XmlElement jingle,
  }) async {
    if (!_running) {
      _log.warning('onJingle called on stopped SipGateway');
      return;
    }
    final action = jingle.getAttribute('action') ?? '';
    final sid = jingle.getAttribute('sid') ?? '';
    if (sid.isEmpty) {
      _log.warning('Jingle iq missing sid; dropping action=$action');
      return;
    }
    // Inbound (peer → us) calls are keyed by a gateway-minted sid the
    // client is echoing back — try that path first.
    final inbound = _inboundCallsBySid[sid];
    if (inbound != null) {
      await _handleInboundJingle(
        call: inbound,
        action: action,
        callerJid: callerJid,
        jingle: jingle,
      );
      return;
    }
    try {
      switch (action) {
        case 'session-initiate':
          await _startOutbound(
            sid: sid,
            callerJid: callerJid,
            calleeJid: calleeJid,
            jingle: jingle,
          );
        case 'session-terminate':
          await _terminateOutbound(sid: sid, jingle: jingle, byClient: true);
        case 'session-info':
          final call = _callsBySid[sid];
          if (call != null) {
            await _handleOutboundSessionInfo(call, jingle);
          }
        case 'transport-info':
          final call = _callsBySid[sid];
          if (call == null) {
            _log.fine('transport-info for unknown sid=$sid; ignored');
          } else if (!call.dispatched) {
            _mergeTransportInfoCandidates(call, jingle);
          } else if (call.answeredAt != null) {
            await _reofferAfterTrickle(call, jingle);
          } else {
            _mergeTransportInfoCandidates(call, jingle);
            _log.fine('trickle after dispatch pre-answer sid=$sid; buffered');
          }
        case 'session-accept':
        case 'transport-replace':
        case 'transport-accept':
        case 'transport-reject':
          _log.fine('ignoring Jingle action=$action sid=$sid');
        default:
          _log.warning('unsupported Jingle action=$action sid=$sid');
      }
    } catch (e, st) {
      _log.warning('onJingle failed action=$action sid=$sid', e, st);
    }
  }

  Future<void> _startOutbound({
    required String sid,
    required Jid callerJid,
    required Jid calleeJid,
    required XmlElement jingle,
  }) async {
    if (_callsBySid.containsKey(sid)) {
      _log.warning('duplicate session-initiate sid=$sid; ignoring');
      return;
    }
    final jingleSession = jingleSessionFromXml(jingle);
    final fromTag = _newTag();
    final call = _OutboundCall(
      sid: sid,
      callerJid: callerJid,
      calleeJid: calleeJid,
      fromTag: fromTag,
      startedAt: DateTime.now().toUtc(),
    );
    _callsBySid[sid] = call;
    _updateActiveGauge();

    // Half-trickle (RFC 8840): if the initiate carries no ICE candidates
    // and no explicit end-of-candidates, buffer the INVITE while
    // subsequent transport-info IQs accumulate candidates. Existing
    // "full offer" clients (candidates in session-initiate) dispatch
    // immediately — unchanged from M2 behavior.
    final complete =
        _hasAnyCandidate(jingleSession) || _jingleHasEndOfCandidates(jingle);
    if (complete) {
      call.pendingJingleSession = jingleSession;
      await _dispatchOutboundInvite(call);
      return;
    }
    _log.info('trickle-ICE: buffering INVITE sid=$sid '
        '(window=${config.outboundTrickleWindow.inMilliseconds}ms)');
    call.pendingJingleSession = jingleSession;
    call.trickleTimer = Timer(config.outboundTrickleWindow, () {
      if (call.dispatched) return;
      _log.info('trickle-ICE: window elapsed, dispatching sid=$sid');
      unawaited(_dispatchOutboundInvite(call));
    });
  }

  Future<void> _dispatchOutboundInvite(_OutboundCall call) async {
    if (call.dispatched) return;
    call.dispatched = true;
    call.trickleTimer?.cancel();
    call.trickleTimer = null;

    final sid = call.sid;
    final jingleSession = call.pendingJingleSession;
    if (jingleSession == null) {
      _log.warning('dispatch without pending jingle sid=$sid; aborting');
      _forgetCall(sid);
      return;
    }
    final rawSdp = jingleSessionToSdp(jingleSession);
    final fromTag = call.fromTag;

    // Anchor the caller's offer through rtpengine, or pass through when
    // no anchor is configured (e.g. Asterisk `webrtc=yes` deployments).
    Uint8List anchoredOffer;
    final anchor = _mediaAnchor;
    if (anchor != null) {
      anchoredOffer = await anchor.anchorOffer(
        callId: sid,
        fromTag: fromTag,
        sdp: Uint8List.fromList(utf8.encode(rawSdp)),
      );
    } else {
      anchoredOffer = Uint8List.fromList(utf8.encode(rawSdp));
    }

    final callerUri = SipJid.toSipUri(call.callerJid);
    final calleeUri = SipJid.toSipUri(call.calleeJid);
    final req = OutboundRequest(
      method: 'INVITE',
      requestUri: calleeUri,
      from: SipJid.toNameAddr(callerUri),
      to: SipJid.toNameAddr(calleeUri),
      callId: sid,
      body: anchoredOffer,
      contentType: 'application/sdp',
      extraHeaders: _sessionTimerRequestHeaders(),
    );

    call.currentOfferSdp = utf8.decode(anchoredOffer, allowMalformed: true);

    await _runInviteTransaction(call, req);
  }

  /// One INVITE round: launch the transaction, relay provisionals, and
  /// react to the final response. May recurse exactly once on 401/407
  /// when digest credentials are configured.
  Future<void> _runInviteTransaction(
    _OutboundCall call,
    OutboundRequest req,
  ) async {
    final sid = call.sid;
    final anchor = _mediaAnchor;
    final UacInviteHandle handle;
    try {
      handle = await _uac.invite(req, _outboundEndpoint);
    } catch (e, st) {
      _log.warning('INVITE launch failed sid=$sid', e, st);
      _forgetCall(sid);
      _sendJingleTerminate(
        call: call,
        reason: 'connectivity-error',
      );
      _writeCallLogFailure(call);
      metrics.inc(
        'rainbow_stub_sip_calls_total',
        labels: {'outcome': 'failed'},
      );
      return;
    }
    call.handle = handle;

    // Provisional relay: 1xx > 100 → Jingle session-info <ringing/>.
    final sub = handle.responses.listen((resp) {
      final code = resp.statusCode;
      if (code > 100 && code < 200 && !call.ringingSent) {
        call.ringingSent = true;
        _sendJingleRinging(call);
      }
    });

    final SipResponse fin;
    try {
      fin = await handle.finalResponse;
    } on UacTransactionTimeoutException {
      await sub.cancel();
      _forgetCall(call.sid);
      _sendJingleTerminate(call: call, reason: 'timeout');
      _writeCallLogFailure(call);
      metrics.inc(
        'rainbow_stub_sip_calls_total',
        labels: {'outcome': 'timeout'},
      );
      return;
    } catch (e, st) {
      await sub.cancel();
      _log.warning('INVITE final response error sid=${call.sid}', e, st);
      _forgetCall(call.sid);
      _sendJingleTerminate(call: call, reason: 'connectivity-error');
      _writeCallLogFailure(call);
      metrics.inc(
        'rainbow_stub_sip_calls_total',
        labels: {'outcome': 'failed'},
      );
      return;
    }
    await sub.cancel();

    // If the client already sent session-terminate (or a peer error already
    // tore the call down), `_terminateOutbound` will have removed the sid
    // from `_callsBySid` — its own path handled Jingle relay + call-log.
    // Bail out here to avoid double-logging / double-emit.
    if (!_callsBySid.containsKey(call.sid)) {
      return;
    }

    final code = fin.statusCode;
    if (code == 401 || code == 407) {
      final retry = _rebuildInviteWithDigest(call, fin, req);
      if (retry != null) {
        _log.info('digest challenge $code — retrying sid=${call.sid}');
        return _runInviteTransaction(call, retry);
      }
    }
    if (code < 200 || code >= 300) {
      // Non-2xx final — auto-ACK is emitted by the FSM (§17.1.1.3).
      _forgetCall(call.sid);
      _sendJingleTerminate(call: call, reason: _mapReason(code));
      _writeCallLogFailure(call);
      metrics.inc(
        'rainbow_stub_sip_calls_total',
        labels: {'outcome': code == 486 || code == 487 ? 'declined' : 'failed'},
      );
      return;
    }

    // 2xx — capture callee to-tag, anchor the answer, relay to XMPP.
    final toAddr = fin.parseTo();
    final toTag = toAddr.tag ?? '';
    call.toTag = toTag;
    call.answeredAt = DateTime.now().toUtc();

    Uint8List anchoredAnswer;
    final rawAnswer = fin.bodyBytes();
    if (anchor != null && toTag.isNotEmpty && rawAnswer.isNotEmpty) {
      anchoredAnswer = await anchor.anchorAnswer(
        callId: call.sid,
        fromTag: call.fromTag,
        toTag: toTag,
        sdp: rawAnswer,
      );
    } else {
      anchoredAnswer = rawAnswer;
    }

    try {
      await handle.ack();
    } catch (e, st) {
      _log.warning('2xx ACK send failed sid=${call.sid}', e, st);
    }

    try {
      final answerSdp = utf8.decode(anchoredAnswer, allowMalformed: true);
      final answerSession = jingleSessionFromSdp(answerSdp);
      _sendJingleAccept(call: call, jingleSession: answerSession);
    } catch (e, st) {
      _log.warning('session-accept build failed sid=${call.sid}', e, st);
    }

    // Session-timer negotiation from the 2xx response.
    if (config.sessionTimersEnabled) {
      final seHeader = fin.firstHeader('session-expires')?.value();
      final se = seHeader == null ? null : _seDuration(seHeader);
      if (se != null) {
        call.sessionExpires = se;
        call.refresherIsUs = _peerExpectsUacRefresh(seHeader);
        _scheduleOutboundSessionRefresh(call);
      }
    }

    _log.info('SIP call answered sid=${call.sid} caller=${call.callerJid} '
        'callee=${call.calleeJid}');
  }

  // ---- Trickle-ICE helpers -------------------------------------------------

  bool _hasAnyCandidate(JingleSession s) =>
      s.contents.any((c) => c.transport.candidates.isNotEmpty);

  bool _jingleHasEndOfCandidates(XmlElement jingle) {
    for (final content in jingle.findElements('content')) {
      for (final transport in content.findElements('transport')) {
        if (transport.getElement('end-of-candidates') != null) {
          return true;
        }
      }
    }
    return false;
  }

  /// Merge candidates from a `transport-info` IQ into the pending Jingle
  /// session and, on `<end-of-candidates/>`, dispatch the INVITE.
  void _mergeTransportInfoCandidates(_OutboundCall call, XmlElement jingle) {
    final pending = call.pendingJingleSession;
    if (pending == null) return;
    var merged = 0;
    for (final content in jingle.findElements('content')) {
      final name = content.getAttribute('name') ?? '';
      final target = pending.contents
          .cast<JingleContent?>()
          .firstWhere((c) => c?.name == name, orElse: () => null);
      if (target == null) {
        _log.fine('trickle: unknown content name="$name" sid=${call.sid}');
        continue;
      }
      for (final transport in content.findElements('transport')) {
        for (final cand in transport.findElements('candidate')) {
          try {
            target.transport.candidates.add(iceCandidateFromXml(cand));
            merged++;
          } catch (e) {
            _log.fine('trickle: bad candidate sid=${call.sid}: $e');
          }
        }
      }
    }
    final eol = _jingleHasEndOfCandidates(jingle);
    _log.fine('trickle: merged $merged candidate(s) sid=${call.sid} '
        'end-of-candidates=$eol');
    if (eol && !call.dispatched) {
      call.trickleTimer?.cancel();
      call.trickleTimer = null;
      unawaited(_dispatchOutboundInvite(call));
    }
  }

  Future<void> _terminateOutbound({
    required String sid,
    required XmlElement jingle,
    required bool byClient,
  }) async {
    final call = _callsBySid.remove(sid);
    if (call == null) {
      _log.fine('session-terminate for unknown sid=$sid');
      return;
    }
    _updateActiveGauge();
    call.terminatedByClient = byClient;
    call.endedAt ??= DateTime.now().toUtc();

    final handle = call.handle;
    if (handle == null) {
      _writeCallLogSuccess(call);
      return;
    }

    if (call.answeredAt == null) {
      try {
        await handle.cancel();
      } catch (e, st) {
        _log.warning('CANCEL failed sid=$sid', e, st);
      }
    } else {
      // In-dialog BYE via Dialog.buildRequest — one-shot, not retransmitted.
      final dialog = handle.dialog;
      if (dialog != null) {
        try {
          final via = _newVia();
          final bytes = dialog.buildRequest(method: 'BYE', via: via);
          await _transport.send(bytes, _outboundEndpoint);
        } catch (e, st) {
          _log.warning('BYE send failed sid=$sid', e, st);
        }
      }
    }

    final anchor = _mediaAnchor;
    if (anchor != null) {
      try {
        await anchor.tearDown(sid);
      } catch (e, st) {
        _log.warning('rtpengine teardown failed sid=$sid', e, st);
      }
    }

    _writeCallLogSuccess(call);
    metrics.inc(
      'rainbow_stub_sip_calls_total',
      labels: {'outcome': call.answeredAt == null ? 'canceled' : 'answered'},
    );
  }

  void _forgetCall(String sid) {
    final removed = _callsBySid.remove(sid);
    removed?.sessionTimer?.cancel();
    removed?.trickleTimer?.cancel();
    _updateActiveGauge();
  }

  // ---- REGISTER (RFC 3261 §10) --------------------------------------------

  final Map<String, int> _registerNc = <String, int>{};
  int _registerRetries = 0;
  Timer? _registerRefresh;

  Future<void> _startRegister() async {
    // Deferred slightly so tests / boot metrics registration finish.
    await Future<void>.delayed(Duration.zero);
    await _sendRegister();
  }

  /// Test hook — the public `boot` path calls `_startRegister` on its
  /// own; the `forTesting` path skips it so tests can wire the
  /// registrar peer first, then trigger REGISTER on demand.
  Future<void> startRegisterForTesting() => _startRegister();

  Future<void> _sendRegister({int cseq = 1}) async {
    final reg = config.registrar;
    if (reg == null) return;
    final port = reg.registrarPort ?? config.transport.defaultPort;
    final requestUri = SipUri.parse('sip:${reg.registrarHost}:$port');
    final aor = NameAddr.parse('<${reg.aor}>');
    final contactUri = config.localContactUri;
    final req = OutboundRequest(
      method: 'REGISTER',
      requestUri: requestUri,
      from: aor,
      to: aor,
      contact: NameAddr.parse('<$contactUri>'),
      cseq: cseq,
      extraHeaders: [
        MapEntry('Expires', '${reg.expiresSeconds}'),
      ],
    );
    UacRequestHandle handle;
    try {
      handle = await _uac.send(req, _outboundEndpoint);
    } catch (e, st) {
      _log.warning('REGISTER launch failed', e, st);
      metrics.inc('rainbow_stub_sip_register_total',
          labels: {'result': 'launch-error'});
      return _scheduleRegisterRetry();
    }
    final SipResponse fin;
    try {
      fin = await handle.finalResponse;
    } catch (e, st) {
      _log.warning('REGISTER final response error', e, st);
      metrics.inc('rainbow_stub_sip_register_total',
          labels: {'result': 'timeout'});
      return _scheduleRegisterRetry();
    }
    final code = fin.statusCode;
    if ((code == 401 || code == 407) && _registerRetries < 3) {
      final computed = _computeDigestHeaders(
        challenge: fin,
        method: 'REGISTER',
        requestUri: requestUri.toString(),
        priorNc: _registerNc,
      );
      if (computed != null) {
        _registerRetries++;
        _registerNc
          ..clear()
          ..addAll(computed.ncByRealm);
        metrics.inc('rainbow_stub_sip_auth_challenges_total',
            labels: {'code': '$code'});
        final retry = OutboundRequest(
          method: req.method,
          requestUri: req.requestUri,
          from: req.from,
          to: req.to,
          callId: req.callId,
          cseq: req.cseq + 1,
          contact: req.contact,
          body: req.body,
          contentType: req.contentType,
          maxForwards: req.maxForwards,
          extraHeaders: [
            ...req.extraHeaders,
            ...computed.headers,
          ],
        );
        try {
          final retryHandle = await _uac.send(retry, _outboundEndpoint);
          final retryFin = await retryHandle.finalResponse;
          return _handleRegisterFinal(retryFin);
        } catch (e, st) {
          _log.warning('REGISTER retry failed', e, st);
          metrics.inc('rainbow_stub_sip_register_total',
              labels: {'result': 'retry-error'});
          return _scheduleRegisterRetry();
        }
      }
    }
    _registerRetries = 0;
    _handleRegisterFinal(fin);
  }

  void _handleRegisterFinal(SipResponse fin) {
    final code = fin.statusCode;
    if (code >= 200 && code < 300) {
      final expiresHdr = fin.firstHeader('expires')?.value();
      final expires =
          int.tryParse(expiresHdr ?? '') ?? config.registrar!.expiresSeconds;
      final refresh =
          Duration(seconds: (expires * 0.75).round().clamp(1, 1 << 30));
      _registerRefresh?.cancel();
      _registerRefresh = Timer(refresh, () => _sendRegister());
      metrics.inc('rainbow_stub_sip_register_total', labels: {'result': 'ok'});
      _log.info(
          'REGISTER ok expires=${expires}s refresh_in=${refresh.inSeconds}s');
    } else {
      metrics.inc('rainbow_stub_sip_register_total',
          labels: {'result': 'fail-$code'});
      _log.warning('REGISTER failed status=$code');
      _scheduleRegisterRetry();
    }
  }

  void _scheduleRegisterRetry() {
    _registerRefresh?.cancel();
    _registerRefresh =
        Timer(const Duration(seconds: 30), () => _sendRegister());
  }

  // ---- Post-answer trickle → in-dialog re-INVITE ---------------------------
  Future<void> _reofferAfterTrickle(
      _OutboundCall call, XmlElement jingle) async {
    _mergeTransportInfoCandidates(call, jingle);
    final pending = call.pendingJingleSession;
    if (pending == null) return;
    final handle = call.handle;
    final dialog = handle?.dialog;
    if (dialog == null) {
      _log.fine('trickle re-INVITE skipped — no dialog sid=${call.sid}');
      return;
    }
    // No re-anchor: rtpengine's contract is idempotent on same fromTag,
    // so re-offering here would just echo the cached SDP. Sending the
    // merged Jingle-derived SDP lets the peer see the fresh candidates
    // directly; a real rtpengine picks up the ICE changes from the
    // peer's subsequent answer.
    final body = Uint8List.fromList(utf8.encode(jingleSessionToSdp(pending)));
    call.currentOfferSdp = utf8.decode(body, allowMalformed: true);
    try {
      final via = _newVia();
      final bytes = dialog.buildRequest(
        method: 'INVITE',
        via: via,
        contact: NameAddr.parse('<${config.localContactUri}>'),
        body: body,
        contentType: 'application/sdp',
      );
      await _transport.send(bytes, _outboundEndpoint);
      metrics.inc(
        'rainbow_stub_sip_trickle_reinvites_total',
        labels: {'direction': 'outbound'},
      );
    } catch (e, st) {
      _log.warning('trickle re-INVITE send failed sid=${call.sid}', e, st);
    }
  }

  // ---- RFC 4028 session timers ---------------------------------------------

  List<MapEntry<String, String>> _sessionTimerRequestHeaders() {
    if (!config.sessionTimersEnabled) return const [];
    return [
      MapEntry(
        'Session-Expires',
        '${config.sessionTimerDuration.inSeconds};refresher=uac',
      ),
      MapEntry('Min-SE', '${config.sessionTimerMinSe.inSeconds}'),
      const MapEntry('Supported', 'timer'),
    ];
  }

  /// Whether the peer expects US to refresh (RFC 4028 §7). If the header
  /// omits `refresher=` we assume the UAC (us) refreshes per RFC 4028 §9.
  bool _peerExpectsUacRefresh(String? headerValue) {
    if (headerValue == null) return true;
    final lower = headerValue.toLowerCase();
    if (!lower.contains('refresher=')) return true;
    return lower.contains('refresher=uac');
  }

  Duration? _seDuration(String v) {
    final semi = v.indexOf(';');
    final head = (semi < 0 ? v : v.substring(0, semi)).trim();
    final n = int.tryParse(head);
    return n == null ? null : Duration(seconds: n);
  }

  void _scheduleOutboundSessionRefresh(_OutboundCall call) {
    call.sessionTimer?.cancel();
    final se = call.sessionExpires;
    if (se == null) return;
    if (!call.refresherIsUs) {
      // Peer is the refresher (RFC 4028 §10): arm the guard timer for
      // the full Session-Expires. A refresh INVITE/UPDATE from the peer
      // re-arms it; if none arrives the session is dead → tear down.
      call.sessionTimer = Timer(se, () => _expireOutboundSession(call));
      return;
    }
    final half = se ~/ 2;
    final refresh =
        half.inSeconds < 30 ? half : half - const Duration(seconds: 15);
    call.sessionTimer = Timer(refresh, () => _sendSessionRefresh(call));
  }

  Future<void> _expireOutboundSession(_OutboundCall call) async {
    if (call.endedAt != null) return;
    _log.info('session-timer expired (peer refresher missed) sid=${call.sid}');
    call.endedAt = DateTime.now().toUtc();
    final handle = call.handle;
    final dialog = handle?.dialog;
    if (dialog != null) {
      try {
        final via = _newVia();
        final bytes = dialog.buildRequest(method: 'BYE', via: via);
        await _transport.send(bytes, _outboundEndpoint);
      } catch (e, st) {
        _log.warning('session-expiry BYE send failed sid=${call.sid}', e, st);
      }
    }
    final anchor = _mediaAnchor;
    if (anchor != null) {
      try {
        await anchor.tearDown(call.sid);
      } catch (_) {}
    }
    _forgetCall(call.sid);
    _sendJingleTerminate(call: call, reason: 'timeout');
    _writeCallLogSuccess(call);
    metrics.inc('rainbow_stub_sip_session_expired_total',
        labels: {'direction': 'outbound'});
  }

  Future<void> _sendSessionRefresh(_OutboundCall call) async {
    final handle = call.handle;
    final dialog = handle?.dialog;
    if (dialog == null) return;
    if (call.endedAt != null) return;
    try {
      final via = _newVia();
      final bodyStr = call.currentOfferSdp ?? '';
      final body = utf8.encode(bodyStr);
      final bytes = dialog.buildRequest(
        method: 'INVITE',
        via: via,
        contact: NameAddr.parse('<${config.localContactUri}>'),
        body: body,
        contentType: bodyStr.isEmpty ? null : 'application/sdp',
      );
      await _transport.send(bytes, _outboundEndpoint);
      metrics.inc('rainbow_stub_sip_session_refresh_total',
          labels: {'direction': 'outbound'});
      _scheduleOutboundSessionRefresh(call);
    } catch (e, st) {
      _log.warning('session refresh send failed sid=${call.sid}', e, st);
    }
  }

  UasReply _handleOutboundMidDialogRefresh(
    _OutboundCall call,
    SipRequest req,
  ) {
    final seHeader = req.firstHeader('session-expires')?.value();
    final se = seHeader == null ? null : _seDuration(seHeader);
    if (se != null && se < config.sessionTimerMinSe) {
      return _sessionIntervalTooSmall();
    }
    if (se != null) {
      call.sessionExpires = se;
      call.refresherIsUs = _peerExpectsUacRefresh(seHeader);
      _scheduleOutboundSessionRefresh(call);
    }
    metrics.inc('rainbow_stub_sip_session_refresh_total',
        labels: {'direction': 'inbound'});
    final body = call.currentOfferSdp ?? '';
    if (body.isEmpty) {
      return UasReply.status(200, 'OK');
    }
    return UasReply.ok(
      body: Uint8List.fromList(utf8.encode(body)),
      contentType: 'application/sdp',
    );
  }

  UasReply _handleInboundMidDialogRefresh(
    _InboundCall call,
    SipRequest req,
  ) {
    final se = _parseSessionExpiresRequest(req);
    if (se != null && se < config.sessionTimerMinSe) {
      return _sessionIntervalTooSmall();
    }
    if (se != null) {
      call.sessionExpires = se;
      call.sessionTimer?.cancel();
      // Peer refreshed → re-arm the guard for the next interval.
      call.sessionTimer = Timer(se, () => _expireInboundSession(call));
    }
    metrics.inc('rainbow_stub_sip_session_refresh_total',
        labels: {'direction': 'inbound'});
    return UasReply.status(200, 'OK');
  }

  /// RFC 4028 §6: reject a refresh whose Session-Expires is below our
  /// configured Min-SE, advertising the floor so the peer can re-offer.
  UasReply _sessionIntervalTooSmall() {
    metrics.inc('rainbow_stub_sip_session_422_total');
    return UasReply.status(
      422,
      'Session Interval Too Small',
      extraHeaders: [
        MapEntry('Min-SE', '${config.sessionTimerMinSe.inSeconds}'),
      ],
    );
  }

  Future<void> _expireInboundSession(_InboundCall call) async {
    if (call.endedAt != null) return;
    _log.info('inbound session-timer expired sid=${call.sid}');
    call.endedAt = DateTime.now().toUtc();
    final dialog = _dialogStore.get(call.ctx.dialog.id) ?? call.ctx.dialog;
    try {
      final via = _newVia();
      final bytes = dialog.buildRequest(method: 'BYE', via: via);
      await _transport.send(bytes, call.peerEndpoint);
    } catch (e, st) {
      _log.warning('inbound session-expiry BYE failed sid=${call.sid}', e, st);
    }
    final anchor = _mediaAnchor;
    if (anchor != null) {
      try {
        await anchor.tearDown(call.callId);
      } catch (_) {}
    }
    _sendJingleTerminateInbound(call, reason: 'timeout');
    _forgetInbound(call);
    _writeInboundCallLog(call, state: 'answered', overwrite: true);
    metrics.inc('rainbow_stub_sip_session_expired_total',
        labels: {'direction': 'inbound'});
  }

  Duration? _parseSessionExpiresRequest(SipRequest req) {
    final h = req.firstHeader('session-expires');
    if (h == null) return null;
    final v = h.value();
    final semi = v.indexOf(';');
    final head = (semi < 0 ? v : v.substring(0, semi)).trim();
    final n = int.tryParse(head);
    return n == null ? null : Duration(seconds: n);
  }

  // ---- RFC 7616 digest auth retry ------------------------------------------

  /// Compute `Authorization` / `Proxy-Authorization` headers for every
  /// challenge (WWW-Authenticate + Proxy-Authenticate) present in
  /// [challenge]. Returns the list of extra headers to append, and the
  /// updated per-realm nonce counters for the caller to persist.
  ///
  /// Returns null when no credentials are configured or none of the
  /// challenges could be parsed.
  ({
    List<MapEntry<String, String>> headers,
    Map<String, int> ncByRealm,
  })? _computeDigestHeaders({
    required SipResponse challenge,
    required String method,
    required String requestUri,
    required Map<String, int> priorNc,
  }) {
    final username = config.authUsername;
    final password = config.authPassword;
    if (username == null || password == null) return null;
    final wwws = challenge.headersOf('www-authenticate').toList();
    final proxies = challenge.headersOf('proxy-authenticate').toList();
    if (wwws.isEmpty && proxies.isEmpty) return null;

    final headers = <MapEntry<String, String>>[];
    final nc = Map<String, int>.from(priorNc);
    void addFrom(SipHeader h, String headerName) {
      final DigestChallenge parsed;
      try {
        parsed = parseDigestChallenge(h.value());
      } on FormatException catch (e) {
        _log.warning('digest challenge parse failed ($headerName): $e');
        return;
      }
      final key = '${parsed.realm}::${parsed.nonce}';
      final nextNc = (nc[key] ?? 0) + 1;
      nc[key] = nextNc;
      final auth = buildAuthorizationHeader(
        challenge: parsed,
        username: username,
        password: password,
        method: method,
        uri: requestUri,
        nc: nextNc,
        random: _rng,
      );
      headers.add(MapEntry(headerName, auth));
    }

    for (final h in wwws) {
      addFrom(h, 'Authorization');
    }
    for (final h in proxies) {
      addFrom(h, 'Proxy-Authorization');
    }
    if (headers.isEmpty) return null;
    return (headers: headers, ncByRealm: nc);
  }

  /// Returns a rebuilt [OutboundRequest] with `Authorization` /
  /// `Proxy-Authorization` filled in, ready to be re-sent via
  /// `_uac.invite`. Returns null if no credentials are configured,
  /// the challenge is unparseable, or retries are exhausted.
  OutboundRequest? _rebuildInviteWithDigest(
    _OutboundCall call,
    SipResponse challenge,
    OutboundRequest original,
  ) {
    if (call.authRetries >= 3) return null;
    final computed = _computeDigestHeaders(
      challenge: challenge,
      method: 'INVITE',
      requestUri: original.requestUri.toString(),
      priorNc: call.authNc,
    );
    if (computed == null) return null;
    call.authRetries++;
    call.authNc
      ..clear()
      ..addAll(computed.ncByRealm);
    metrics.inc('rainbow_stub_sip_auth_challenges_total',
        labels: {'code': '${challenge.statusCode}'});
    return OutboundRequest(
      method: original.method,
      requestUri: original.requestUri,
      from: original.from,
      to: original.to,
      callId: original.callId,
      cseq: original.cseq + 1,
      contact: original.contact,
      body: original.body,
      contentType: original.contentType,
      maxForwards: original.maxForwards,
      extraHeaders: [
        // Drop any prior stale Authorization from a preceding retry so
        // fresh headers replace them cleanly.
        ...original.extraHeaders.where((e) =>
            !e.key.toLowerCase().startsWith('authorization') &&
            !e.key.toLowerCase().startsWith('proxy-authorization')),
        ...computed.headers,
      ],
    );
  }

  void _sendJingleRinging(_OutboundCall call) {
    final id = _newIqId('ring', call.sid);
    final stanza = '<iq xmlns="jabber:client" type="set" id="${_esc(id)}" '
        'from="${_esc(call.calleeJid.toString())}" '
        'to="${_esc(call.callerJid.toString())}">'
        '<jingle xmlns="urn:xmpp:jingle:1" action="session-info" '
        'initiator="${_esc(call.callerJid.toString())}" '
        'sid="${_esc(call.sid)}">'
        '<ringing xmlns="urn:xmpp:jingle:apps:rtp:info:1"/>'
        '</jingle></iq>';
    router.fanOut(call.callerJid.local, stanza);
  }

  void _sendJingleAccept({
    required _OutboundCall call,
    required JingleSession jingleSession,
  }) {
    final jingleEl = jingleSessionToXml(
      jingleSession,
      action: 'session-accept',
      sid: call.sid,
      initiator: call.callerJid.toString(),
      responder: call.calleeJid.toString(),
    );
    final id = _newIqId('acc', call.sid);
    final stanza = '<iq xmlns="jabber:client" type="set" id="${_esc(id)}" '
        'from="${_esc(call.calleeJid.toString())}" '
        'to="${_esc(call.callerJid.toString())}">'
        '${jingleEl.toXmlString()}</iq>';
    router.fanOut(call.callerJid.local, stanza);
  }

  void _sendJingleTerminate({
    required _OutboundCall call,
    required String reason,
  }) {
    final id = _newIqId('trm', call.sid);
    final stanza = '<iq xmlns="jabber:client" type="set" id="${_esc(id)}" '
        'from="${_esc(call.calleeJid.toString())}" '
        'to="${_esc(call.callerJid.toString())}">'
        '<jingle xmlns="urn:xmpp:jingle:1" action="session-terminate" '
        'sid="${_esc(call.sid)}">'
        '<reason><${_esc(reason)}/></reason>'
        '</jingle></iq>';
    router.fanOut(call.callerJid.local, stanza);
  }

  void _writeCallLogSuccess(_OutboundCall call) {
    final answered = call.answeredAt;
    final owner = call.callerJid.local;
    if (owner.isEmpty) return;
    final durationMs = answered == null
        ? 0
        : (call.endedAt ?? DateTime.now().toUtc())
            .difference(answered)
            .inMilliseconds
            .abs();
    callLog.insert(
      ownerId: owner,
      peerJid: call.calleeJid.toString(),
      direction: 'outgoing',
      state: answered == null ? 'canceled' : 'answered',
      durationMs: durationMs,
      startedAt: call.startedAt,
    );
  }

  void _writeCallLogFailure(_OutboundCall call) {
    final owner = call.callerJid.local;
    if (owner.isEmpty) return;
    callLog.insert(
      ownerId: owner,
      peerJid: call.calleeJid.toString(),
      direction: 'outgoing',
      state: 'failed',
      durationMs: 0,
      startedAt: call.startedAt,
    );
  }

  ViaHeader _newVia() {
    final local = _transport.localEndpoint;
    return ViaHeader(
      protocolName: 'SIP',
      protocolVersion: '2.0',
      transport: local.protocol.token,
      host: local.address.address,
      port: local.port,
      params: SipParams.parse(';branch=z9hG4bK${_newTag()}'),
    );
  }

  String _newIqId(String kind, String sid) =>
      'sipgw-$kind-$sid-${_rng.nextInt(1 << 20).toRadixString(16)}';

  String _newTag() {
    final buf = StringBuffer();
    for (var i = 0; i < 6; i++) {
      buf.write(_rng.nextInt(256).toRadixString(16).padLeft(2, '0'));
    }
    return buf.toString();
  }

  String _mapReason(int code) {
    if (code == 486 || code == 600) return 'busy';
    if (code == 487) return 'cancel';
    if (code == 603) return 'decline';
    if (code >= 400 && code < 500) return 'general-error';
    if (code >= 500 && code < 600) return 'connectivity-error';
    return 'general-error';
  }

  // ---- XMPP session-info payloads (M4): DTMF + hold + unhold ---------------

  Future<void> _handleOutboundSessionInfo(
    _OutboundCall call,
    XmlElement jingle,
  ) async {
    for (final child in jingle.children.whereType<XmlElement>()) {
      final local = child.name.local;
      final ns = child.name.namespaceUri;
      if (local == 'dtmf' && ns == _dtmfNs) {
        final digit = child.getAttribute('digit');
        if (digit == null || digit.isEmpty) continue;
        final durationMs = int.tryParse(child.getAttribute('duration') ?? '');
        await _injectDtmf(
          callId: call.sid,
          tag: call.fromTag,
          digit: digit,
          durationMs: durationMs,
          direction: 'outbound',
        );
      } else if (local == 'hold' && ns == _rtpInfoNs) {
        await _reofferOutbound(call, hold: true);
      } else if (local == 'unhold' && ns == _rtpInfoNs) {
        await _reofferOutbound(call, hold: false);
      } else {
        _log.fine('outbound session-info $local (ns=$ns) sid=${call.sid} '
            '— ignored');
      }
    }
  }

  Future<void> _handleInboundSessionInfoPostAnswer(
    _InboundCall call,
    XmlElement jingle,
  ) async {
    for (final child in jingle.children.whereType<XmlElement>()) {
      final local = child.name.local;
      final ns = child.name.namespaceUri;
      if (local == 'dtmf' && ns == _dtmfNs) {
        final digit = child.getAttribute('digit');
        if (digit == null || digit.isEmpty) continue;
        final durationMs = int.tryParse(child.getAttribute('duration') ?? '');
        await _injectDtmf(
          callId: call.callId,
          tag: call.ctx.dialog.localTag,
          digit: digit,
          durationMs: durationMs,
          direction: 'inbound',
        );
      } else {
        _log.fine('inbound session-info $local (ns=$ns) sid=${call.sid} '
            '— ignored');
      }
    }
  }

  Future<void> _injectDtmf({
    required String callId,
    required String tag,
    required String digit,
    int? durationMs,
    required String direction,
  }) async {
    final client = _rtpengineClient;
    if (client == null) {
      _log.fine('DTMF ignored — no rtpengine wired '
          '(callId=$callId digit=$digit direction=$direction)');
      return;
    }
    try {
      await client.injectDtmf(
        callId,
        DtmfRequest(
          tag: tag,
          event: digit,
          durationMs: durationMs ?? 200,
        ),
      );
      metrics.inc(
        'rainbow_stub_sip_dtmf_out_total',
        labels: {'direction': direction},
      );
    } catch (e, st) {
      _log.warning('DTMF inject failed callId=$callId digit=$digit', e, st);
    }
  }

  Future<void> _reofferOutbound(
    _OutboundCall call, {
    required bool hold,
  }) async {
    final handle = call.handle;
    if (handle == null || call.answeredAt == null) {
      _log.fine('hold ignored — call not answered sid=${call.sid}');
      return;
    }
    final dialog = handle.dialog;
    if (dialog == null) {
      _log.fine('hold ignored — no dialog sid=${call.sid}');
      return;
    }
    final currentSdp = call.currentOfferSdp;
    if (currentSdp == null) return;
    if (hold && call.onHold) return;
    if (!hold && !call.onHold) return;

    final modified = _rewriteSdpDirection(currentSdp, hold: hold);
    final body = Uint8List.fromList(utf8.encode(modified));
    call.currentOfferSdp = modified;
    call.onHold = hold;

    // rtpengine's block/unblock is the semantic operation for hold; the
    // re-INVITE below is the SIP-side signal so the peer stops sending
    // media too. Skipping anchorOffer here also avoids the rtpengine
    // "same fromTag = idempotent, return cached SDP" caching contract.
    final client = _rtpengineClient;
    if (client != null) {
      try {
        if (hold) {
          await client.blockMedia(callId: call.sid, tag: call.fromTag);
        } else {
          await client.unblockMedia(callId: call.sid, tag: call.fromTag);
        }
      } catch (e, st) {
        _log.warning('rtpengine block/unblock failed sid=${call.sid}', e, st);
      }
    }

    try {
      final via = _newVia();
      final bytes = dialog.buildRequest(
        method: 'INVITE',
        via: via,
        contact: NameAddr.parse('<${config.localContactUri}>'),
        body: body,
        contentType: 'application/sdp',
      );
      await _transport.send(bytes, _outboundEndpoint);
      metrics.inc(
        'rainbow_stub_sip_holds_total',
        labels: {'action': hold ? 'hold' : 'unhold'},
      );
    } catch (e, st) {
      _log.warning('re-INVITE send failed sid=${call.sid}', e, st);
    }
  }

  /// Swap the media direction attribute in every m-section to reflect
  /// [hold]. Handles the common `a=sendrecv` ↔ `a=sendonly` case; if
  /// the SDP has no direction attribute, appends one to each m-section.
  String _rewriteSdpDirection(String sdp, {required bool hold}) {
    final target = hold ? 'sendonly' : 'sendrecv';
    // Replace any existing direction attribute in-place.
    final directions = ['sendrecv', 'sendonly', 'recvonly', 'inactive'];
    var out = sdp;
    var replaced = false;
    for (final d in directions) {
      if (d == target) continue;
      final re = RegExp('a=$d\\r?\\n', multiLine: true);
      if (re.hasMatch(out)) {
        out = out.replaceAll(re, 'a=$target\r\n');
        replaced = true;
      }
    }
    if (replaced) return out;
    // No direction attribute — append one to each m-section, right after
    // the m= line block.
    final lines = out.split(RegExp(r'\r?\n'));
    final buf = StringBuffer();
    var inserted = false;
    for (var i = 0; i < lines.length; i++) {
      final l = lines[i];
      buf.write(l);
      buf.write('\r\n');
      if (l.startsWith('m=') && !inserted) {
        buf.write('a=$target\r\n');
        inserted = true;
      }
    }
    return buf.toString();
  }

  // ---- SIP → XMPP: inbound INVITE (M3) -------------------------------------

  Future<UasReply> _onInboundInvite(
    InboundSipMessage inbound,
    UasInviteContext ctx,
  ) async {
    final invite = inbound.message as SipRequest;
    final NameAddr fromAddr;
    final NameAddr toAddr;
    try {
      fromAddr = invite.parseFrom();
      toAddr = invite.parseTo();
    } catch (_) {
      return UasReply.status(400, 'Bad Request');
    }

    // Route by DID (To-URI user part) → Rainbow user id.
    final didUser = SipJid.normalizeLocal(toAddr.uri.user ?? '');
    final userId = config.dids[didUser];
    if (userId == null || users.findById(userId) == null) {
      _log.info('inbound INVITE for unknown DID user="$didUser"');
      return UasReply.status(404, 'Not Found');
    }

    final peerLocal = SipJid.normalizeLocal(fromAddr.uri.user ?? '');
    if (peerLocal.isEmpty) return UasReply.status(400, 'Bad Request');
    final peerJid = Jid(local: peerLocal, domain: sipDomain);
    final calleeJid = Jid(local: userId, domain: xmppDomain);

    // Anchor the peer's offer through rtpengine (or pass through).
    final rawOffer = invite.bodyBytes();
    if (rawOffer.isEmpty) return UasReply.status(400, 'Missing SDP');
    final peerFromTag = fromAddr.tag ?? '';
    Uint8List anchoredOffer;
    final anchor = _mediaAnchor;
    if (anchor != null) {
      try {
        anchoredOffer = await anchor.anchorOffer(
          callId: invite.callId ?? _newSid(),
          fromTag: peerFromTag,
          sdp: rawOffer,
        );
      } catch (e, st) {
        _log.warning('rtpengine offer failed', e, st);
        return UasReply.status(500, 'Media Anchor Error');
      }
    } else {
      anchoredOffer = rawOffer;
    }

    // Translate the anchored offer into Jingle for the XMPP client.
    final JingleSession offerSession;
    try {
      final sdpStr = utf8.decode(anchoredOffer, allowMalformed: true);
      offerSession = jingleSessionFromSdp(sdpStr);
    } catch (e, st) {
      _log.warning('SDP → Jingle parse failed', e, st);
      return UasReply.status(500, 'SDP Parse Error');
    }

    final sid = _newSid();
    final callId = invite.callId ?? sid;
    final call = _InboundCall(
      sid: sid,
      callId: callId,
      calleeJid: calleeJid,
      peerJid: peerJid,
      peerFromTag: peerFromTag,
      peerEndpoint: inbound.source,
      offerSession: offerSession,
      ctx: ctx,
      completer: Completer<UasReply>(),
      startedAt: DateTime.now().toUtc(),
    );
    _inboundCallsBySid[sid] = call;
    _inboundCallsByCallId[callId] = call;
    _updateActiveGauge();

    // Fan the session-initiate out to every session of the recipient.
    final initiateStanza = _buildIncomingSessionInitiate(call);
    final delivered = router.fanOut(userId, initiateStanza);
    if (delivered == 0) {
      _log.info(
        'no active sessions for user=$userId — inbound SIP call missed '
        '(would-push from=$peerJid sid=$sid)',
      );
      _forgetInbound(call);
      _writeInboundCallLog(call, state: 'missed');
      metrics.inc(
        'rainbow_stub_sip_calls_total',
        labels: {'outcome': 'missed'},
      );
      return UasReply.status(480, 'Temporarily Unavailable');
    }

    // Auto-ring: 180 Ringing goes out as soon as the propose was
    // delivered. Some clients still send session-info <ringing/> back;
    // handled in _handleInboundJingle.
    try {
      await ctx.sendProvisional(UasReply.ringing());
      call.ringingSent = true;
    } catch (e, st) {
      _log.warning('sendProvisional(180) failed', e, st);
    }

    final timer = Timer(config.inboundRingTimeout, () {
      if (!call.completer.isCompleted) {
        _log.info('inbound call sid=$sid ring timeout');
        call.completer.complete(UasReply.status(408, 'Request Timeout'));
      }
    });

    final reply = await call.completer.future;
    timer.cancel();

    // Post-answer bookkeeping (call-log + metrics) happens INSIDE the
    // client-driven session-accept path so state is recorded before the
    // FSM ships the 2xx. For non-answered outcomes, log here.
    if (call.answeredAt == null) {
      if (reply is UasStatusReply && reply.isSuccess) {
        // Unexpected — shouldn't happen without a session-accept.
      } else {
        final code = reply is UasStatusReply ? reply.code : 500;
        _forgetInbound(call);
        _writeInboundCallLog(call,
            state: code == 486 || code == 487 ? 'declined' : 'canceled');
        metrics.inc(
          'rainbow_stub_sip_calls_total',
          labels: {
            'outcome': code == 486 || code == 487 ? 'declined' : 'canceled',
          },
        );
      }
    }
    return reply;
  }

  Future<UasReply> _onInDialogRequest(
    Dialog dialog,
    InboundSipMessage inbound,
  ) async {
    final req = inbound.message as SipRequest;
    final method = req.method.toUpperCase();
    final inboundCall = _inboundCallsByCallId[dialog.callId];
    if (inboundCall != null) {
      switch (method) {
        case 'BYE':
          _sendJingleTerminateInbound(inboundCall, reason: 'success');
          inboundCall.endedAt = DateTime.now().toUtc();
          inboundCall.sessionTimer?.cancel();
          _forgetInbound(inboundCall);
          _writeInboundCallLog(inboundCall, state: 'answered');
          return UasReply.status(200, 'OK');
        case 'ACK':
          return const UasReply.none();
        case 'INVITE':
        case 'UPDATE':
          return _handleInboundMidDialogRefresh(inboundCall, req);
        default:
          return UasReply.status(405, 'Method Not Allowed');
      }
    }

    final outboundCall = _callsBySid[dialog.callId];
    if (outboundCall != null) {
      switch (method) {
        case 'BYE':
          outboundCall.endedAt = DateTime.now().toUtc();
          outboundCall.sessionTimer?.cancel();
          _forgetCall(outboundCall.sid);
          _sendJingleTerminate(call: outboundCall, reason: 'success');
          _writeCallLogSuccess(outboundCall);
          final anchor = _mediaAnchor;
          if (anchor != null) {
            try {
              await anchor.tearDown(outboundCall.sid);
            } catch (_) {}
          }
          metrics.inc(
            'rainbow_stub_sip_calls_total',
            labels: {'outcome': 'answered'},
          );
          return UasReply.status(200, 'OK');
        case 'ACK':
          return const UasReply.none();
        case 'INVITE':
        case 'UPDATE':
          return _handleOutboundMidDialogRefresh(outboundCall, req);
        default:
          return UasReply.status(405, 'Method Not Allowed');
      }
    }

    return UasReply.status(481, 'Call/Transaction Does Not Exist');
  }

  Future<void> _handleInboundJingle({
    required _InboundCall call,
    required String action,
    required Jid callerJid,
    required XmlElement jingle,
  }) async {
    switch (action) {
      case 'session-accept':
        if (call.acceptingResource != null) {
          _sendJingleTerminateTo(
            call: call,
            target: callerJid,
            reason: 'cancel',
          );
          return;
        }
        call.acceptingResource = callerJid;
        call.answeredAt = DateTime.now().toUtc();

        // Anchor the client's answer through rtpengine.
        final answerSession = jingleSessionFromXml(jingle);
        final rawAnswer = jingleSessionToSdp(answerSession);
        Uint8List anchoredAnswer;
        final anchor = _mediaAnchor;
        if (anchor != null) {
          try {
            anchoredAnswer = await anchor.anchorAnswer(
              callId: call.callId,
              fromTag: call.peerFromTag,
              toTag: call.ctx.dialog.localTag,
              sdp: Uint8List.fromList(utf8.encode(rawAnswer)),
            );
          } catch (e, st) {
            _log.warning('rtpengine answer failed sid=${call.sid}', e, st);
            call.completer.complete(
              UasReply.status(500, 'Media Anchor Error'),
            );
            return;
          }
        } else {
          anchoredAnswer = Uint8List.fromList(utf8.encode(rawAnswer));
        }

        _retractOtherInboundSessions(call, winner: callerJid);
        _writeInboundCallLog(call, state: 'answered');
        metrics.inc(
          'rainbow_stub_sip_calls_total',
          labels: {'outcome': 'answered'},
        );

        call.completer.complete(
          UasReply.ok(body: anchoredAnswer, contentType: 'application/sdp'),
        );

      case 'session-terminate':
        if (call.answeredAt == null) {
          if (!call.completer.isCompleted) {
            call.completer.complete(UasReply.status(486, 'Busy Here'));
          }
          return;
        }
        // In-dialog BYE toward peer.
        final dialog = _dialogStore.get(call.ctx.dialog.id) ?? call.ctx.dialog;
        try {
          final via = _newVia();
          final bytes = dialog.buildRequest(method: 'BYE', via: via);
          await _transport.send(bytes, call.peerEndpoint);
        } catch (e, st) {
          _log.warning('inbound BYE send failed sid=${call.sid}', e, st);
        }
        final anchor = _mediaAnchor;
        if (anchor != null) {
          try {
            await anchor.tearDown(call.callId);
          } catch (_) {}
        }
        call.endedAt = DateTime.now().toUtc();
        _forgetInbound(call);
        _writeInboundCallLog(call, state: 'answered', overwrite: true);

      case 'session-info':
        final ringing = jingle.getElement('ringing', namespace: _rtpInfoNs);
        if (ringing != null && !call.ringingSent) {
          call.ringingSent = true;
          try {
            await call.ctx.sendProvisional(UasReply.ringing());
          } catch (_) {}
          return;
        }
        // Post-answer session-info payloads (DTMF, hold) go here.
        if (call.answeredAt != null) {
          await _handleInboundSessionInfoPostAnswer(call, jingle);
        }

      default:
        _log.fine('inbound Jingle: ignoring action=$action sid=${call.sid}');
    }
  }

  void _retractOtherInboundSessions(
    _InboundCall call, {
    required Jid winner,
  }) {
    // Every other session of the same user gets a Jingle
    // session-terminate reason=cancel so they drop the incoming-call UI.
    final userId = call.calleeJid.local;
    for (final s in router.sessionsOf(userId)) {
      if (s.jid == winner) continue;
      final id = _newIqId('rct', call.sid);
      final stanza = '<iq xmlns="jabber:client" type="set" id="${_esc(id)}" '
          'from="${_esc(call.peerJid.toString())}" '
          'to="${_esc(s.jid.toString())}">'
          '<jingle xmlns="urn:xmpp:jingle:1" action="session-terminate" '
          'sid="${_esc(call.sid)}">'
          '<reason><cancel/></reason></jingle></iq>';
      s.send(stanza);
    }
  }

  void _sendJingleTerminateTo({
    required _InboundCall call,
    required Jid target,
    required String reason,
  }) {
    final id = _newIqId('trm', call.sid);
    final stanza = '<iq xmlns="jabber:client" type="set" id="${_esc(id)}" '
        'from="${_esc(call.peerJid.toString())}" '
        'to="${_esc(target.toString())}">'
        '<jingle xmlns="urn:xmpp:jingle:1" action="session-terminate" '
        'sid="${_esc(call.sid)}">'
        '<reason><${_esc(reason)}/></reason></jingle></iq>';
    for (final s in router.sessionsOf(target.local)) {
      if (target.resource != null && s.jid.resource != target.resource) {
        continue;
      }
      s.send(stanza);
    }
  }

  void _sendJingleTerminateInbound(_InboundCall call,
      {required String reason}) {
    final target = call.acceptingResource ?? call.calleeJid;
    _sendJingleTerminateTo(call: call, target: target, reason: reason);
  }

  String _buildIncomingSessionInitiate(_InboundCall call) {
    final jingleEl = jingleSessionToXml(
      call.offerSession,
      action: 'session-initiate',
      sid: call.sid,
      initiator: call.peerJid.toString(),
      responder: call.calleeJid.toString(),
    );
    final id = _newIqId('sin', call.sid);
    return '<iq xmlns="jabber:client" type="set" id="${_esc(id)}" '
        'from="${_esc(call.peerJid.toString())}" '
        'to="${_esc(call.calleeJid.toString())}">'
        '${jingleEl.toXmlString()}</iq>';
  }

  void _writeInboundCallLog(
    _InboundCall call, {
    required String state,
    bool overwrite = false,
  }) {
    if (call.callLogged && !overwrite) return;
    call.callLogged = true;
    final owner = call.calleeJid.local;
    if (owner.isEmpty) return;
    final answered = call.answeredAt;
    final durationMs = answered == null
        ? 0
        : (call.endedAt ?? DateTime.now().toUtc())
            .difference(answered)
            .inMilliseconds
            .abs();
    callLog.insert(
      ownerId: owner,
      peerJid: call.peerJid.toString(),
      direction: 'incoming',
      state: state,
      durationMs: durationMs,
      startedAt: call.startedAt,
    );
  }

  void _forgetInbound(_InboundCall call) {
    _inboundCallsBySid.remove(call.sid);
    _inboundCallsByCallId.remove(call.callId);
    _updateActiveGauge();
  }

  void _updateActiveGauge() {
    metrics.setGauge(
      'rainbow_stub_sip_calls_active',
      (_callsBySid.length + _inboundCallsBySid.length).toDouble(),
    );
  }

  String _newSid() =>
      'gwsid-${DateTime.now().microsecondsSinceEpoch.toRadixString(16)}-'
      '${_rng.nextInt(1 << 20).toRadixString(16)}';
}

class _OutboundCall {
  _OutboundCall({
    required this.sid,
    required this.callerJid,
    required this.calleeJid,
    required this.fromTag,
    required this.startedAt,
  });

  final String sid;
  final Jid callerJid;
  final Jid calleeJid;
  final String fromTag;
  final DateTime startedAt;
  UacInviteHandle? handle;
  String? toTag;
  DateTime? answeredAt;
  DateTime? endedAt;
  bool ringingSent = false;
  bool terminatedByClient = false;
  String? currentOfferSdp;
  bool onHold = false;

  /// Trickle-ICE buffering (RFC 8840): non-null between the initial
  /// `session-initiate` (with no candidates) and INVITE dispatch.
  JingleSession? pendingJingleSession;
  Timer? trickleTimer;
  bool dispatched = false;

  /// RFC 4028 session-timer refresh state.
  Timer? sessionTimer;
  Duration? sessionExpires;
  bool refresherIsUs = true;

  /// Digest-auth retry counter — capped at 3 to survive proxy + endpoint
  /// challenge chains without ever looping.
  int authRetries = 0;

  /// Per-`realm::nonce` nonce-count map so successive retries never
  /// replay a stale count against the same challenge (RFC 7616 §3.4.1).
  final Map<String, int> authNc = <String, int>{};
}

class _InboundCall {
  _InboundCall({
    required this.sid,
    required this.callId,
    required this.calleeJid,
    required this.peerJid,
    required this.peerFromTag,
    required this.peerEndpoint,
    required this.offerSession,
    required this.ctx,
    required this.completer,
    required this.startedAt,
  });

  final String sid;
  final String callId;
  final Jid calleeJid;
  final Jid peerJid;
  final String peerFromTag;
  final Endpoint peerEndpoint;
  final JingleSession offerSession;
  final UasInviteContext ctx;
  final Completer<UasReply> completer;
  final DateTime startedAt;
  Jid? acceptingResource;
  bool ringingSent = false;
  bool callLogged = false;
  DateTime? answeredAt;
  DateTime? endedAt;

  Timer? sessionTimer;
  Duration? sessionExpires;
}

String _esc(String s) => s
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;')
    .replaceAll('"', '&quot;')
    .replaceAll("'", '&apos;');
