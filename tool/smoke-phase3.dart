// ignore_for_file: file_names
// Smoke test for phase 3 — connects two XMPP-over-WS sessions and sends a
// message from alice to bob. Requires the server to be running on :8443
// with the default seed (alice + bob + ...).
//
// Usage:  dart run tool/smoke-phase3.dart
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:rainbow_stub/rainbow_stub.dart';
import 'package:web_socket_channel/io.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:xml/xml.dart';

const _domain = 'localhost';
const _appAuth =
    'Basic NjVjNjgxYzAxYzhmMTFlOWFkZDg5MzJiMzU4ZWY4MWQ6VVlkdTN3Q1hUZGZ5akltaFVSbklrWjB0YWM1SjlYU0xzeklLQlJVVVdWQjM1YjZuVDNmV1YyQmhBR2hvamRCUQ==';

Future<void> main() async {
  final log = initLogging();
  log.info('=== phase 3 smoke ===');

  final aliceLogin = await _restLogin('alice@rainbow-stub.local', 'password');
  final bobLogin = await _restLogin('bob@rainbow-stub.local', 'password');
  final aliceId = (aliceLogin['loggedInUser'] as Map)['id'] as String;
  final bobId = (bobLogin['loggedInUser'] as Map)['id'] as String;
  log.info('REST login OK — aliceId=$aliceId bobId=$bobId');

  final alice = await _connect(
    email: 'alice@rainbow-stub.local',
    token: aliceLogin['token'] as String,
    resource: 'phone',
  );
  log.info('alice bound as ${alice.jid}');

  final bob = await _connect(
    email: 'bob@rainbow-stub.local',
    token: bobLogin['token'] as String,
    resource: 'web',
  );
  log.info('bob bound as ${bob.jid}');

  final delivered = bob.awaitLocal('message');
  final msg =
      '<message id="smoke1" to="$bobId@$_domain" type="chat">'
      '<body>hello from smoke</body>'
      '</message>';
  alice.send(msg);
  final got = await delivered.timeout(const Duration(seconds: 5));
  log.info(
    'bob received: from=${got.getAttribute('from')} '
    'body=${got.getElement('body')?.innerText}',
  );

  // Presence
  final presence = bob.awaitLocal('presence');
  alice.send('<presence><show>dnd</show><status>focused</status></presence>');
  final p = await presence.timeout(const Duration(seconds: 5));
  log.info(
    'bob saw presence: from=${p.getAttribute('from')} '
    'show=${p.getElement('show')?.innerText} '
    'status=${p.getElement('status')?.innerText}',
  );

  await alice.close();
  await bob.close();
  log.info('=== phase 3 smoke DONE ===');
  exit(0);
}

Future<Map<String, dynamic>> _restLogin(String email, String password) async {
  final client = HttpClient();
  try {
    final auth = 'Basic ${base64.encode(utf8.encode('$email:$password'))}';
    final req = await client.getUrl(
      Uri.parse('http://$_domain:8443/api/rainbow/authentication/v1.0/login'),
    );
    req.headers.set('authorization', auth);
    req.headers.set('x-rainbow-app-auth', _appAuth);
    final resp = await req.close();
    if (resp.statusCode != 200) {
      throw StateError('login $email → ${resp.statusCode}');
    }
    final body = await resp.transform(utf8.decoder).join();
    return jsonDecode(body) as Map<String, dynamic>;
  } finally {
    client.close(force: true);
  }
}

Future<_Xmpp> _connect({
  required String email,
  required String token,
  required String resource,
}) async {
  final channel = IOWebSocketChannel.connect(
    Uri.parse('ws://$_domain:8443/websocket'),
    protocols: ['xmpp'],
  );
  await channel.ready;
  final c = _Xmpp(channel);
  await c.openStream();
  await c.saslPlain(email: email, password: token);
  await c.openStream();
  await c.bind(resource);
  return c;
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

  void send(String s) => _channel.sink.add(s);

  Future<XmlElement> awaitLocal(String localName) =>
      _controller.stream.firstWhere((e) => e.localName == localName);

  Future<void> openStream() async {
    final ready = _controller.stream.firstWhere(
      (e) => e.localName == 'features' || e.localName == 'stream:features',
    );
    send(
      '<open xmlns="urn:ietf:params:xml:ns:xmpp-framing" to="$_domain" '
      'version="1.0"/>',
    );
    await ready.timeout(const Duration(seconds: 5));
  }

  Future<void> saslPlain({
    required String email,
    required String password,
  }) async {
    final ready = _controller.stream.firstWhere(
      (e) => e.localName == 'success' || e.localName == 'failure',
    );
    final payload = base64.encode(utf8.encode('\u0000$email\u0000$password'));
    send(
      '<auth xmlns="urn:ietf:params:xml:ns:xmpp-sasl" '
      'mechanism="PLAIN">$payload</auth>',
    );
    final r = await ready.timeout(const Duration(seconds: 5));
    if (r.localName != 'success') {
      throw StateError('SASL failed: ${r.toXmlString()}');
    }
  }

  Future<void> bind(String resource) async {
    final ready = _controller.stream.firstWhere(
      (e) => e.localName == 'iq' && e.getAttribute('type') == 'result',
    );
    send(
      '<iq type="set" id="bind1">'
      '<bind xmlns="urn:ietf:params:xml:ns:xmpp-bind">'
      '<resource>$resource</resource></bind></iq>',
    );
    final iq = await ready.timeout(const Duration(seconds: 5));
    jid = iq.findAllElements('jid').first.innerText;
  }

  Future<void> close() async {
    await _sub.cancel();
    if (!_controller.isClosed) await _controller.close();
    await _channel.sink.close();
  }
}
