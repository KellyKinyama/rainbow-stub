// ignore_for_file: file_names
// Smoke script for the phase-6 XMPP batch: XEP-0198 (SM), XEP-0280 (Carbons),
// bubble MAM, XEP-0313 RSM pagination.
//
// Requires the server running on :8443 with the default seed.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:rainbow_stub/rainbow_stub.dart';
import 'package:web_socket_channel/io.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:xml/xml.dart';

const _domain = 'localhost';
const _appAuth =
    'Basic NjVjNjgxYzAxYzhmMTFlOWFkZDg5MzJiMzU4ZWY4MWQ6VVlkdTN3Q1hUZGZ5akltaFVSbklrWjB0YWM1SjlYU0xzeklLQlJVVVdWQjM1YjZuVDNmV1YyQmhBR2hvamRCUQ==';

Future<void> main() async {
  final log = initLogging();
  log.info('=== xmpp batch smoke: SM + Carbons + MAM(bubble) + RSM ===');

  final aliceLogin = await _restLogin('alice@rainbow-stub.local', 'password');
  final aliceId = (aliceLogin['loggedInUser'] as Map)['id'] as String;
  final aliceToken = aliceLogin['token'] as String;

  // ---- SM enable + ack --------------------------------------------------
  final a1 = await _connect(
    email: 'alice@rainbow-stub.local',
    token: aliceToken,
    resource: 'phone',
  );
  final enableReady = a1.awaitLocal('enabled');
  a1.send('<enable xmlns="urn:xmpp:sm:3" resume="true"/>');
  final enabled = await enableReady.timeout(const Duration(seconds: 3));
  final smid = enabled.getAttribute('id');
  log.info('SM enabled smid=$smid resume=${enabled.getAttribute('resume')}');

  a1.send('<presence/>');
  final ackReady = a1.awaitLocal('a');
  a1.send('<r xmlns="urn:xmpp:sm:3"/>');
  final ack = await ackReady.timeout(const Duration(seconds: 3));
  log.info('SM ack h=${ack.getAttribute('h')}');

  // ---- Carbons ---------------------------------------------------------
  final a2 = await _connect(
    email: 'alice@rainbow-stub.local',
    token: aliceToken,
    resource: 'web',
  );
  final cbnDone = a2.stream.firstWhere(
    (e) => e.localName == 'iq' && e.getAttribute('id') == 'cbn',
  );
  a2.send('<iq type="set" id="cbn"><enable xmlns="urn:xmpp:carbons:2"/></iq>');
  await cbnDone.timeout(const Duration(seconds: 3));
  log.info('carbons enabled on resource=web');

  final bobLogin = await _restLogin('bob@rainbow-stub.local', 'password');
  final bobId = (bobLogin['loggedInUser'] as Map)['id'] as String;

  final carbonReady = a2.stream.firstWhere(
    (e) =>
        e.localName == 'message' &&
        e.getElement('sent', namespace: 'urn:xmpp:carbons:2') != null,
  );
  a1.send(
    '<message id="cb1" to="$bobId@$_domain" type="chat">'
    '<body>carbon me</body></message>',
  );
  final carbon = await carbonReady.timeout(const Duration(seconds: 3));
  final inner = carbon
      .getElement('sent', namespace: 'urn:xmpp:carbons:2')!
      .getElement('forwarded', namespace: 'urn:xmpp:forward:0')!
      .getElement('message', namespace: 'jabber:client')!;
  log.info(
    'carbon received on resource=web: from=${inner.getAttribute('from')} '
    'body=${inner.getElement('body')?.innerText}',
  );

  // ---- Bubble MAM + RSM (paginate the seeded "Rainbow Stub Demo" room) --
  // Fetch a bubble id via REST /rooms.
  final rooms = await _restGet(
    '/api/rainbow/enduser/v1.0/rooms',
    token: aliceToken,
  );
  final bubbles = (rooms['data'] as List).cast<Map<String, dynamic>>();
  if (bubbles.isEmpty) {
    log.warning('no bubbles seeded — MAM(bubble) smoke skipped');
  } else {
    final bubbleId = bubbles.first['id'] as String;
    // Send 4 groupchat messages so we have history.
    for (var i = 1; i <= 4; i++) {
      a1.send(
        '<message id="g$i" to="$bubbleId@muc.$_domain" type="groupchat">'
        '<body>hist $i</body></message>',
      );
    }
    await Future<void>.delayed(const Duration(milliseconds: 200));

    // MAM with RSM max=2 (first page).
    final bodies = <String>[];
    int? count;
    var done = Completer<void>();
    late StreamSubscription sub;
    sub = a1.stream.listen((e) {
      if (e.localName == 'message') {
        final b = e
            .getElement('result', namespace: 'urn:xmpp:mam:2')
            ?.getElement('forwarded', namespace: 'urn:xmpp:forward:0')
            ?.getElement('message', namespace: 'jabber:client')
            ?.getElement('body')
            ?.innerText;
        if (b != null) bodies.add(b);
      } else if (e.localName == 'iq' && e.getAttribute('id') == 'mamB1') {
        count = int.tryParse(
          e
                  .getElement('fin', namespace: 'urn:xmpp:mam:2')
                  ?.getElement(
                    'set',
                    namespace: 'http://jabber.org/protocol/rsm',
                  )
                  ?.getElement('count')
                  ?.innerText ??
              '',
        );
        done.complete();
      }
    });
    a1.send(
      '<iq type="set" id="mamB1">'
      '<query xmlns="urn:xmpp:mam:2">'
      '<x xmlns="jabber:x:data" type="submit">'
      '<field var="with"><value>$bubbleId@muc.$_domain</value></field>'
      '</x>'
      '<set xmlns="http://jabber.org/protocol/rsm"><max>2</max></set>'
      '</query></iq>',
    );
    await done.future.timeout(const Duration(seconds: 3));
    await sub.cancel();
    log.info('bubble MAM page 1 bodies=$bodies total=$count');
  }

  await a1.close();
  await a2.close();

  // ---- SM resume: drop + reconnect + <resume/> --------------------------
  final a3 = await _connect(
    email: 'alice@rainbow-stub.local',
    token: aliceToken,
    resource: 'phone',
  );
  final e3 = a3.awaitLocal('enabled');
  a3.send('<enable xmlns="urn:xmpp:sm:3" resume="true"/>');
  final resumeSmid = (await e3.timeout(
    const Duration(seconds: 3),
  )).getAttribute('id')!;

  // Bob sends message, alice drops before ack.
  final bobToken = bobLogin['token'] as String;
  final bob = await _connect(
    email: 'bob@rainbow-stub.local',
    token: bobToken,
    resource: 'web',
  );
  final firstMsg = a3.awaitLocal('message');
  bob.send(
    '<message id="offline" to="$aliceId@$_domain" type="chat">'
    '<body>while you were dropping</body></message>',
  );
  await firstMsg.timeout(const Duration(seconds: 3));
  await a3.close();
  await Future<void>.delayed(const Duration(milliseconds: 200));

  // Reconnect and resume.
  final ch = IOWebSocketChannel.connect(
    Uri.parse('ws://$_domain:8443/websocket'),
    protocols: ['xmpp'],
  );
  await ch.ready;
  final a4 = _Xmpp(ch);
  await a4.openStream();
  await a4.saslPlain(email: 'alice@rainbow-stub.local', password: aliceToken);
  await a4.openStream();
  final resumedReady = a4.stream.firstWhere(
    (e) => e.localName == 'resumed' || e.localName == 'failed',
  );
  a4.send('<resume xmlns="urn:xmpp:sm:3" h="0" previd="$resumeSmid"/>');
  final resumeResp = await resumedReady.timeout(const Duration(seconds: 3));
  log.info('resume → <${resumeResp.localName}>');
  if (resumeResp.localName == 'resumed') {
    final replay = await a4
        .awaitLocal('message')
        .timeout(const Duration(seconds: 3));
    log.info('replayed after resume: ${replay.getElement('body')?.innerText}');
  }
  await a4.close();
  await bob.close();

  log.info('=== batch smoke DONE ===');
  exit(0);
}

Future<Map<String, dynamic>> _restLogin(String email, String password) async {
  final client = HttpClient();
  try {
    final auth = 'Basic ${base64.encode(utf8.encode('$email:$password'))}';
    final req = await client.getUrl(
      Uri.parse('http://$_domain:8443/api/rainbow/authentication/v1.0/login'),
    );
    req.headers.set('authorization', auth);
    req.headers.set('x-rainbow-app-auth', _appAuth);
    final resp = await req.close();
    if (resp.statusCode != 200) {
      throw StateError('login $email → ${resp.statusCode}');
    }
    return jsonDecode(await resp.transform(utf8.decoder).join())
        as Map<String, dynamic>;
  } finally {
    client.close(force: true);
  }
}

Future<Map<String, dynamic>> _restGet(
  String path, {
  required String token,
}) async {
  final client = HttpClient();
  try {
    final req = await client.getUrl(Uri.parse('http://$_domain:8443$path'));
    req.headers.set('authorization', 'Bearer $token');
    final resp = await req.close();
    if (resp.statusCode != 200) {
      throw StateError('$path → ${resp.statusCode}');
    }
    return jsonDecode(await resp.transform(utf8.decoder).join())
        as Map<String, dynamic>;
  } finally {
    client.close(force: true);
  }
}

Future<_Xmpp> _connect({
  required String email,
  required String token,
  required String resource,
}) async {
  final channel = IOWebSocketChannel.connect(
    Uri.parse('ws://$_domain:8443/websocket'),
    protocols: ['xmpp'],
  );
  await channel.ready;
  final c = _Xmpp(channel);
  await c.openStream();
  await c.saslPlain(email: email, password: token);
  await c.openStream();
  await c.bind(resource);
  return c;
}

class _Xmpp {
  _Xmpp(this._channel) {
    _sub = _channel.stream.listen((raw) {
      final text = raw is List<int> ? utf8.decode(raw) : raw as String;
      try {
        _controller.add(XmlDocument.parse(text).rootElement);
      } on XmlException {
        // ignore
      }
    }, onDone: () => _controller.isClosed ? null : _controller.close());
  }

  final WebSocketChannel _channel;
  late final StreamSubscription _sub;
  final _controller = StreamController<XmlElement>.broadcast();
  String jid = '';

  Stream<XmlElement> get stream => _controller.stream;

  void send(String s) => _channel.sink.add(s);

  Future<XmlElement> awaitLocal(String localName) =>
      stream.firstWhere((e) => e.localName == localName);

  Future<void> openStream() async {
    final ready = stream.firstWhere(
      (e) => e.localName == 'features' || e.localName == 'stream:features',
    );
    send(
      '<open xmlns="urn:ietf:params:xml:ns:xmpp-framing" to="$_domain" '
      'version="1.0"/>',
    );
    await ready.timeout(const Duration(seconds: 5));
  }

  Future<void> saslPlain({
    required String email,
    required String password,
  }) async {
    final ready = stream.firstWhere(
      (e) => e.localName == 'success' || e.localName == 'failure',
    );
    final payload = base64.encode(utf8.encode('\u0000$email\u0000$password'));
    send(
      '<auth xmlns="urn:ietf:params:xml:ns:xmpp-sasl" '
      'mechanism="PLAIN">$payload</auth>',
    );
    final r = await ready.timeout(const Duration(seconds: 5));
    if (r.localName != 'success') {
      throw StateError('SASL failed: ${r.toXmlString()}');
    }
  }

  Future<void> bind(String resource) async {
    final ready = stream.firstWhere(
      (e) => e.localName == 'iq' && e.getAttribute('type') == 'result',
    );
    send(
      '<iq type="set" id="bind1">'
      '<bind xmlns="urn:ietf:params:xml:ns:xmpp-bind">'
      '<resource>$resource</resource></bind></iq>',
    );
    final iq = await ready.timeout(const Duration(seconds: 5));
    jid = iq.findAllElements('jid').first.innerText;
  }

  Future<void> close() async {
    await _sub.cancel();
    if (!_controller.isClosed) await _controller.close();
    await _channel.sink.close();
  }
}
