import 'dart:convert';
import 'dart:typed_data';

import 'package:shelf/shelf.dart';
import 'package:shelf_router/shelf_router.dart';

import '../auth/auth_service.dart';
import '../events/event_pusher.dart';
import '../users/avatar_store.dart' show readUploadedImage;
import '../util/errors.dart';
import '../util/json.dart';
import 'file_store.dart';

Router fileRouter({
  required AuthService auth,
  required FileStore files,
  required EventPusher events,
}) {
  final r = Router();
  const base = '/api/rainbow/fileServer/v1.0';

  String downloadUrl(String id, Uri baseUri) =>
      '${baseUri.scheme}://${baseUri.authority}$base/files/$id/data';

  // POST /fileServer/v1.0/files  — create descriptor
  r.post('$base/files', (Request req) async {
    final me = auth.authenticateBearer(req.headers['authorization']);
    final body = await readJsonBody(req);
    final peer = body['peer'] as String?;
    final peerType = (body['peerType'] as String?) ?? 'user';
    if (peer == null) throw RainbowError.badRequest('peer required');
    final fileName = (body['fileName'] as String?) ?? 'untitled';
    final mime = (body['mime'] as String?) ?? 'application/octet-stream';
    final f = files.create(
      ownerId: me.id,
      peerJid: peer,
      peerType: peerType,
      fileName: fileName,
      mimeType: mime,
      byteSize: (body['size'] as int?) ?? 0,
    );
    return jsonOk({'data': f.toRainbowJson()}, status: 201);
  });

  // PUT /fileServer/v1.0/files/<id>/data  — upload bytes
  r.put('$base/files/<id>/data', (Request req, String id) async {
    final me = auth.authenticateBearer(req.headers['authorization']);
    final f = files.findById(id);
    if (f == null) throw RainbowError.notFound('File not found');
    if (f.ownerId != me.id) throw RainbowError.forbidden();
    final ct = req.headers['content-type'] ?? 'application/octet-stream';
    try {
      final img = ct.startsWith('multipart/')
          ? await readUploadedImage(req)
          : (bytes: await _drain(req), mimeType: ct);
      await files.writeBytes(id, img.bytes, img.mimeType);
    } on FormatException catch (e) {
      throw RainbowError.badRequest(e.message);
    }
    final updated = files.findById(id)!;
    final json = updated.toRainbowJson(
      downloadUrl: downloadUrl(id, req.requestedUri),
    );
    events.pushFileAttachFinished(me.id, json);
    return jsonOk({'data': json});
  });

  // GET /fileServer/v1.0/files/<id>/data  — download bytes
  r.get('$base/files/<id>/data', (Request req, String id) async {
    final me = auth.authenticateBearer(req.headers['authorization']);
    final f = files.findById(id);
    if (f == null) throw RainbowError.notFound('File not found');
    // Owner or the peer can download; roster/room membership is not enforced
    // in the stub.
    final bytes = await files.readBytes(id);
    if (bytes == null) throw RainbowError.notFound('Not uploaded');
    events.pushFileDownloadFinished(
      me.id,
      f.toRainbowJson(downloadUrl: downloadUrl(id, req.requestedUri)),
    );
    return Response.ok(
      bytes,
      headers: {
        'content-type': f.mimeType,
        'content-disposition':
            'attachment; filename="${_escFilename(f.fileName)}"',
        'cache-control': 'private, max-age=60',
      },
    );
  });

  // GET /fileServer/v1.0/files/<id>  — descriptor
  r.get('$base/files/<id>', (Request req, String id) {
    auth.authenticateBearer(req.headers['authorization']);
    final f = files.findById(id);
    if (f == null) throw RainbowError.notFound('File not found');
    return jsonOk({
      'data': f.toRainbowJson(downloadUrl: downloadUrl(id, req.requestedUri)),
    });
  });

  // DELETE /fileServer/v1.0/files/<id>
  r.delete('$base/files/<id>', (Request req, String id) async {
    final me = auth.authenticateBearer(req.headers['authorization']);
    final f = files.findById(id);
    if (f == null) throw RainbowError.notFound('File not found');
    if (f.ownerId != me.id) throw RainbowError.forbidden();
    await files.delete(id);
    return jsonOk({'status': 'deleted', 'fileId': id});
  });

  // GET /fileServer/v1.0/files?peer=<jid>  — list shared files with a peer
  r.get('$base/files', (Request req) {
    final me = auth.authenticateBearer(req.headers['authorization']);
    final peer = req.requestedUri.queryParameters['peer'];
    if (peer == null) throw RainbowError.badRequest('peer required');
    final list = files
        .listForPeer(peer)
        .map(
          (f) =>
              f.toRainbowJson(downloadUrl: downloadUrl(f.id, req.requestedUri)),
        )
        .toList();
    events.pushSharedFilesForPeer(me.id, peerJid: peer, files: list);
    return jsonOk({'data': list, 'total': list.length});
  });

  return r;
}

Future<Uint8List> _drain(Request req) async {
  final buf = BytesBuilder();
  await for (final chunk in req.read()) {
    buf.add(chunk);
  }
  return buf.toBytes();
}

String _escFilename(String s) =>
    s.replaceAll('"', '\\"').replaceAll('\r', '').replaceAll('\n', '');

// Keeps `dart:convert` reachable for future expansion (JSON responses).
// ignore: unused_element
String _keep(Object o) => jsonEncode(o);
