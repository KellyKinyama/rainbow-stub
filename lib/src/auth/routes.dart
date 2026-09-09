import 'dart:convert';
import 'dart:math';

import 'package:logging/logging.dart';
import 'package:shelf/shelf.dart';
import 'package:shelf_router/shelf_router.dart';
import 'package:sqlite3/sqlite3.dart';

import '../db/database.dart';
import '../util/errors.dart';
import '../util/json.dart';
import '../users/user_repository.dart';
import 'auth_service.dart';

final _log = Logger('auth.routes');

Router authRouter({
  required AuthService auth,
  required UserRepository users,
  required AppDatabase db,
}) {
  final r = Router();

  // ---- /api/rainbow/authentication/v1.0/login  (Basic user + x-rainbow-app-auth)
  r.get('/api/rainbow/authentication/v1.0/login', (Request req) async {
    auth.validateAppAuth(req.headers['x-rainbow-app-auth']);
    final creds = auth.decodeBasic(req.headers['authorization']);
    final result = auth.login(creds.email, creds.password);
    _log.info('login ok email=${creds.email} user=${result.user.id}');
    return jsonOk(_loginPayload(result));
  });

  // ---- /logout
  r.post('/api/rainbow/authentication/v1.0/logout', (Request req) async {
    auth.logout(req.headers['authorization']);
    return jsonOk({'status': 'Logout successful'});
  });

  // ---- /renew
  r.get('/api/rainbow/authentication/v1.0/renew', (Request req) async {
    final result = auth.renew(req.headers['authorization']);
    return jsonOk(_loginPayload(result));
  });

  // ---- self-register: send email
  r.post('/api/rainbow/enduser/v1.0/users/self-register/send-email', (
    Request req,
  ) async {
    auth.validateAppAuth(req.headers['x-rainbow-app-auth']);
    final body = await readJsonBody(req);
    final email = (body['email'] ?? body['loginEmail']) as String?;
    if (email == null || email.isEmpty) {
      throw RainbowError.badRequest('email is required');
    }
    final token = _issueOneTimeToken(
      db,
      purpose: 'self-register',
      email: email,
    );
    _log.info('self-register token=$token email=$email');
    // Real Rainbow emails the code; we return it so devs can copy-paste.
    return jsonOk({
      'status': 'email sent',
      'data': {'email': email, 'devToken': token},
    });
  });

  // ---- self-register: validate token
  r.post('/api/rainbow/enduser/v1.0/users/self-register/validate-token', (
    Request req,
  ) async {
    auth.validateAppAuth(req.headers['x-rainbow-app-auth']);
    final body = await readJsonBody(req);
    final token = body['token'] as String?;
    final row = _findOneTimeToken(db, token, 'self-register');
    if (row == null) throw RainbowError.badRequest('Invalid token');
    return jsonOk({
      'sucess': true, // note: matches SDK typo in EventType payload
      'data': {'email': row['email']},
    });
  });

  // ---- self-register: create account
  r.post('/api/rainbow/enduser/v1.0/users/self-register', (Request req) async {
    auth.validateAppAuth(req.headers['x-rainbow-app-auth']);
    final body = await readJsonBody(req);
    final token = body['token'] as String?;
    final ot = _findOneTimeToken(db, token, 'self-register');
    if (ot == null) throw RainbowError.badRequest('Invalid token');
    final email = ot['email'] as String;
    if (users.findByEmail(email) != null) {
      throw RainbowError.conflict('Email already registered');
    }
    final user = users.create(
      loginEmail: email,
      password:
          body['password'] as String? ??
          (throw RainbowError.badRequest('password required')),
      firstName: body['firstName'] as String?,
      lastName: body['lastName'] as String?,
    );
    _consumeOneTimeToken(db, token!);
    _log.info('self-register created user=${user.id} email=$email');
    return jsonOk({'data': user.toRainbowJson()}, status: 201);
  });

  // ---- reset password: send email
  r.post('/api/rainbow/enduser/v1.0/users/reset-password/send-email', (
    Request req,
  ) async {
    auth.validateAppAuth(req.headers['x-rainbow-app-auth']);
    final body = await readJsonBody(req);
    final email = body['email'] as String?;
    if (email == null || email.isEmpty) {
      throw RainbowError.badRequest('email is required');
    }
    final u = users.findByEmail(email);
    // Don't leak account existence — but log for dev.
    if (u == null) {
      _log.info('reset-password requested for unknown email=$email');
      return jsonOk({'status': 'ok'});
    }
    final token = _issueOneTimeToken(
      db,
      purpose: 'reset-password',
      email: email,
    );
    _log.info('reset-password token=$token email=$email');
    return jsonOk({
      'status': 'email sent',
      'data': {'devToken': token},
    });
  });

  // ---- reset password: apply
  r.post('/api/rainbow/enduser/v1.0/users/reset-password', (Request req) async {
    auth.validateAppAuth(req.headers['x-rainbow-app-auth']);
    final body = await readJsonBody(req);
    final token = body['token'] as String?;
    final password = body['password'] as String?;
    if (token == null || password == null) {
      throw RainbowError.badRequest('token + password required');
    }
    final ot = _findOneTimeToken(db, token, 'reset-password');
    if (ot == null) throw RainbowError.badRequest('Invalid token');
    final u = users.findByEmail(ot['email'] as String);
    if (u == null) throw RainbowError.notFound('User missing');
    users.setPassword(u.id, password);
    _consumeOneTimeToken(db, token);
    return jsonOk({'status': 'password updated'});
  });

  return r;
}

// ---- helpers ----------------------------------------------------------------

Map<String, dynamic> _loginPayload(LoginResult result) {
  final expiresIn = result.token.expiresAt
      .difference(DateTime.now().toUtc())
      .inSeconds;
  final ttl = result.token.renewExpiresAt
      .difference(DateTime.now().toUtc())
      .inSeconds;
  return {
    'loggedInUser': result.user.toRainbowJson(),
    'token': result.token.token,
    'expiresIn': expiresIn,
    'timeToLive': ttl,
    'expirationDate': result.token.expiresAt.toIso8601String(),
    'supportedTokens': const ['registerCallback'],
  };
}

String _issueOneTimeToken(
  AppDatabase db, {
  required String purpose,
  required String email,
  Map<String, dynamic>? payload,
}) {
  final r = Random.secure();
  final digits = List.generate(6, (_) => r.nextInt(10)).join();
  final expires = DateTime.now().toUtc().add(const Duration(minutes: 15));
  db.db.execute(
    '''
    INSERT INTO one_time_tokens (token, purpose, email, payload, expires_at)
    VALUES (?, ?, ?, ?, ?)
    ''',
    [
      digits,
      purpose,
      email,
      payload == null ? null : jsonEncode(payload),
      expires.toIso8601String(),
    ],
  );
  return digits;
}

Row? _findOneTimeToken(AppDatabase db, String? token, String purpose) {
  if (token == null || token.isEmpty) return null;
  final rs = db.db.select(
    '''
    SELECT * FROM one_time_tokens
    WHERE token = ? AND purpose = ? AND consumed_at IS NULL
      AND expires_at > ?
    ''',
    [token, purpose, DateTime.now().toUtc().toIso8601String()],
  );
  return rs.isEmpty ? null : rs.first;
}

void _consumeOneTimeToken(AppDatabase db, String token) {
  db.db.execute('UPDATE one_time_tokens SET consumed_at = ? WHERE token = ?', [
    DateTime.now().toUtc().toIso8601String(),
    token,
  ]);
}
