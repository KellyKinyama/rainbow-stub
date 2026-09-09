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

void main() {
  late RainbowStubApp app;
  late HttpServer server;
  late String base;
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
    final tempDir = Directory.systemTemp.createTempSync('rainbow-stub-p4');
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
        appId: '65c681c01c8f11e9add8932b358ef81d',
        appSecret:
            'UYdu3wCXTdfyjImhURnIkZ0tac5J9XSLszIKBRUUWVB35b6nT3fWV2BhAGhojdBQ',
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
    aliceId = app.users
        .create(
          loginEmail: 'alice@rainbow-stub.local',
          password: 'password',
          firstName: 'Alice',
          lastName: 'Sample',
        )
        .id;
    bobId = app.users
        .create(
          loginEmail: 'bob@rainbow-stub.local',
          password: 'password',
          firstName: 'Bob',
          lastName: 'Marley',
        )
        .id;
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
    base = 'http://${server.address.host}:${server.port}';
  });

  tearDown(() async {
    await server.close(force: true);
    app.db.close();
  });

  Future<_Resp> req(
    String method,
    String path, {
    Map<String, String>? headers,
    Object? body,
  }) async {
    final client = HttpClient();
    try {
      final r = await client.openUrl(method, Uri.parse('$base$path'));
      r.persistentConnection = false;
      headers?.forEach(r.headers.set);
      if (body != null) {
        final bytes = body is List<int> ? body : utf8.encode(body.toString());
        r.contentLength = bytes.length;
        r.add(bytes);
      }
      final resp = await r.close();
      final bytes = await resp.fold<BytesBuilder>(
        BytesBuilder(),
        (b, chunk) => b..add(chunk),
      );
      return _Resp(
        resp.statusCode,
        utf8.decode(bytes.toBytes(), allowMalformed: true),
      );
    } finally {
      client.close(force: true);
    }
  }

  Map<String, String> hdr(String token, {String? ct}) => {
    'authorization': 'Bearer $token',
    if (ct != null) 'content-type': ct,
  };

  test('create bubble → both members see it via /rooms', () async {
    final create = await req(
      'POST',
      '/api/rainbow/enduser/v1.0/rooms',
      headers: hdr(aliceToken, ct: 'application/json'),
      body: jsonEncode({'name': 'Team Rainbow', 'topic': 'daily standup'}),
    );
    expect(create.statusCode, 201);
    final bubble = (jsonDecode(create.body) as Map)['data'] as Map;
    final bubbleId = bubble['id'] as String;

    final invite = await req(
      'POST',
      '/api/rainbow/enduser/v1.0/rooms/$bubbleId/users',
      headers: hdr(aliceToken, ct: 'application/json'),
      body: jsonEncode({'userId': bobId}),
    );
    expect(invite.statusCode, 201);

    final bobRooms = await req(
      'GET',
      '/api/rainbow/enduser/v1.0/rooms/invitations',
      headers: hdr(bobToken),
    );
    expect(bobRooms.statusCode, 200);
    final body = jsonDecode(bobRooms.body) as Map;
    expect(body['total'], 1);
    expect((body['data'] as List).first['name'], 'Team Rainbow');

    // Bob accepts
    final accept = await req(
      'PUT',
      '/api/rainbow/enduser/v1.0/rooms/$bubbleId/users/$bobId',
      headers: hdr(bobToken, ct: 'application/json'),
      body: jsonEncode({'status': 'accepted'}),
    );
    expect(accept.statusCode, 200);

    final bobAllRooms = await req(
      'GET',
      '/api/rainbow/enduser/v1.0/rooms',
      headers: hdr(bobToken),
    );
    expect(jsonDecode(bobAllRooms.body)['total'], 1);
  });

  test(
    'creating a bubble pushes BubblesListUpdated to owner over XMPP',
    () async {
      final alice = await _connect(
        base,
        email: 'alice@rainbow-stub.local',
        token: aliceToken,
        resource: 'phone',
      );
      final gotEvent = alice.awaitLocal('message');
      final postFuture = req(
        'POST',
        '/api/rainbow/enduser/v1.0/rooms',
        headers: hdr(aliceToken, ct: 'application/json'),
        body: jsonEncode({'name': 'Pushed Bubble'}),
      );
      final ev = await gotEvent.timeout(const Duration(seconds: 3));
      await postFuture;
      expect(ev.getAttribute('type'), 'headline');
      final event = ev.getElement('event', namespace: 'urn:rainbow:events');
      expect(event?.getAttribute('type'), 'BubblesListUpdated');
      await alice.close();
    },
  );

  test('groupchat message fans out to accepted members', () async {
    // Create a bubble; auto-accept bob.
    final bubble = app.bubbles.create(ownerId: aliceId, name: 'Fan-out room');
    app.bubbles.addMember(bubble.id, bobId, status: 'accepted');

    final alice = await _connect(
      base,
      email: 'alice@rainbow-stub.local',
      token: aliceToken,
      resource: 'phone',
    );
    final bob = await _connect(
      base,
      email: 'bob@rainbow-stub.local',
      token: bobToken,
      resource: 'web',
    );

    final delivered = bob.awaitLocal('message');
    alice.send(
      '<message id="g1" to="${bubble.id}@muc.$_domain" type="groupchat">'
      '<body>hello team</body></message>',
    );
    final got = await delivered.timeout(const Duration(seconds: 3));
    expect(got.getElement('body')?.innerText, 'hello team');
    expect(got.getAttribute('from'), '$aliceId@$_domain/phone');
    expect(app.bubbles.historyFor(bubble.id), hasLength(1));
    await alice.close();
    await bob.close();
  });

  test('file upload/download round-trip + FileAttachFinished push', () async {
    final descResp = await req(
      'POST',
      '/api/rainbow/fileServer/v1.0/files',
      headers: hdr(aliceToken, ct: 'application/json'),
      body: jsonEncode({
        'peer': '$bobId@$_domain',
        'peerType': 'user',
        'fileName': 'notes.txt',
        'mime': 'text/plain',
      }),
    );
    expect(descResp.statusCode, 201);
    final fileId =
        ((jsonDecode(descResp.body) as Map)['data'] as Map)['id'] as String;

    final alice = await _connect(
      base,
      email: 'alice@rainbow-stub.local',
      token: aliceToken,
      resource: 'phone',
    );
    final pushed = alice.awaitLocal('message');

    final payload = utf8.encode('hello file world');
    final up = await req(
      'PUT',
      '/api/rainbow/fileServer/v1.0/files/$fileId/data',
      headers: hdr(aliceToken, ct: 'text/plain'),
      body: payload,
    );
    expect(up.statusCode, 200);

    final ev = await pushed.timeout(const Duration(seconds: 3));
    expect(
      ev
          .getElement('event', namespace: 'urn:rainbow:events')
          ?.getAttribute('type'),
      'FileAttachFinished',
    );

    final dl = await req(
      'GET',
      '/api/rainbow/fileServer/v1.0/files/$fileId/data',
      headers: hdr(aliceToken),
    );
    expect(dl.statusCode, 200);
    expect(dl.body, 'hello file world');
    await alice.close();
  });

  test('call log listing + delete', () async {
    final entry = app.callLog.insert(
      ownerId: aliceId,
      peerJid: '$bobId@$_domain',
      peerDisplay: 'Bob',
      direction: 'incoming',
      state: 'missed',
    );
    final list = await req(
      'GET',
      '/api/rainbow/enduser/v1.0/users/$aliceId/calllogs',
      headers: hdr(aliceToken),
    );
    expect(list.statusCode, 200);
    final body = jsonDecode(list.body) as Map;
    expect(body['total'], 1);
    expect(body['unreadMissed'], 1);

    final del = await req(
      'DELETE',
      '/api/rainbow/enduser/v1.0/users/$aliceId/calllogs/${entry.id}',
      headers: hdr(aliceToken),
    );
    expect(del.statusCode, 200);
    final list2 = await req(
      'GET',
      '/api/rainbow/enduser/v1.0/users/$aliceId/calllogs',
      headers: hdr(aliceToken),
    );
    expect((jsonDecode(list2.body) as Map)['total'], 0);
  });
}

class _Resp {
  _Resp(this.statusCode, this.body);
  final int statusCode;
  final String body;
}

Future<_Xmpp> _connect(
  String httpBase, {
  required String email,
  required String token,
  required String resource,
}) async {
  final uri = Uri.parse('${httpBase.replaceFirst('http', 'ws')}/websocket');
  final channel = IOWebSocketChannel.connect(uri, protocols: ['xmpp']);
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
