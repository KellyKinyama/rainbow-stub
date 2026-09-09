import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:logging/logging.dart';
import 'package:rainbow_stub/rainbow_stub.dart';
import 'package:shelf/shelf_io.dart' as shelf_io;
import 'package:test/test.dart';
import 'package:web_socket_channel/io.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:xml/xml.dart';

const _domain = 'rainbow-stub.local';

void main() {
  late RainbowStubApp app;
  late HttpServer server;
  late String host;
  late int port;
  late String aliceId;
  late String bobId;
  late String aliceToken;

  setUpAll(() {
    Logger.root.level = Level.INFO;
    Logger.root.onRecord.listen((r) {
      final err = r.error != null ? ' err=${r.error}' : '';
      // ignore: avoid_print
      print('${r.level.name} ${r.loggerName} ${r.message}$err');
    });
  });

  setUp(() async {
    final tempDir = Directory.systemTemp.createTempSync('rainbow-stub-p7');
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
    );
    app = await RainbowStubApp.boot(config);
    final alice = app.users.create(
      loginEmail: 'alice@rainbow-stub.local',
      password: 'password',
      firstName: 'Alice',
      lastName: 'Sample',
    );
    final bob = app.users.create(
      loginEmail: 'bob@rainbow-stub.local',
      password: 'password',
      firstName: 'Bob',
      lastName: 'Marley',
    );
    aliceId = alice.id;
    bobId = bob.id;
    aliceToken = app.tokens
        .issue(
          userId: aliceId,
          ttl: const Duration(hours: 1),
          renewTtl: const Duration(hours: 2),
        )
        .token;
    server = await shelf_io.serve(app.buildHandler(), '127.0.0.1', 0);
    host = server.address.host;
    port = server.port;
  });

  tearDown(() async {
    await server.close(force: true);
    app.db.close();
  });

  Future<_Xmpp> connect({
    required String email,
    required String token,
    required String resource,
  }) async {
    final uri = Uri.parse('ws://$host:$port/websocket');
    final channel = IOWebSocketChannel.connect(uri, protocols: ['xmpp']);
    await channel.ready;
    final c = _Xmpp(channel);
    await c.openStream();
    await c.saslPlain(email: email, password: token);
    await c.openStream();
    await c.bind(resource);
    return c;
  }

  test('SASL: 3 bad-password attempts trigger stream close', () async {
    final channel = IOWebSocketChannel.connect(
      Uri.parse('ws://$host:$port/websocket'),
      protocols: ['xmpp'],
    );
    await channel.ready;
    final c = _Xmpp(channel);
    await c.openStream();

    var failures = 0;
    // Fire 3 bad SASL attempts.
    for (var i = 0; i < 3; i++) {
      final resp = c.awaitLocal('failure');
      final bogus = base64.encode(
        utf8.encode('\u0000alice@rainbow-stub.local\u0000wrong$i'),
      );
      c.send(
        '<auth xmlns="urn:ietf:params:xml:ns:xmpp-sasl" '
        'mechanism="PLAIN">$bogus</auth>',
      );
      await resp.timeout(const Duration(seconds: 3));
      failures++;
    }
    expect(failures, 3);

    // Server should close the channel — sink.done resolves when it does.
    await c._channel.sink.done.timeout(const Duration(seconds: 3));
    await c.close();
  });

  test(
    'MAM on bubble the caller is NOT a member of returns <forbidden/>',
    () async {
      // Bubble owned by bob, alice is NOT a member.
      final bubble = app.bubbles.create(ownerId: bobId, name: 'Bob only');
      app.bubbles.insertMessage(
        bubbleId: bubble.id,
        stanzaId: 's1',
        from: Jid.parse('$bobId@$_domain'),
        body: 'secret',
      );

      final alice = await connect(
        email: 'alice@rainbow-stub.local',
        token: aliceToken,
        resource: 'phone',
      );
      final resp = alice.awaitId('mam-forbid');
      alice.send(
        '<iq type="set" id="mam-forbid">'
        '<query xmlns="urn:xmpp:mam:2">'
        '<x xmlns="jabber:x:data" type="submit">'
        '<field var="with"><value>${bubble.id}@muc.$_domain</value></field>'
        '</x></query></iq>',
      );
      final iq = await resp.timeout(const Duration(seconds: 3));
      expect(iq.getAttribute('type'), 'error');
      expect(
        iq
            .getElement('error')
            ?.getElement(
              'forbidden',
              namespace: 'urn:ietf:params:xml:ns:xmpp-stanzas',
            ),
        isNotNull,
      );
      await alice.close();
    },
  );

  test('MAM RSM max is clamped to 200', () async {
    final aliceJid = Jid.parse('$aliceId@$_domain');
    final bobJid = Jid.parse('$bobId@$_domain');
    for (var i = 0; i < 3; i++) {
      app.messages.insert(
        from: aliceJid,
        to: bobJid,
        stanzaId: 'x$i',
        body: 'b$i',
      );
    }
    final alice = await connect(
      email: 'alice@rainbow-stub.local',
      token: aliceToken,
      resource: 'phone',
    );
    // Request max=999999 → server should clamp.
    var count = 0;
    final done = Completer<void>();
    late StreamSubscription sub;
    sub = alice.stream.listen((e) {
      if (e.localName == 'message' &&
          e.getElement('result', namespace: 'urn:xmpp:mam:2') != null) {
        count++;
      } else if (e.localName == 'iq' && e.getAttribute('id') == 'mm-cap') {
        done.complete();
      }
    });
    alice.send(
      '<iq type="set" id="mm-cap">'
      '<query xmlns="urn:xmpp:mam:2">'
      '<x xmlns="jabber:x:data" type="submit">'
      '<field var="with"><value>$bobId@$_domain</value></field>'
      '</x>'
      '<set xmlns="http://jabber.org/protocol/rsm"><max>999999</max></set>'
      '</query></iq>',
    );
    await done.future.timeout(const Duration(seconds: 3));
    await sub.cancel();
    expect(count, 3); // total items only 3, but server should not have failed
    await alice.close();
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
