// Unit tests for the RFC 7616 / RFC 2617 Digest helper used by the
// gateway's outbound INVITE challenge-response flow.

import 'package:rainbow_stub/src/sip/digest_auth.dart';
import 'package:test/test.dart';

void main() {
  group('parseDigestChallenge', () {
    test('RFC 7616 §3.9.1 basic MD5 with qop=auth', () {
      final ch = parseDigestChallenge(
        'Digest realm="http-auth@example.org", qop="auth, auth-int", '
        'algorithm=MD5, '
        'nonce="7ypf/xlj9XXwfDPEoM4URrv/xwf94BcCAzFZH4GiTo0v", '
        'opaque="FQhe/qaU925kfnzjCev0ciny7QMkPqMAFRtzCUYo5tdS"',
      );
      expect(ch.realm, 'http-auth@example.org');
      expect(ch.nonce, '7ypf/xlj9XXwfDPEoM4URrv/xwf94BcCAzFZH4GiTo0v');
      expect(ch.qop, 'auth, auth-int');
      expect(ch.opaque, 'FQhe/qaU925kfnzjCev0ciny7QMkPqMAFRtzCUYo5tdS');
      expect(ch.algorithm, 'MD5');
      expect(ch.stale, isFalse);
    });

    test('stale=true propagates', () {
      final ch = parseDigestChallenge(
        'Digest realm="r", nonce="n", stale=true',
      );
      expect(ch.stale, isTrue);
    });

    test('missing realm/nonce throws FormatException', () {
      expect(
        () => parseDigestChallenge('Digest realm="r"'),
        throwsFormatException,
      );
    });
  });

  group('buildAuthorizationHeader', () {
    test(
        'RFC 2617 §3.5 example (MD5 + qop=auth) reproduces the '
        'documented response digest', () {
      // Reference values from RFC 2617:
      //   username = Mufasa, password = Circle Of Life
      //   realm    = testrealm@host.com
      //   method   = GET, uri = /dir/index.html
      //   nonce    = dcd98b7102dd2f0e8b11d0f600bfb0c093
      //   nc       = 00000001, cnonce = 0a4f113b
      //   qop      = auth
      //   expected response = 6629fae49393a05397450978507c4ef1
      final ch = parseDigestChallenge(
        'Digest realm="testrealm@host.com", '
        'nonce="dcd98b7102dd2f0e8b11d0f600bfb0c093", '
        'qop="auth", '
        'opaque="5ccc069c403ebaf9f0171e9517f40e41"',
      );
      final header = buildAuthorizationHeader(
        challenge: ch,
        username: 'Mufasa',
        password: 'Circle Of Life',
        method: 'GET',
        uri: '/dir/index.html',
        nc: 1,
        cnonce: '0a4f113b',
      );
      expect(header, contains('response="6629fae49393a05397450978507c4ef1"'));
      expect(header, contains('username="Mufasa"'));
      expect(header, contains('realm="testrealm@host.com"'));
      expect(header, contains('qop=auth'));
      expect(header, contains('nc=00000001'));
      expect(header, contains('cnonce="0a4f113b"'));
      expect(header, contains('opaque="5ccc069c403ebaf9f0171e9517f40e41"'));
    });

    test('qop absent → RFC 2069 3-tuple compute (no nc/cnonce/qop)', () {
      final ch = parseDigestChallenge(
        'Digest realm="r", nonce="deadbeef"',
      );
      final header = buildAuthorizationHeader(
        challenge: ch,
        username: 'u',
        password: 'p',
        method: 'INVITE',
        uri: 'sip:bob@example.com',
      );
      expect(header, contains('username="u"'));
      expect(header, contains('nonce="deadbeef"'));
      expect(header, isNot(contains('qop=')));
      expect(header, isNot(contains('nc=')));
      expect(header, isNot(contains('cnonce=')));
    });
  });
}
