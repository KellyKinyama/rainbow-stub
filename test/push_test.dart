import 'dart:convert';
import 'dart:io';

import 'package:rainbow_stub/rainbow_stub.dart';
import 'package:shelf/shelf_io.dart' as shelf_io;
import 'package:test/test.dart';

void main() {
  late HttpServer server;
  late RainbowStubApp app;
  late String base;
  late String aliceId;
  late String aliceToken;

  const appAuthHeader =
      'Basic NjVjNjgxYzAxYzhmMTFlOWFkZDg5MzJiMzU4ZWY4MWQ6VVlkdTN3Q1hUZGZ5akltaFVSbklrWjB0YWM1SjlYU0xzeklLQlJVVVdWQjM1YjZuVDNmV1YyQmhBR2hvamRCUQ==';

  setUp(() async {
    final tempDir = Directory.systemTemp.createTempSync('rainbow-stub-push');
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
    final alice = app.users.create(
      loginEmail: 'alice@rainbow-stub.local',
      password: 'password',
      firstName: 'Alice',
      lastName: 'Sample',
    );
    aliceId = alice.id;
    server = await shelf_io.serve(app.buildHandler(), '127.0.0.1', 0);
    base = 'http://127.0.0.1:${server.port}';

    final loginResp = await _get(
      '$base/api/rainbow/authentication/v1.0/login',
      headers: {
        'authorization':
            'Basic ${base64Encode(utf8.encode('alice@rainbow-stub.local:password'))}',
        'x-rainbow-app-auth': appAuthHeader,
      },
    );
    aliceToken =
        (jsonDecode(loginResp.body) as Map<String, dynamic>)['token'] as String;
  });

  tearDown(() async {
    await server.close(force: true);
    app.db.close();
  });

  test('POST /users/:id/push-tokens upserts, GET returns the token, '
      'DELETE removes it', () async {
    final base1 = '$base/api/rainbow/enduser/v1.0/users/$aliceId/push-tokens';
    final headers = {
      'authorization': 'Bearer $aliceToken',
      'content-type': 'application/json',
    };

    final post = await _post(
      base1,
      headers: headers,
      body: jsonEncode({'token': 'apns-abc123', 'platform': 'ios'}),
    );
    expect(post.statusCode, 201);

    final get1 = await _get(base1, headers: headers);
    final data1 =
        (jsonDecode(get1.body) as Map<String, dynamic>)['data']
            as List<dynamic>;
    expect(data1, hasLength(1));
    expect(data1.first['token'], 'apns-abc123');
    expect(data1.first['platform'], 'ios');

    // Re-upsert with a new platform for the same token.
    await _post(
      base1,
      headers: headers,
      body: jsonEncode({'token': 'apns-abc123', 'platform': 'debug'}),
    );
    final get2 = await _get(base1, headers: headers);
    final data2 =
        (jsonDecode(get2.body) as Map<String, dynamic>)['data']
            as List<dynamic>;
    expect(data2, hasLength(1));
    expect(data2.first['platform'], 'debug');

    // Delete.
    final del = await _delete('$base1/apns-abc123', headers: headers);
    expect(del.statusCode, 200);
    final get3 = await _get(base1, headers: headers);
    final data3 =
        (jsonDecode(get3.body) as Map<String, dynamic>)['data']
            as List<dynamic>;
    expect(data3, isEmpty);
  });

  test('POST rejects unknown platform', () async {
    final resp = await _post(
      '$base/api/rainbow/enduser/v1.0/users/$aliceId/push-tokens',
      headers: {
        'authorization': 'Bearer $aliceToken',
        'content-type': 'application/json',
      },
      body: jsonEncode({'token': 'x', 'platform': 'bogus'}),
    );
    expect(resp.statusCode, 400);
  });

  test('POST rejects mismatched user id (forbidden)', () async {
    // Register a second user and try to push their token onto alice.
    app.users.create(
      loginEmail: 'bob@rainbow-stub.local',
      password: 'password',
      firstName: 'Bob',
      lastName: 'Sample',
    );
    final loginResp = await _get(
      '$base/api/rainbow/authentication/v1.0/login',
      headers: {
        'authorization':
            'Basic ${base64Encode(utf8.encode('bob@rainbow-stub.local:password'))}',
        'x-rainbow-app-auth': appAuthHeader,
      },
    );
    final bobToken =
        (jsonDecode(loginResp.body) as Map<String, dynamic>)['token'] as String;

    final resp = await _post(
      '$base/api/rainbow/enduser/v1.0/users/$aliceId/push-tokens',
      headers: {
        'authorization': 'Bearer $bobToken',
        'content-type': 'application/json',
      },
      body: jsonEncode({'token': 'stolen', 'platform': 'ios'}),
    );
    expect(resp.statusCode, 403);
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

Future<_HttpResp> _post(
  String url, {
  Map<String, String>? headers,
  String? body,
}) async {
  final client = HttpClient();
  try {
    final req = await client.postUrl(Uri.parse(url));
    req.persistentConnection = false;
    headers?.forEach(req.headers.set);
    if (body != null) req.write(body);
    final resp = await req.close();
    final respBody = await resp.transform(utf8.decoder).join();
    return _HttpResp(resp.statusCode, respBody);
  } finally {
    client.close(force: true);
  }
}

Future<_HttpResp> _delete(String url, {Map<String, String>? headers}) async {
  final client = HttpClient();
  try {
    final req = await client.deleteUrl(Uri.parse(url));
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
