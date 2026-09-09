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
  late String bobToken;

  setUpAll(() {
    Logger.root.level = Level.INFO;
    Logger.root.onRecord.listen((r) {
      final err = r.error != null ? ' err=${r.error}' : '';
      // ignore: avoid_print
      print('${r.level.name} ${r.loggerName} ${r.message}$err');
    });
  });

  setUp(() async {
    final tempDir = Directory.systemTemp.createTempSync('rainbow-stub-p5');
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
    app.roster.add(aliceId, bobId);
    app.presence.set(bobId, 'away', status: 'lunch');
    aliceToken = app.tokens
        .issue(
          userId: aliceId,
          ttl: const Duration(hours: 1),
          renewTtl: const Duration(hours: 2),
        )
        .token;
    bobToken = app.tokens
        .issue(
          userId: bobId,
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

  test('XEP-0199 ping receives result', () async {
    final alice = await connect(
      email: 'alice@rainbow-stub.local',
      token: aliceToken,
      resource: 'phone',
    );
    final ready = alice.awaitId('ping1');
    alice.send(
      '<iq type="get" id="ping1" to="$_domain">'
      '<ping xmlns="urn:xmpp:ping"/></iq>',
    );
    final resp = await ready.timeout(const Duration(seconds: 3));
    expect(resp.getAttribute('type'), 'result');
    await alice.close();
  });

  test('XEP-0030 disco#info advertises expected features', () async {
    final alice = await connect(
      email: 'alice@rainbow-stub.local',
      token: aliceToken,
      resource: 'phone',
    );
    final ready = alice.awaitId('d1');
    alice.send(
      '<iq type="get" id="d1" to="$_domain">'
      '<query xmlns="http://jabber.org/protocol/disco#info"/></iq>',
    );
    final resp = await ready.timeout(const Duration(seconds: 3));
    final feats = resp
        .findAllElements(
          'feature',
          namespace: 'http://jabber.org/protocol/disco#info',
        )
        .map((e) => e.getAttribute('var'))
        .whereType<String>()
        .toSet();
    expect(
      feats,
      containsAll(['urn:xmpp:ping', 'jabber:iq:roster', 'urn:xmpp:mam:2']),
    );
    await alice.close();
  });

  test('RFC 6121 roster get returns bob as subscription="both"', () async {
    final alice = await connect(
      email: 'alice@rainbow-stub.local',
      token: aliceToken,
      resource: 'phone',
    );
    final ready = alice.awaitId('r1');
    alice.send('<iq type="get" id="r1"><query xmlns="jabber:iq:roster"/></iq>');
    final resp = await ready.timeout(const Duration(seconds: 3));
    final items = resp
        .findAllElements('item', namespace: 'jabber:iq:roster')
        .toList();
    expect(items, hasLength(1));
    expect(items.first.getAttribute('jid'), '$bobId@$_domain');
    expect(items.first.getAttribute('subscription'), 'both');
    await alice.close();
  });

  test(
    'initial <presence/> triggers peer presence delivery back to caller',
    () async {
      final alice = await connect(
        email: 'alice@rainbow-stub.local',
        token: aliceToken,
        resource: 'phone',
      );
      final ready = alice.stream.firstWhere(
        (e) =>
            e.localName == 'presence' &&
            e.getAttribute('from') == '$bobId@$_domain',
      );
      alice.send('<presence/>');
      final pres = await ready.timeout(const Duration(seconds: 3));
      expect(pres.getElement('show')?.innerText, 'away');
      expect(pres.getElement('status')?.innerText, 'lunch');
      await alice.close();
    },
  );

  test(
    'REST DELETE /networks/:contactId triggers roster push over XMPP',
    () async {
      final alice = await connect(
        email: 'alice@rainbow-stub.local',
        token: aliceToken,
        resource: 'phone',
      );
      final pushed = alice.stream.firstWhere(
        (e) =>
            e.localName == 'iq' &&
            e.getAttribute('type') == 'set' &&
            e.getElement('query', namespace: 'jabber:iq:roster') != null,
      );

      // REST delete.
      final client = HttpClient();
      try {
        final r = await client.deleteUrl(
          Uri.parse(
            'http://$host:$port/api/rainbow/enduser/v1.0/users/networks/$bobId',
          ),
        );
        r.persistentConnection = false;
        r.headers.set('authorization', 'Bearer $aliceToken');
        await (await r.close()).drain<void>();
      } finally {
        client.close(force: true);
      }

      final iq = await pushed.timeout(const Duration(seconds: 3));
      final item = iq
          .getElement('query', namespace: 'jabber:iq:roster')!
          .getElement('item')!;
      expect(item.getAttribute('subscription'), 'remove');
      expect(item.getAttribute('jid'), '$bobId@$host');
      await alice.close();
    },
  );

  test('MUC join returns occupant snapshot + self-presence with 110', () async {
    // Owner alice, bob is accepted member.
    final bubble = app.bubbles.create(ownerId: aliceId, name: 'Room A');
    app.bubbles.addMember(bubble.id, bobId, status: 'accepted');

    final alice = await connect(
      email: 'alice@rainbow-stub.local',
      token: aliceToken,
      resource: 'phone',
    );
    final occupants = <String>[];
    var selfSeen = false;
    late StreamSubscription sub;
    final done = Completer<void>();
    sub = alice.stream.listen((e) {
      if (e.localName != 'presence') return;
      final from = e.getAttribute('from') ?? '';
      if (!from.startsWith('${bubble.id}@muc.$_domain/')) return;
      occupants.add(from);
      final has110 = e
          .findAllElements(
            'status',
            namespace: 'http://jabber.org/protocol/muc#user',
          )
          .any((s) => s.getAttribute('code') == '110');
      if (has110) {
        selfSeen = true;
        done.complete();
      }
    });
    alice.send('<presence to="${bubble.id}@muc.$_domain/alice"/>');
    await done.future.timeout(const Duration(seconds: 3));
    await sub.cancel();
    expect(selfSeen, isTrue);
    expect(occupants.length, greaterThanOrEqualTo(2));
    await alice.close();
  });

  test('delivery receipt (empty body <received/>) forwards to peer', () async {
    final alice = await connect(
      email: 'alice@rainbow-stub.local',
      token: aliceToken,
      resource: 'phone',
    );
    final bob = await connect(
      email: 'bob@rainbow-stub.local',
      token: bobToken,
      resource: 'web',
    );
    final ready = bob.awaitLocal('message');
    alice.send(
      '<message id="rcpt1" to="$bobId@$_domain" type="chat">'
      '<received xmlns="urn:xmpp:receipts" id="orig-42"/>'
      '</message>',
    );
    final msg = await ready.timeout(const Duration(seconds: 3));
    final rcpt = msg.getElement('received', namespace: 'urn:xmpp:receipts');
    expect(rcpt, isNotNull);
    expect(rcpt!.getAttribute('id'), 'orig-42');
    expect(msg.getElement('body'), isNull);
    await alice.close();
    await bob.close();
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
