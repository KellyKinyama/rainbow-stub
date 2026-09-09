import 'package:shelf/shelf.dart';
import 'package:shelf_router/shelf_router.dart';

import '../auth/auth_service.dart';
import '../events/event_pusher.dart';
import '../users/user_repository.dart';
import '../util/errors.dart';
import '../util/json.dart';
import 'bubble_repository.dart';

Router bubbleRouter({
  required AuthService auth,
  required UserRepository users,
  required BubbleRepository bubbles,
  required EventPusher events,
}) {
  final r = Router();

  Map<String, dynamic> serialize(String bubbleId) {
    final b = bubbles.findById(bubbleId)!;
    return bubbles.bubbleToRainbowJson(b, bubbles.membersOf(bubbleId));
  }

  // GET /rooms — bubbles the caller is a member of
  r.get('/api/rainbow/enduser/v1.0/rooms', (Request req) {
    final me = auth.authenticateBearer(req.headers['authorization']);
    final list = bubbles.listForUser(me.id);
    return jsonOk({
      'data': list.map((b) => serialize(b.id)).toList(),
      'total': list.length,
    });
  });

  // GET /rooms/invitations — pending invitations for the caller
  r.get('/api/rainbow/enduser/v1.0/rooms/invitations', (Request req) {
    final me = auth.authenticateBearer(req.headers['authorization']);
    final list = bubbles.listInvitedFor(me.id);
    return jsonOk({
      'data': list.map((b) => serialize(b.id)).toList(),
      'total': list.length,
    });
  });

  // POST /rooms — create bubble
  r.post('/api/rainbow/enduser/v1.0/rooms', (Request req) async {
    final me = auth.authenticateBearer(req.headers['authorization']);
    final body = await readJsonBody(req);
    final name = (body['name'] ?? body['displayName']) as String?;
    if (name == null || name.isEmpty) {
      throw RainbowError.badRequest('name is required');
    }
    final b = bubbles.create(
      ownerId: me.id,
      name: name,
      topic: body['topic'] as String?,
      visibility: (body['visibility'] as String?) ?? 'private',
    );
    final json = serialize(b.id);
    events.pushBubblesListUpdated(me.id, [json]);
    return jsonOk({'data': json}, status: 201);
  });

  // PUT /rooms/<id>
  r.put('/api/rainbow/enduser/v1.0/rooms/<id>', (Request req, String id) async {
    final me = auth.authenticateBearer(req.headers['authorization']);
    final b = bubbles.findById(id);
    if (b == null) throw RainbowError.notFound('Bubble not found');
    final member = bubbles.memberOf(id, me.id);
    if (member == null || member.role == 'user') {
      throw RainbowError.forbidden('Only owner/moderator can update');
    }
    final body = await readJsonBody(req);
    bubbles.update(
      id,
      name: body['name'] as String?,
      topic: body['topic'] as String?,
      visibility: body['visibility'] as String?,
      archived: body['isArchived'] as bool?,
    );
    final json = serialize(id);
    for (final m in bubbles.membersOf(id)) {
      if (m.status == 'accepted') events.pushOnBubbleUpdated(m.userId, json);
    }
    if (body['isArchived'] == true) {
      events.pushBubbleArchived(me.id, id);
    }
    return jsonOk({'data': json});
  });

  // DELETE /rooms/<id>
  r.delete('/api/rainbow/enduser/v1.0/rooms/<id>', (Request req, String id) {
    final me = auth.authenticateBearer(req.headers['authorization']);
    final b = bubbles.findById(id);
    if (b == null) throw RainbowError.notFound('Bubble not found');
    if (b.ownerId != me.id) {
      throw RainbowError.forbidden('Only owner can delete');
    }
    final memberIds = bubbles.membersOf(id).map((m) => m.userId).toList();
    bubbles.delete(id);
    for (final uid in memberIds) {
      events.pushBubbleDeleted(uid, id);
    }
    return jsonOk({'status': 'deleted', 'bubbleId': id});
  });

  // POST /rooms/<id>/users  — invite user by { userId | loginEmail }
  r.post('/api/rainbow/enduser/v1.0/rooms/<id>/users', (
    Request req,
    String id,
  ) async {
    final me = auth.authenticateBearer(req.headers['authorization']);
    final b = bubbles.findById(id);
    if (b == null) throw RainbowError.notFound('Bubble not found');
    final actor = bubbles.memberOf(id, me.id);
    if (actor == null || actor.role == 'user') {
      throw RainbowError.forbidden('Only owner/moderator can invite');
    }
    final body = await readJsonBody(req);
    var targetId = body['userId'] as String?;
    final email = body['loginEmail'] as String?;
    if (targetId == null && email != null) {
      final u = users.findByEmail(email);
      if (u == null) throw RainbowError.notFound('User not found');
      targetId = u.id;
    }
    if (targetId == null) {
      throw RainbowError.badRequest('userId or loginEmail required');
    }
    bubbles.addMember(id, targetId, role: 'user', status: 'invited');
    final json = serialize(id);
    events.pushBubbleInvitation(targetId, json);
    return jsonOk({'data': json}, status: 201);
  });

  // PUT /rooms/<id>/users/<userId>  — status transitions (accept/decline/leave)
  r.put('/api/rainbow/enduser/v1.0/rooms/<id>/users/<userId>', (
    Request req,
    String id,
    String userId,
  ) async {
    final me = auth.authenticateBearer(req.headers['authorization']);
    final b = bubbles.findById(id);
    if (b == null) throw RainbowError.notFound('Bubble not found');
    if (userId != me.id && bubbles.memberOf(id, me.id)?.role == 'user') {
      throw RainbowError.forbidden();
    }
    final body = await readJsonBody(req);
    final status = body['status'] as String?;
    if (status == null) {
      throw RainbowError.badRequest('status required');
    }
    bubbles.setStatus(id, userId, status);
    final json = serialize(id);
    // Notify all accepted members.
    for (final m in bubbles.membersOf(id)) {
      if (m.status == 'accepted' || m.userId == userId) {
        events.pushOnBubbleUpdated(m.userId, json);
      }
    }
    return jsonOk({'data': json});
  });

  return r;
}
