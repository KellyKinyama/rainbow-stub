import 'dart:convert';
import 'dart:io';

import 'package:rainbow_stub/rainbow_stub.dart';
import 'package:shelf/shelf_io.dart' as shelf_io;
import 'package:test/test.dart';

void main() {
  late HttpServer server;
  late RainbowStubApp app;
  late String base;

  const appAuthHeader =
      'Basic NjVjNjgxYzAxYzhmMTFlOWFkZDg5MzJiMzU4ZWY4MWQ6VVlkdTN3Q1hUZGZ5akltaFVSbklrWjB0YWM1SjlYU0xzeklLQlJVVVdWQjM1YjZuVDNmV1YyQmhBR2hvamRCUQ==';

  setUp(() async {
    final tempDir = Directory.systemTemp.createTempSync('rainbow-stub-test');
    final dbFile = File('${tempDir.path}/t.db');
    final config = Config(
      host: '127.0.0.1',
      port: 0,
      publicHost: 'localhost',
      tlsCertPath: 'certs/rainbow-stub.crt',
      tlsKeyPath: 'certs/rainbow-stub.key',
      dbPath: dbFile.path,
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
    app.users.create(
      loginEmail: 'alice@rainbow-stub.local',
      password: 'password',
      firstName: 'Alice',
      lastName: 'Sample',
    );
    server = await shelf_io.serve(app.buildHandler(), '127.0.0.1', 0);
    base = 'http://127.0.0.1:${server.port}';
  });

  tearDown(() async {
    await server.close(force: true);
    app.db.close();
  });

  test('login returns loggedInUser + bearer token', () async {
    final basic = base64Encode(
      utf8.encode('alice@rainbow-stub.local:password'),
    );
    final res = await _get(
      '$base/api/rainbow/authentication/v1.0/login',
      headers: {
        'authorization': 'Basic $basic',
        'x-rainbow-app-auth': appAuthHeader,
      },
    );
    expect(res.statusCode, 200);
    final body = jsonDecode(res.body) as Map<String, dynamic>;
    expect(body['token'], isA<String>());
    expect((body['token'] as String).length, 40);
    expect(body['loggedInUser']['loginEmail'], 'alice@rainbow-stub.local');
    expect(body['loggedInUser']['id'], hasLength(24));
    expect(body['supportedTokens'], contains('registerCallback'));
  });

  test('login rejects unknown app', () async {
    final basic = base64Encode(
      utf8.encode('alice@rainbow-stub.local:password'),
    );
    final res = await _get(
      '$base/api/rainbow/authentication/v1.0/login',
      headers: {
        'authorization': 'Basic $basic',
        'x-rainbow-app-auth': 'Basic ${base64Encode(utf8.encode("nope:nope"))}',
      },
    );
    expect(res.statusCode, 401);
  });

  test('login rejects bad password', () async {
    final basic = base64Encode(
      utf8.encode('alice@rainbow-stub.local:wrongpassword'),
    );
    final res = await _get(
      '$base/api/rainbow/authentication/v1.0/login',
      headers: {
        'authorization': 'Basic $basic',
        'x-rainbow-app-auth': appAuthHeader,
      },
    );
    expect(res.statusCode, 401);
    final body = jsonDecode(res.body) as Map<String, dynamic>;
    expect(body['errorCode'], 401);
  });

  test('bearer-authenticated GET /users/:id returns self', () async {
    final basic = base64Encode(
      utf8.encode('alice@rainbow-stub.local:password'),
    );
    final login = await _get(
      '$base/api/rainbow/authentication/v1.0/login',
      headers: {
        'authorization': 'Basic $basic',
        'x-rainbow-app-auth': appAuthHeader,
      },
    );
    final token = (jsonDecode(login.body) as Map)['token'] as String;
    final userId = (jsonDecode(login.body) as Map)['loggedInUser']['id'];

    final res = await _get(
      '$base/api/rainbow/enduser/v1.0/users/$userId',
      headers: {'authorization': 'Bearer $token'},
    );
    expect(res.statusCode, 200);
    final body = jsonDecode(res.body) as Map<String, dynamic>;
    expect(body['data']['id'], userId);
    expect(body['data']['loginEmail'], 'alice@rainbow-stub.local');
  });

  test('renew rotates token', () async {
    final basic = base64Encode(
      utf8.encode('alice@rainbow-stub.local:password'),
    );
    final login = await _get(
      '$base/api/rainbow/authentication/v1.0/login',
      headers: {
        'authorization': 'Basic $basic',
        'x-rainbow-app-auth': appAuthHeader,
      },
    );
    final oldToken = (jsonDecode(login.body) as Map)['token'] as String;
    final renew = await _get(
      '$base/api/rainbow/authentication/v1.0/renew',
      headers: {'authorization': 'Bearer $oldToken'},
    );
    expect(renew.statusCode, 200);
    final newToken = (jsonDecode(renew.body) as Map)['token'] as String;
    expect(newToken, isNot(oldToken));

    // Old token is now revoked.
    final res = await _get(
      '$base/api/rainbow/authentication/v1.0/renew',
      headers: {'authorization': 'Bearer $oldToken'},
    );
    expect(res.statusCode, 401);
  });
}

Future<_HttpResp> _get(String url, {Map<String, String>? headers}) async {
  final client = HttpClient();
  try {
    final req = await client.getUrl(Uri.parse(url));
    req.persistentConnection = false;
    headers?.forEach(req.headers.set);
    final resp = await req.close();
    final body = await resp.transform(utf8.decoder).join();
    return _HttpResp(resp.statusCode, body);
  } finally {
    client.close(force: true);
  }
}

class _HttpResp {
  _HttpResp(this.statusCode, this.body);
  final int statusCode;
  final String body;
}
