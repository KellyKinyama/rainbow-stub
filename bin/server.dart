import 'dart:async';
import 'dart:io';

import 'package:logging/logging.dart';
import 'package:rainbow_stub/rainbow_stub.dart';
import 'package:shelf/shelf_io.dart' as shelf_io;

Future<void> main(List<String> args) async {
  final configPath = _argValue(args, '--config') ?? 'config/rainbow-stub.yaml';
  final config = await Config.load(configPath);
  final log = config.logs.isJson ? initJsonLogging() : initTextLogging();

  var tlsEnabled =
      config.tls.enabled &&
      File(config.tlsCertPath).existsSync() &&
      File(config.tlsKeyPath).existsSync();

  if (config.tls.enabled && !tlsEnabled && config.tls.autoGenerate) {
    log.info('TLS cert missing — auto-generating self-signed pair');
    final ok = await _autoGenerateCert(
      certPath: config.tlsCertPath,
      keyPath: config.tlsKeyPath,
      publicHost: config.publicHost,
      log: log,
    );
    if (ok) {
      tlsEnabled = true;
    }
  }
  if (!tlsEnabled) {
    log.warning(
      config.tls.enabled
          ? 'TLS enabled but no cert found and auto-gen failed — '
                'starting HTTP only.'
          : 'TLS disabled by config — starting HTTP only.',
    );
  }

  final app = await RainbowStubApp.boot(config);
  final handler = app.buildHandler();

  final ctx = tlsEnabled
      ? (SecurityContext()
          ..useCertificateChain(config.tlsCertPath)
          ..usePrivateKey(config.tlsKeyPath))
      : null;

  final server = await shelf_io.serve(
    handler,
    config.host,
    config.port,
    securityContext: ctx,
  );

  final scheme = tlsEnabled ? 'https' : 'http';
  log.info(
    'rainbow-stub listening on $scheme://${server.address.host}:${server.port}',
  );

  ProcessSignal.sigint.watch().listen((_) async {
    log.info('SIGINT — shutting down');
    await server.close(force: true);
    await app.shutdown();
    exit(0);
  });
}

Future<bool> _autoGenerateCert({
  required String certPath,
  required String keyPath,
  required String publicHost,
  required Logger log,
}) async {
  await Directory(File(certPath).parent.path).create(recursive: true);
  try {
    final result = await Process.run('openssl', [
      'req',
      '-x509',
      '-newkey',
      'rsa:2048',
      '-keyout',
      keyPath,
      '-out',
      certPath,
      '-days',
      '825',
      '-nodes',
      '-subj',
      '/CN=$publicHost/O=rainbow-stub/C=US',
      '-addext',
      'subjectAltName=DNS:$publicHost,DNS:localhost,'
          'IP:127.0.0.1,IP:10.0.2.2',
    ]);
    if (result.exitCode != 0) {
      log.warning('openssl failed: ${result.stderr}');
      return false;
    }
    log.info('generated self-signed cert at $certPath');
    return true;
  } on ProcessException catch (e) {
    log.warning('openssl not on PATH — TLS auto-gen skipped: ${e.message}');
    return false;
  }
}

String? _argValue(List<String> args, String name) {
  for (var i = 0; i < args.length; i++) {
    if (args[i] == name && i + 1 < args.length) return args[i + 1];
    if (args[i].startsWith('$name=')) return args[i].substring(name.length + 1);
  }
  return null;
}
