import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';

/// RFC 7616 / RFC 2617 Digest challenge parsed from a
/// `WWW-Authenticate` or `Proxy-Authenticate` header.
class DigestChallenge {
  DigestChallenge({
    required this.realm,
    required this.nonce,
    this.opaque,
    this.qop,
    this.algorithm = 'MD5',
    this.stale = false,
  });

  final String realm;
  final String nonce;
  final String? opaque;

  /// May be `null` (RFC 2617 default), `"auth"`, `"auth-int"`, or a
  /// comma-separated list. Only `auth` is supported when negotiating.
  final String? qop;

  /// `MD5` (default), `MD5-sess`, `SHA-256`, `SHA-256-sess`. Only MD5
  /// and MD5-sess are actually computed here — the two most common in
  /// the wild for SIP.
  final String algorithm;

  final bool stale;
}

/// Parse the parameter list of a `Digest ...` challenge into a
/// [DigestChallenge]. Accepts the header value with or without the
/// leading scheme token.
DigestChallenge parseDigestChallenge(String headerValue) {
  var s = headerValue.trim();
  if (s.toLowerCase().startsWith('digest')) {
    s = s.substring(6).trim();
  }
  final params = _parseParams(s);
  final realm = params['realm'];
  final nonce = params['nonce'];
  if (realm == null || nonce == null) {
    throw FormatException('digest challenge missing realm/nonce: $headerValue');
  }
  return DigestChallenge(
    realm: realm,
    nonce: nonce,
    opaque: params['opaque'],
    qop: params['qop'],
    algorithm: params['algorithm'] ?? 'MD5',
    stale: (params['stale'] ?? '').toLowerCase() == 'true',
  );
}

/// Compute the `Authorization` / `Proxy-Authorization` header value for
/// the given challenge, credentials, and request line. When [qop] is
/// present the caller-supplied [nc] (nonce count) + [cnonce] are woven
/// into the response digest.
String buildAuthorizationHeader({
  required DigestChallenge challenge,
  required String username,
  required String password,
  required String method,
  required String uri,
  int nc = 1,
  String? cnonce,
  Random? random,
}) {
  final algo = challenge.algorithm.toUpperCase();
  final hashName = algo.startsWith('SHA-256') ? 'sha-256' : 'md5';
  Digest hash(String input) => hashName == 'sha-256'
      ? sha256.convert(utf8.encode(input))
      : md5.convert(utf8.encode(input));

  final a1raw = '$username:${challenge.realm}:$password';
  var ha1 = hash(a1raw).toString();
  if (algo.endsWith('-SESS')) {
    final c = cnonce ?? _randomCnonce(random);
    ha1 = hash('$ha1:${challenge.nonce}:$c').toString();
  }
  final ha2 = hash('$method:$uri').toString();

  final qopSel = _selectQop(challenge.qop);
  final String response;
  final ncHex = nc.toRadixString(16).padLeft(8, '0');
  final c = cnonce ?? _randomCnonce(random);
  if (qopSel != null) {
    response =
        hash('$ha1:${challenge.nonce}:$ncHex:$c:$qopSel:$ha2').toString();
  } else {
    response = hash('$ha1:${challenge.nonce}:$ha2').toString();
  }

  final params = <String, String>{
    'username': _quoted(username),
    'realm': _quoted(challenge.realm),
    'nonce': _quoted(challenge.nonce),
    'uri': _quoted(uri),
    'response': _quoted(response),
    'algorithm': challenge.algorithm,
    if (challenge.opaque != null) 'opaque': _quoted(challenge.opaque!),
    if (qopSel != null) ...{
      'qop': qopSel,
      'nc': ncHex,
      'cnonce': _quoted(c),
    },
  };
  final rendered = params.entries.map((e) => '${e.key}=${e.value}').join(', ');
  return 'Digest $rendered';
}

String? _selectQop(String? offered) {
  if (offered == null) return null;
  final options = offered.split(',').map((s) => s.trim().toLowerCase()).toSet();
  if (options.contains('auth')) return 'auth';
  // auth-int not supported (would require body hashing at build time).
  return null;
}

String _randomCnonce(Random? random) {
  final r = random ?? Random.secure();
  final bytes = List<int>.generate(8, (_) => r.nextInt(256));
  return bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
}

String _quoted(String v) =>
    '"${v.replaceAll(r'\', r'\\').replaceAll('"', r'\"')}"';

Map<String, String> _parseParams(String input) {
  final out = <String, String>{};
  var i = 0;
  final s = input;
  while (i < s.length) {
    while (i < s.length && (s[i] == ' ' || s[i] == ',' || s[i] == '\t')) {
      i++;
    }
    final kStart = i;
    while (i < s.length && s[i] != '=' && s[i] != ',') {
      i++;
    }
    final key = s.substring(kStart, i).trim();
    if (key.isEmpty) break;
    if (i >= s.length || s[i] != '=') {
      out[key.toLowerCase()] = '';
      continue;
    }
    i++; // skip =
    String value;
    if (i < s.length && s[i] == '"') {
      i++;
      final buf = StringBuffer();
      while (i < s.length && s[i] != '"') {
        if (s[i] == r'\' && i + 1 < s.length) {
          buf.write(s[i + 1]);
          i += 2;
        } else {
          buf.write(s[i]);
          i++;
        }
      }
      if (i < s.length) i++; // skip closing "
      value = buf.toString();
    } else {
      final vStart = i;
      while (i < s.length && s[i] != ',') {
        i++;
      }
      value = s.substring(vStart, i).trim();
    }
    out[key.toLowerCase()] = value;
  }
  return out;
}
