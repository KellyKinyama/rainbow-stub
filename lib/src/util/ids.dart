import 'dart:math';
import 'dart:typed_data';

/// Mongo-style 24-hex ObjectId — Rainbow uses these for every entity ID
/// (user id, bubble id, message id, file descriptor id, …). Wire-compat
/// depends on the shape (24 lowercase hex chars).
///
/// Layout: 4B seconds since epoch + 5B random per-process + 3B counter.
class ObjectIdGen {
  ObjectIdGen() {
    final r = Random.secure();
    _random = Uint8List.fromList(List.generate(5, (_) => r.nextInt(256)));
    _counter = Random.secure().nextInt(0xFFFFFF);
  }

  late final Uint8List _random;
  int _counter = 0;

  String next() {
    final ts = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final bytes = Uint8List(12);
    bytes[0] = (ts >> 24) & 0xFF;
    bytes[1] = (ts >> 16) & 0xFF;
    bytes[2] = (ts >> 8) & 0xFF;
    bytes[3] = ts & 0xFF;
    bytes.setRange(4, 9, _random);
    _counter = (_counter + 1) & 0xFFFFFF;
    bytes[9] = (_counter >> 16) & 0xFF;
    bytes[10] = (_counter >> 8) & 0xFF;
    bytes[11] = _counter & 0xFF;
    final buf = StringBuffer();
    for (final b in bytes) {
      buf.write(b.toRadixString(16).padLeft(2, '0'));
    }
    return buf.toString();
  }
}

/// 40-char lowercase hex — matches Rainbow's opaque bearer token shape.
String newBearerToken() {
  final r = Random.secure();
  final buf = StringBuffer();
  for (var i = 0; i < 20; i++) {
    buf.write(r.nextInt(256).toRadixString(16).padLeft(2, '0'));
  }
  return buf.toString();
}
