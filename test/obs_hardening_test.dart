import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:logging/logging.dart';
import 'package:rainbow_stub/rainbow_stub.dart';
import 'package:shelf/shelf_io.dart' as shelf_io;
import 'package:test/test.dart';
import 'package:web_socket_channel/io.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:xml/xml.dart';

const _domain = 'rainbow-stub.local';

Future<RainbowStubApp> _bootApp({TlsConfig? tls}) async {
  final tempDir = Directory.systemTemp.createTempSync('rainbow-stub-hard2');
  final config = Config(
    host: '127.0.0.1',
    port: 0,
    publicHost: _domain,
    tlsCertPath: 'certs/rainbow-stub.crt',
    tlsKeyPath: 'certs/rainbow-stub.key',
    dbPath: '${tempDir.path}/t.db',
    fileStorePath: '${tempDir.path}/files',
    avatarStorePath: '${tempDir.path}/avatars',
    auth: AuthConfig(
      appId: 'x',
      appSecret: 'x',
      tokenTtl: const Duration(hours: 24),
      renewTtl: const Duration(hours: 48),
    ),
    asterisk: AsteriskConfig(
      ariUrl: 'http://localhost:8088/asterisk/ari',
      ariUser: 'asterisk',
      ariPassword: 'asterisk',
      wsSipUrl: 'wss://localhost:8089/asterisk/ws',
      sipDomain: 'rainbow-stub',
    ),
    tls: tls ?? const TlsConfig(),
  );
  return RainbowStubApp.boot(config);
}

Future<String> _get(String url, {Map<String, String>? headers}) async {
  final client = HttpClient();
  try {
    final r = await client.getUrl(Uri.parse(url));
    r.persistentConnection = false;
    headers?.forEach(r.headers.set);
    final resp = await r.close();
    return utf8.decode(
      await resp
          .fold<BytesBuilder>(BytesBuilder(), (b, chunk) => b..add(chunk))
          .then((b) => b.toBytes()),
    );
  } finally {
    client.close(force: true);
  }
}

Future<HttpClientResponse> _getResponse(
  String url, {
  Map<String, String>? headers,
}) async {
  final client = HttpClient();
  final r = await client.getUrl(Uri.parse(url));
  r.persistentConnection = false;
  headers?.forEach(r.headers.set);
  return r.close();
}

void main() {
  setUpAll(() {
    Logger.root.level = Level.INFO;
    Logger.root.onRecord.listen((_) {});
  });

  test(
    '/metrics exposes Prometheus text with the RN request counter',
    () async {
      final app = await _bootApp();
      final server = await shelf_io.serve(app.buildHandler(), '127.0.0.1', 0);
      try {
        // Hit /health twice to advance the counter.
        await _get('http://127.0.0.1:${server.port}/health');
        await _get('http://127.0.0.1:${server.port}/health');

        final body = await _get('http://127.0.0.1:${server.port}/metrics');
        expect(
          body,
          contains(
            '# HELP rainbow_stub_http_requests_total HTTP requests handled',
          ),
        );
        expect(
          body,
          contains('# TYPE rainbow_stub_http_requests_total counter'),
        );
        expect(body, contains('rainbow_stub_http_requests_total{'));
        expect(body, contains('rainbow_stub_build_info{version="0.1.0"} 1'));
        // Duration histogram + gauges present.
        expect(
          body,
          contains('rainbow_stub_http_request_duration_seconds_bucket{'),
        );
        expect(body, contains('rainbow_stub_xmpp_sessions '));
        expect(body, contains('rainbow_stub_xmpp_sm_parked '));
      } finally {
        await server.close(force: true);
        app.db.close();
      }
    },
  );

  test(
    'security headers: X-Content-Type-Options, X-Frame-Options, Referrer',
    () async {
      final app = await _bootApp();
      final server = await shelf_io.serve(app.buildHandler(), '127.0.0.1', 0);
      try {
        final resp = await _getResponse(
          'http://127.0.0.1:${server.port}/health',
        );
        expect(resp.headers.value('x-content-type-options'), 'nosniff');
        expect(resp.headers.value('x-frame-options'), 'DENY');
        expect(resp.headers.value('referrer-policy'), 'no-referrer');
        // HSTS should NOT be emitted on plain HTTP.
        expect(resp.headers.value('strict-transport-security'), isNull);
        await resp.drain<void>();
      } finally {
        await server.close(force: true);
        app.db.close();
      }
    },
  );

  test('JSON access log emits one NDJSON record per request', () async {
    // Rewire root logger to capture output.
    final captured = <String>[];
    final subscription = Logger.root.onRecord.listen((r) {
      // Simulate what initJsonLogging would write.
      captured.add(
        jsonEncode({
          'level': r.level.name,
          'logger': r.loggerName,
          'message': r.message,
          if (r.error is Map) ...(r.error as Map<String, Object?>),
        }),
      );
    });
    final app = await _bootApp();
    final server = await shelf_io.serve(app.buildHandler(), '127.0.0.1', 0);
    try {
      await _get('http://127.0.0.1:${server.port}/health');
      // Find at least one line that is valid JSON with the expected fields.
      final line = captured.firstWhere((l) {
        try {
          final j = jsonDecode(l) as Map<String, dynamic>;
          return j['logger'] == 'http' &&
              j['method'] == 'GET' &&
              j['path'] == '/health' &&
              j['status'] == 200;
        } catch (_) {
          return false;
        }
      }, orElse: () => '');
      expect(line, isNot(isEmpty), reason: 'expected structured http log');
      final decoded = jsonDecode(line) as Map<String, dynamic>;
      expect(decoded['duration_ms'], isA<int>());
    } finally {
      await server.close(force: true);
      app.db.close();
      await subscription.cancel();
    }
  });

  test('XMPP DOCTYPE frame is rejected without parsing', () async {
    final app = await _bootApp();
    final aliceId = app.users
        .create(
          loginEmail: 'alice@rainbow-stub.local',
          password: 'password',
          firstName: 'Alice',
          lastName: 'Sample',
        )
        .id;
    final token = app.tokens
        .issue(
          userId: aliceId,
          ttl: const Duration(hours: 1),
          renewTtl: const Duration(hours: 2),
        )
        .token;
    final server = await shelf_io.serve(app.buildHandler(), '127.0.0.1', 0);
    try {
      final ch = IOWebSocketChannel.connect(
        Uri.parse('ws://127.0.0.1:${server.port}/websocket'),
        protocols: ['xmpp'],
      );
      await ch.ready;

      final _Xmpp c = _Xmpp(ch);
      await c.openStream();
      await c.saslPlain(email: 'alice@rainbow-stub.local', password: token);
      await c.openStream();
      await c.bind('phone');

      // Attempt XXE-style frame.
      c.send(
        '<!DOCTYPE lol [<!ENTITY lol "lol">]><message><body>&lol;</body></message>',
      );

      // Server should close the WS shortly.
      await ch.sink.done.timeout(const Duration(seconds: 3));
      await c.close();
    } finally {
      await server.close(force: true);
      app.db.close();
    }
  });
}

class _Xmpp {
  _Xmpp(this._channel) {
    _sub = _channel.stream.listen((raw) {
      final text = raw is List<int> ? utf8.decode(raw) : raw as String;
      try {
        _controller.add(XmlDocument.parse(text).rootElement);
      } on XmlException {
        // ignore
      }
    }, onDone: () => _controller.isClosed ? null : _controller.close());
  }

  final WebSocketChannel _channel;
  late final StreamSubscription _sub;
  final _controller = StreamController<XmlElement>.broadcast();
  String jid = '';

  Stream<XmlElement> get stream => _controller.stream;

  void send(String s) => _channel.sink.add(s);

  Future<XmlElement> awaitLocal(String localName) =>
      stream.firstWhere((e) => e.localName == localName);

  Future<void> openStream() async {
    final ready = stream.firstWhere(
      (e) => e.localName == 'features' || e.localName == 'stream:features',
    );
    send(
      '<open xmlns="urn:ietf:params:xml:ns:xmpp-framing" to="$_domain" '
      'version="1.0"/>',
    );
    await ready.timeout(const Duration(seconds: 3));
  }

  Future<void> saslPlain({
    required String email,
    required String password,
  }) async {
    final ready = stream.firstWhere(
      (e) => e.localName == 'success' || e.localName == 'failure',
    );
    final payload = base64.encode(utf8.encode('\u0000$email\u0000$password'));
    send(
      '<auth xmlns="urn:ietf:params:xml:ns:xmpp-sasl" '
      'mechanism="PLAIN">$payload</auth>',
    );
    final r = await ready.timeout(const Duration(seconds: 3));
    if (r.localName != 'success') {
      throw StateError('SASL failed: ${r.toXmlString()}');
    }
  }

  Future<void> bind(String resource) async {
    final ready = stream.firstWhere(
      (e) => e.localName == 'iq' && e.getAttribute('type') == 'result',
    );
    send(
      '<iq type="set" id="bind1">'
      '<bind xmlns="urn:ietf:params:xml:ns:xmpp-bind">'
      '<resource>$resource</resource></bind></iq>',
    );
    final iq = await ready.timeout(const Duration(seconds: 3));
    jid = iq.findAllElements('jid').first.innerText;
  }

  Future<void> close() async {
    await _sub.cancel();
    if (!_controller.isClosed) await _controller.close();
    await _channel.sink.close();
  }
}
