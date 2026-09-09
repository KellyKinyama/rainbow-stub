import 'dart:convert';

import '../config/config.dart';
import '../util/errors.dart';
import '../users/user_model.dart';
import '../users/user_repository.dart';
import 'token_store.dart';

class LoginResult {
  LoginResult({required this.token, required this.user});

  final TokenRecord token;
  final User user;
}

class AuthService {
  AuthService({
    required this.config,
    required this.users,
    required this.tokens,
  });

  final Config config;
  final UserRepository users;
  final TokenStore tokens;

  /// Validates the `x-rainbow-app-auth` header (Basic base64(appId:secret)).
  void validateAppAuth(String? header) {
    if (header == null || !header.startsWith('Basic ')) {
      throw RainbowError.unauthorized('Missing application signature');
    }
    final decoded = utf8.decode(base64.decode(header.substring(6).trim()));
    final idx = decoded.indexOf(':');
    if (idx <= 0) {
      throw RainbowError.unauthorized('Malformed application signature');
    }
    final id = decoded.substring(0, idx);
    final secret = decoded.substring(idx + 1);
    if (id != config.auth.appId || secret != config.auth.appSecret) {
      throw RainbowError.unauthorized('Unknown application');
    }
  }

  ({String email, String password}) decodeBasic(String? header) {
    if (header == null || !header.startsWith('Basic ')) {
      throw RainbowError.unauthorized('Missing user credentials');
    }
    final decoded = utf8.decode(base64.decode(header.substring(6).trim()));
    final idx = decoded.indexOf(':');
    if (idx <= 0) {
      throw RainbowError.unauthorized('Malformed user credentials');
    }
    return (
      email: decoded.substring(0, idx),
      password: decoded.substring(idx + 1),
    );
  }

  LoginResult login(String email, String password) {
    final u = users.findByEmail(email);
    if (u == null || !users.verifyPassword(u, password)) {
      throw RainbowError.unauthorized('Bad user credentials');
    }
    final tok = tokens.issue(
      userId: u.id,
      ttl: config.auth.tokenTtl,
      renewTtl: config.auth.renewTtl,
    );
    return LoginResult(token: tok, user: u);
  }

  User authenticateBearer(String? header) {
    if (header == null || !header.startsWith('Bearer ')) {
      throw RainbowError.unauthorized('Missing bearer token');
    }
    final tok = tokens.find(header.substring(7).trim());
    if (tok == null || tok.revoked || tok.isExpired) {
      throw RainbowError.unauthorized('Invalid or expired token');
    }
    final u = users.findById(tok.userId);
    if (u == null) {
      throw RainbowError.unauthorized('Owner missing');
    }
    return u;
  }

  void logout(String? bearer) {
    if (bearer == null || !bearer.startsWith('Bearer ')) return;
    tokens.revoke(bearer.substring(7).trim());
  }

  LoginResult renew(String? bearer) {
    if (bearer == null || !bearer.startsWith('Bearer ')) {
      throw RainbowError.unauthorized('Missing bearer token');
    }
    final TokenRecord newTok;
    try {
      newTok = tokens.renew(
        oldToken: bearer.substring(7).trim(),
        ttl: config.auth.tokenTtl,
        renewTtl: config.auth.renewTtl,
      );
    } on StateError {
      throw RainbowError.unauthorized('Cannot renew token');
    }
    return LoginResult(token: newTok, user: users.findById(newTok.userId)!);
  }
}
