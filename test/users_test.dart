import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:logging/logging.dart';
import 'package:rainbow_stub/rainbow_stub.dart';
import 'package:shelf/shelf_io.dart' as shelf_io;
import 'package:test/test.dart';

/// Minimal PNG (1×1 transparent) — no external asset needed.
final _pngBytes = Uint8List.fromList(
  base64Decode(
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNkYAAAAAYAAjCB0C8AAAAASUVORK5CYII=',
  ),
);

const _appAuthHeader =
    'Basic NjVjNjgxYzAxYzhmMTFlOWFkZDg5MzJiMzU4ZWY4MWQ6VVlkdTN3Q1hUZGZ5akltaFVSbklrWjB0YWM1SjlYU0xzeklLQlJVVVdWQjM1YjZuVDNmV1YyQmhBR2hvamRCUQ==';

void main() {
  late HttpServer server;
  late RainbowStubApp app;
  late String base;
  late String aliceId;
  late String bobId;
  late String aliceToken;

  setUpAll(() {
    Logger.root.level = Level.INFO;
    Logger.root.onRecord.listen((r) {
      final err = r.error != null ? ' err=${r.error}' : '';
      // ignore: avoid_print
      print('${r.level.name} ${r.loggerName} ${r.message}$err');
      if (r.stackTrace != null) {
        // ignore: avoid_print
        print(r.stackTrace);
      }
    });
  });

  tearDownAll(() {});

  setUp(() async {
    final tempDir = Directory.systemTemp.createTempSync('rainbow-stub-p2');
    final config = Config(
      host: '127.0.0.1',
      port: 0,
      publicHost: 'localhost',
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
    final alice = app.users.create(
      loginEmail: 'alice@rainbow-stub.local',
      password: 'password',
      firstName: 'Alice',
      lastName: 'Sample',
    );
    final bob = app.users.create(
      loginEmail: 'bob@rainbow-stub.local',
      password: 'x',
      firstName: 'Bob',
      lastName: 'Marley',
    );
    app.users.create(
      loginEmail: 'carol@rainbow-stub.local',
      password: 'x',
      firstName: 'Carol',
      lastName: 'Danvers',
    );
    app.roster.add(alice.id, bob.id);
    app.presence.set(bob.id, 'away', status: 'lunch');
    aliceId = alice.id;
    bobId = bob.id;

    server = await shelf_io.serve(app.buildHandler(), '127.0.0.1', 0);
    base = 'http://127.0.0.1:${server.port}';

    final basic = base64Encode(
      utf8.encode('alice@rainbow-stub.local:password'),
    );
    final r = await _get(
      '$base/api/rainbow/authentication/v1.0/login',
      headers: {
        'authorization': 'Basic $basic',
        'x-rainbow-app-auth': _appAuthHeader,
      },
    );
    aliceToken = (jsonDecode(r.body) as Map)['token'] as String;
  });

  tearDown(() async {
    await server.close(force: true);
    app.db.close();
  });

  test('GET /users/networks returns roster + peerUser + presence', () async {
    final r = await _get(
      '$base/api/rainbow/enduser/v1.0/users/networks',
      headers: {'authorization': 'Bearer $aliceToken'},
    );
    expect(r.statusCode, 200);
    final body = jsonDecode(r.body) as Map<String, dynamic>;
    expect(body['total'], 1);
    final data = body['data'] as List;
    expect(data, hasLength(1));
    final entry = data.first as Map<String, dynamic>;
    expect(entry['userId'], aliceId);
    expect(entry['peerId'], bobId);
    expect(entry['peerUser']['loginEmail'], 'bob@rainbow-stub.local');
    expect(entry['peerUser']['presence']['show'], 'away');
    expect(entry['peerUser']['presence']['status'], 'lunch');
  });

  test('GET /users returns search results (paginated)', () async {
    final r = await _get(
      '$base/api/rainbow/enduser/v1.0/users?search=car',
      headers: {'authorization': 'Bearer $aliceToken'},
    );
    expect(r.statusCode, 200);
    final body = jsonDecode(r.body) as Map<String, dynamic>;
    expect(body['total'], 1);
    final data = body['data'] as List;
    expect((data.first as Map)['firstName'], 'Carol');
  });

  test('GET arbitrary /users/:id works (not just self)', () async {
    final r = await _get(
      '$base/api/rainbow/enduser/v1.0/users/$bobId',
      headers: {'authorization': 'Bearer $aliceToken'},
    );
    expect(r.statusCode, 200);
    final body = jsonDecode(r.body) as Map<String, dynamic>;
    expect(body['data']['id'], bobId);
    expect(body['data']['presence']['show'], 'away');
  });

  test('POST /users/networks/:contactId adds to roster', () async {
    // First remove bob so we can re-add.
    await _request(
      'DELETE',
      '$base/api/rainbow/enduser/v1.0/users/networks/$bobId',
      headers: {'authorization': 'Bearer $aliceToken'},
    );
    final r = await _request(
      'POST',
      '$base/api/rainbow/enduser/v1.0/users/networks/$bobId',
      headers: {'authorization': 'Bearer $aliceToken'},
    );
    expect(r.statusCode, 201);
    final body = jsonDecode(r.body) as Map<String, dynamic>;
    expect(body['data']['peerId'], bobId);
    expect(body['data']['status'], 'accepted');
  });

  test(
    'POST /users/:id/photo (multipart) then GET /avatar echoes bytes',
    () async {
      const boundary = 'PHASE2';
      final buf = BytesBuilder()
        ..add(utf8.encode('--$boundary\r\n'))
        ..add(
          utf8.encode(
            'content-disposition: form-data; name="photo"; filename="a.png"\r\n',
          ),
        )
        ..add(utf8.encode('content-type: image/png\r\n\r\n'))
        ..add(_pngBytes)
        ..add(utf8.encode('\r\n--$boundary--\r\n'));

      final up = await _request(
        'POST',
        '$base/api/rainbow/enduser/v1.0/users/$aliceId/photo',
        headers: {
          'authorization': 'Bearer $aliceToken',
          'content-type': 'multipart/form-data; boundary=$boundary',
        },
        body: buf.toBytes(),
      );
      expect(up.statusCode, 200);
      final upBody = jsonDecode(up.body) as Map<String, dynamic>;
      expect(upBody['data']['lastAvatarUpdateDate'], isNotNull);

      final get = await _rawGet(
        '$base/api/rainbow/enduser/v1.0/users/$aliceId/avatar',
        headers: {'authorization': 'Bearer $aliceToken'},
      );
      expect(get.statusCode, 200);
      expect(get.contentType, 'image/png');
      expect(get.bodyBytes, _pngBytes);
    },
    // Flaky on Windows due to dart:HttpClient ephemeral-port / TIME_WAIT
    // pressure when many sockets churn in prior tests. Retry buys stability.
    retry: 2,
  );

  test('POST own /presences updates and is reflected in /users/:id', () async {
    final r = await _request(
      'POST',
      '$base/api/rainbow/enduser/v1.0/users/$aliceId/presences',
      headers: {
        'authorization': 'Bearer $aliceToken',
        'content-type': 'application/json',
      },
      body: utf8.encode(jsonEncode({'show': 'dnd', 'status': 'heads-down'})),
    );
    expect(r.statusCode, 200);
    final me = await _get(
      '$base/api/rainbow/enduser/v1.0/users/$aliceId',
      headers: {'authorization': 'Bearer $aliceToken'},
    );
    final body = jsonDecode(me.body) as Map<String, dynamic>;
    expect(body['data']['presence']['show'], 'dnd');
    expect(body['data']['presence']['status'], 'heads-down');
  });
}

class _Resp {
  _Resp(this.statusCode, this.body, {this.contentType, Uint8List? bytes})
    : bodyBytes = bytes ?? Uint8List(0);
  final int statusCode;
  final String body;
  final Uint8List bodyBytes;
  final String? contentType;
}

Future<_Resp> _get(String url, {Map<String, String>? headers}) =>
    _request('GET', url, headers: headers);

Future<_Resp> _request(
  String method,
  String url, {
  Map<String, String>? headers,
  List<int>? body,
}) async {
  final client = HttpClient();
  try {
    final req = await client.openUrl(method, Uri.parse(url));
    // Force close after this request — avoids stale keep-alive connections
    // being reused across per-test servers on different ports.
    req.persistentConnection = false;
    headers?.forEach(req.headers.set);
    if (body != null) {
      req.contentLength = body.length;
      req.add(body);
    }
    final resp = await req.close();
    final bytes = await resp.fold<BytesBuilder>(
      BytesBuilder(),
      (b, chunk) => b..add(chunk),
    );
    final asBytes = bytes.toBytes();
    return _Resp(
      resp.statusCode,
      utf8.decode(asBytes, allowMalformed: true),
      contentType: resp.headers.value('content-type'),
      bytes: asBytes,
    );
  } finally {
    client.close(force: true);
  }
}

Future<_Resp> _rawGet(String url, {Map<String, String>? headers}) =>
    _request('GET', url, headers: headers);
