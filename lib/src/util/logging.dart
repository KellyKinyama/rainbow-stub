import 'dart:convert';

import 'package:logging/logging.dart';

/// Emits log records as NDJSON — one JSON object per line — for easy
/// ingestion by log aggregators (Loki, Elastic, Cloud Logging).
///
/// If a caller passes a `Map<String, Object?>` as the LogRecord's error slot,
/// its fields are merged into the top-level object for structured search.
Logger initJsonLogging({Level level = Level.INFO}) {
  Logger.root.level = level;
  Logger.root.onRecord.listen(_writeJson);
  return Logger('rainbow-stub');
}

Logger initTextLogging({Level level = Level.INFO}) {
  Logger.root.level = level;
  Logger.root.onRecord.listen((r) {
    final err = r.error != null ? ' err=${r.error}' : '';
    // ignore: avoid_print
    print(
      '${r.time.toIso8601String()} '
      '${r.level.name.padRight(7)} '
      '${r.loggerName.padRight(18)} '
      '${r.message}$err',
    );
    if (r.stackTrace != null) {
      // ignore: avoid_print
      print(r.stackTrace);
    }
  });
  return Logger('rainbow-stub');
}

/// Default = JSON. Callers wanting the pretty format opt in via
/// [initTextLogging].
Logger initLogging({Level level = Level.INFO}) => initJsonLogging(level: level);

void _writeJson(LogRecord r) {
  final base = <String, Object?>{
    'ts': r.time.toUtc().toIso8601String(),
    'level': r.level.name,
    'logger': r.loggerName,
    'message': r.message,
  };
  final err = r.error;
  if (err is Map<String, Object?>) {
    base.addAll(err);
  } else if (err != null) {
    base['error'] = err.toString();
  }
  if (r.stackTrace != null) {
    base['stack'] = r.stackTrace.toString();
  }
  // ignore: avoid_print
  print(jsonEncode(base));
}
