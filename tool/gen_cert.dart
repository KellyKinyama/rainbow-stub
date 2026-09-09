// Generates a self-signed TLS cert + key for local development.
// Requires `openssl` on PATH (already present in Git-for-Windows / WSL).
//
// Usage:  dart run tool/gen_cert.dart
import 'dart:io';

Future<void> main() async {
  final certDir = Directory('certs');
  if (!await certDir.exists()) await certDir.create(recursive: true);

  const cert = 'certs/rainbow-stub.crt';
  const key = 'certs/rainbow-stub.key';

  if (await File(cert).exists() && await File(key).exists()) {
    stdout.writeln('Cert already exists at $cert — nothing to do.');
    return;
  }

  final result = await Process.run('openssl', [
    'req',
    '-x509',
    '-newkey',
    'rsa:2048',
    '-keyout',
    key,
    '-out',
    cert,
    '-days',
    '825',
    '-nodes',
    '-subj',
    '/CN=rainbow-stub.local/O=rainbow-stub/C=US',
    '-addext',
    'subjectAltName=DNS:localhost,DNS:rainbow-stub.local,IP:127.0.0.1,IP:10.0.2.2',
  ]);
  if (result.exitCode != 0) {
    stderr.writeln('openssl failed:\n${result.stderr}');
    exit(result.exitCode);
  }
  stdout.writeln('Generated $cert + $key');
  stdout.writeln(
    'Trust it on Android emulator: adb push $cert /data/local/tmp/ '
    '&& adb shell su 0 mv /data/local/tmp/rainbow-stub.crt '
    '/system/etc/security/cacerts/',
  );
}
