import 'package:shelf/shelf.dart';
import 'package:shelf_router/shelf_router.dart';

import '../auth/auth_service.dart';
import '../util/errors.dart';
import '../util/json.dart';
import 'push_token_repository.dart';

/// REST endpoints for APNs/FCM device tokens. Scoped to the caller —
/// you can only see/mutate your own tokens.
Router pushRouter({
  required AuthService auth,
  required PushTokenRepository tokens,
}) {
  final r = Router();

  // GET /api/rainbow/enduser/v1.0/users/:userId/push-tokens
  r.get('/api/rainbow/enduser/v1.0/users/<userId>/push-tokens', (
    Request req,
    String userId,
  ) {
    final me = auth.authenticateBearer(req.headers['authorization']);
    if (me.id != userId) throw RainbowError.forbidden();
    final list = tokens.findForUser(userId);
    return jsonOk({
      'data': list.map((t) => t.toJson()).toList(),
      'total': list.length,
    });
  });

  // POST /api/rainbow/enduser/v1.0/users/:userId/push-tokens
  //   body: { "token": "…", "platform": "ios|android|web|debug" }
  r.post('/api/rainbow/enduser/v1.0/users/<userId>/push-tokens', (
    Request req,
    String userId,
  ) async {
    final me = auth.authenticateBearer(req.headers['authorization']);
    if (me.id != userId) throw RainbowError.forbidden();
    final body = await readJsonBody(req);
    final token = (body['token'] as String?)?.trim() ?? '';
    final platform = (body['platform'] as String?)?.trim() ?? '';
    if (token.isEmpty) throw RainbowError.badRequest('token is required');
    if (!_platforms.contains(platform)) {
      throw RainbowError.badRequest(
        'platform must be one of ${_platforms.join(', ')}',
      );
    }
    tokens.upsert(userId: userId, token: token, platform: platform);
    return jsonOk({
      'data': {'userId': userId, 'token': token, 'platform': platform},
    }, status: 201);
  });

  // DELETE /api/rainbow/enduser/v1.0/users/:userId/push-tokens/:token
  r.delete('/api/rainbow/enduser/v1.0/users/<userId>/push-tokens/<token>', (
    Request req,
    String userId,
    String token,
  ) {
    final me = auth.authenticateBearer(req.headers['authorization']);
    if (me.id != userId) throw RainbowError.forbidden();
    tokens.delete(userId: userId, token: Uri.decodeComponent(token));
    return jsonOk({'status': 'deleted', 'token': token});
  });

  return r;
}

const _platforms = {'ios', 'android', 'web', 'debug'};
