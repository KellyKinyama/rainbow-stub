import 'package:shelf/shelf.dart';
import 'package:shelf_router/shelf_router.dart';

import '../auth/auth_service.dart';
import '../events/event_pusher.dart';
import '../util/errors.dart';
import '../util/json.dart';
import 'avatar_store.dart';
import 'presence_repository.dart';
import 'roster_repository.dart';
import 'user_model.dart';
import 'user_repository.dart';

Router userRouter({
  required AuthService auth,
  required UserRepository users,
  required RosterRepository roster,
  required PresenceRepository presence,
  required AvatarStore avatars,
  required EventPusher events,
}) {
  final r = Router();

  Map<String, dynamic> serialize(User u) => u.toRainbowJson(
    presence: presence.findOrDefault(u.id).toRainbowJson(),
    hasAvatar: avatars.has(u.id),
  );

  // Roster (must precede generic /users/<id> so "networks" isn't captured).
  r.get('/api/rainbow/enduser/v1.0/users/networks', (Request req) {
    final me = auth.authenticateBearer(req.headers['authorization']);
    final q = req.requestedUri.queryParameters;
    final offset = int.tryParse(q['offset'] ?? '') ?? 0;
    final limit = int.tryParse(q['limit'] ?? '') ?? 100;
    final entries = roster.listFor(me.id, offset: offset, limit: limit);
    final total = roster.countFor(me.id);
    return jsonOk({
      'data': entries
          .map(
            (e) => e.toRainbowJson(
              presence: presence.findOrDefault(e.contact.id).toRainbowJson(),
              hasAvatar: avatars.has(e.contact.id),
            ),
          )
          .toList(),
      'total': total,
      'offset': offset,
      'limit': limit,
    });
  });

  r.post('/api/rainbow/enduser/v1.0/users/networks/<contactId>', (
    Request req,
    String contactId,
  ) {
    final me = auth.authenticateBearer(req.headers['authorization']);
    final contact = users.findById(contactId);
    if (contact == null) {
      throw RainbowError.notFound('Contact not found');
    }
    final entry = roster.add(me.id, contactId);
    final domain = _xmppDomain(req);
    events.pushRosterItem(
      me.id,
      contactJid: '$contactId@$domain',
      name: contact.displayName,
    );
    // Mirror push: the contact's roster.add is symmetric server-side,
    // so surface the same item to the contact's client too. Without
    // this, an incoming chat from the adder shows up as a raw user id.
    events.pushRosterItem(
      contactId,
      contactJid: '${me.id}@$domain',
      name: me.displayName,
    );
    return jsonOk({
      'data': entry.toRainbowJson(
        presence: presence.findOrDefault(contactId).toRainbowJson(),
        hasAvatar: avatars.has(contactId),
      ),
    }, status: 201);
  });

  r.delete('/api/rainbow/enduser/v1.0/users/networks/<contactId>', (
    Request req,
    String contactId,
  ) {
    final me = auth.authenticateBearer(req.headers['authorization']);
    if (!roster.exists(me.id, contactId)) {
      throw RainbowError.notFound('Not in roster');
    }
    roster.remove(me.id, contactId);
    final domain = _xmppDomain(req);
    events.pushRosterRemove(me.id, contactJid: '$contactId@$domain');
    events.pushRosterRemove(contactId, contactJid: '${me.id}@$domain');
    return jsonOk({'status': 'ok'});
  });

  // Search — /users?search=<q>&limit=&offset=
  r.get('/api/rainbow/enduser/v1.0/users', (Request req) {
    auth.authenticateBearer(req.headers['authorization']);
    final q = req.requestedUri.queryParameters;
    final search = (q['search'] ?? q['displayName'] ?? '').trim();
    final offset = int.tryParse(q['offset'] ?? '') ?? 0;
    final limit = int.tryParse(q['limit'] ?? '') ?? 50;
    final results = users.search(search, offset: offset, limit: limit);
    final total = users.countSearch(search);
    return jsonOk({
      'data': results.map(serialize).toList(),
      'total': total,
      'offset': offset,
      'limit': limit,
    });
  });

  // Avatar GET/POST/DELETE — must precede generic /users/<id>.
  r.get('/api/rainbow/enduser/v1.0/users/<id>/avatar', (
    Request req,
    String id,
  ) async {
    auth.authenticateBearer(req.headers['authorization']);
    final blob = await avatars.read(id);
    if (blob == null) throw RainbowError.notFound('No avatar');
    return Response.ok(
      blob.bytes,
      headers: {
        'content-type': blob.mimeType,
        'cache-control': 'private, max-age=60',
        'last-modified': blob.updatedAt.toIso8601String(),
      },
    );
  });

  r.post('/api/rainbow/enduser/v1.0/users/<id>/photo', (
    Request req,
    String id,
  ) async {
    final me = auth.authenticateBearer(req.headers['authorization']);
    if (id != me.id) throw RainbowError.forbidden();
    try {
      final img = await readUploadedImage(req);
      if (!img.mimeType.startsWith('image/')) {
        throw RainbowError.badRequest('Not an image: ${img.mimeType}');
      }
      await avatars.write(me.id, img.bytes, img.mimeType);
    } on FormatException catch (e) {
      throw RainbowError.badRequest(e.message);
    }
    return jsonOk({'data': serialize(me)});
  });

  r.delete('/api/rainbow/enduser/v1.0/users/<id>/photo', (
    Request req,
    String id,
  ) async {
    final me = auth.authenticateBearer(req.headers['authorization']);
    if (id != me.id) throw RainbowError.forbidden();
    await avatars.delete(me.id);
    return jsonOk({'data': serialize(me)});
  });

  // Presence — POST /users/:id/presences (own only for now).
  r.post('/api/rainbow/enduser/v1.0/users/<id>/presences', (
    Request req,
    String id,
  ) async {
    final me = auth.authenticateBearer(req.headers['authorization']);
    if (id != me.id) throw RainbowError.forbidden();
    final body = await readJsonBody(req);
    final show = (body['show'] ?? body['presence']) as String? ?? 'online';
    final status = body['status'] as String?;
    presence.set(me.id, show, status: status);
    return jsonOk({'data': serialize(me)});
  });

  // Generic GET /users/<id> — self OR any known user.
  r.get('/api/rainbow/enduser/v1.0/users/<id>', (Request req, String id) {
    final me = auth.authenticateBearer(req.headers['authorization']);
    final target = id == 'me' ? me : users.findById(id);
    if (target == null) throw RainbowError.notFound('User not found');
    return jsonOk({'data': serialize(target)});
  });

  // PUT /users/<id> (self only).
  r.put('/api/rainbow/enduser/v1.0/users/<id>', (Request req, String id) async {
    final me = auth.authenticateBearer(req.headers['authorization']);
    if (id != me.id) throw RainbowError.forbidden();
    final body = await readJsonBody(req);
    final updated = users.update(
      me.id,
      firstName: body['firstName'] as String?,
      lastName: body['lastName'] as String?,
      nickName: body['nickName'] as String?,
      title: body['title'] as String?,
      jobTitle: body['jobTitle'] as String?,
      language: body['language'] as String?,
    );
    return jsonOk({'data': serialize(updated)});
  });

  return r;
}

/// Derive the XMPP domain from the incoming request host so JIDs match
/// what the client used to connect.
String _xmppDomain(Request req) => req.requestedUri.host;
