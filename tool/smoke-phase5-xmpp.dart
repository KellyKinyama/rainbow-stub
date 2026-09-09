// ignore_for_file: file_names
// Smoke script for phase 5 XMPP hardening: ping, roster get, disco#info,
// initial presence probe (contact presences delivered to caller).
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
  log.info('=== xmpp hardening smoke ===');

  final aliceLogin = await _restLogin('alice@rainbow-stub.local', 'password');
  final token = aliceLogin['token'] as String;

  final alice = await _connect(
    email: 'alice@rainbow-stub.local',
    token: token,
    resource: 'phone',
  );
  log.info('bound as ${alice.jid}');

  // Ping
  final pong = alice.awaitId('p1');
  alice.send(
    '<iq type="get" id="p1" to="$_domain"><ping xmlns="urn:xmpp:ping"/></iq>',
  );
  final pongRes = await pong.timeout(const Duration(seconds: 3));
  log.info('ping → ${pongRes.getAttribute('type')}');

  // Disco#info
  final disco = alice.awaitId('d1');
  alice.send(
    '<iq type="get" id="d1" to="$_domain">'
    '<query xmlns="http://jabber.org/protocol/disco#info"/></iq>',
  );
  final discoRes = await disco.timeout(const Duration(seconds: 3));
  final feats = discoRes
      .findAllElements(
        'feature',
        namespace: 'http://jabber.org/protocol/disco#info',
      )
      .map((e) => e.getAttribute('var'))
      .whereType<String>()
      .toList();
  log.info('disco#info features (${feats.length}): ${feats.join(', ')}');

  // Roster get
  final roster = alice.awaitId('r1');
  alice.send('<iq type="get" id="r1"><query xmlns="jabber:iq:roster"/></iq>');
  final rosterRes = await roster.timeout(const Duration(seconds: 3));
  final items = rosterRes
      .findAllElements('item', namespace: 'jabber:iq:roster')
      .toList();
  log.info('roster items (${items.length}):');
  for (final i in items) {
    log.info(
      '  ${i.getAttribute('name')} <${i.getAttribute('jid')}> sub=${i.getAttribute('subscription')}',
    );
  }

  // Initial presence — should receive contacts' presences back.
  final peers = <XmlElement>[];
  late StreamSubscription sub;
  final done = Completer<void>();
  sub = alice.stream.listen((e) {
    if (e.localName != 'presence') return;
    final from = e.getAttribute('from') ?? '';
    if (from.contains('@$_domain') && !from.contains('/')) {
      peers.add(e);
      if (peers.length >= items.length) done.complete();
    }
  });
  alice.send('<presence/>');
  await done.future.timeout(const Duration(seconds: 3), onTimeout: () {});
  await sub.cancel();
  log.info(
    'received ${peers.length} peer presences after initial <presence/>:',
  );
  for (final p in peers) {
    final show =
        p.getElement('show')?.innerText ??
        (p.getAttribute('type') == 'unavailable' ? 'offline' : 'online');
    final status = p.getElement('status')?.innerText;
    log.info('  ${p.getAttribute('from')} show=$show status=${status ?? ''}');
  }

  await alice.close();
  log.info('=== smoke DONE ===');
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
    return jsonDecode(await resp.transform(utf8.decoder).join())
        as Map<String, dynamic>;
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

  Stream<XmlElement> get stream => _controller.stream;

  void send(String s) => _channel.sink.add(s);

  Future<XmlElement> awaitId(String id) =>
      stream.firstWhere((e) => e.getAttribute('id') == id);

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
