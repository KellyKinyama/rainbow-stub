import 'package:shelf/shelf.dart';
import 'package:shelf_router/shelf_router.dart';

import '../auth/auth_service.dart';
import '../util/errors.dart';
import '../util/json.dart';
import 'calllog_repository.dart';

Router callLogRouter({
  required AuthService auth,
  required CallLogRepository log,
}) {
  final r = Router();
  const base = '/api/rainbow/enduser/v1.0/users';

  // GET /users/<userId>/calllogs
  r.get('$base/<userId>/calllogs', (Request req, String userId) {
    final me = auth.authenticateBearer(req.headers['authorization']);
    if (userId != me.id) throw RainbowError.forbidden();
    final q = req.requestedUri.queryParameters;
    final offset = int.tryParse(q['offset'] ?? '') ?? 0;
    final limit = int.tryParse(q['limit'] ?? '') ?? 100;
    final list = log.listFor(me.id, offset: offset, limit: limit);
    return jsonOk({
      'data': list.map((e) => e.toRainbowJson()).toList(),
      'total': list.length,
      'unreadMissed': log.countMissed(me.id),
      'offset': offset,
      'limit': limit,
    });
  });

  // DELETE /users/<userId>/calllogs/<id>
  r.delete('$base/<userId>/calllogs/<id>', (
    Request req,
    String userId,
    String id,
  ) {
    final me = auth.authenticateBearer(req.headers['authorization']);
    if (userId != me.id) throw RainbowError.forbidden();
    log.deleteOne(me.id, id);
    return jsonOk({'status': 'deleted', 'id': id});
  });

  // DELETE /users/<userId>/calllogs
  r.delete('$base/<userId>/calllogs', (Request req, String userId) {
    final me = auth.authenticateBearer(req.headers['authorization']);
    if (userId != me.id) throw RainbowError.forbidden();
    log.deleteAll(me.id);
    return jsonOk({'status': 'deleted'});
  });

  // PUT /users/<userId>/calllogs/<id>/read
  r.put('$base/<userId>/calllogs/<id>/read', (
    Request req,
    String userId,
    String id,
  ) {
    final me = auth.authenticateBearer(req.headers['authorization']);
    if (userId != me.id) throw RainbowError.forbidden();
    log.markRead(me.id, id);
    return jsonOk({'status': 'ok'});
  });

  return r;
}
