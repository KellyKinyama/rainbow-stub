// Seeds the local DB with demo users so you can log in immediately.
//   alice@rainbow-stub.local / password  → primary demo account
//   bob, carol, dave, eve                → roster contacts of alice
//
// Usage:  dart run tool/seed.dart
import 'package:rainbow_stub/rainbow_stub.dart';

Future<void> main() async {
  final log = initLogging();
  final config = await Config.load('config/rainbow-stub.yaml');
  final app = await RainbowStubApp.boot(config);

  const password = 'password';
  final seeds = <(String email, String first, String last, String presence)>[
    ('alice@rainbow-stub.local', 'Alice', 'Sample', 'online'),
    ('bob@rainbow-stub.local', 'Bob', 'Marley', 'online'),
    ('carol@rainbow-stub.local', 'Carol', 'Danvers', 'away'),
    ('dave@rainbow-stub.local', 'Dave', 'Grohl', 'dnd'),
    ('eve@rainbow-stub.local', 'Eve', 'Polastri', 'offline'),
  ];

  final ids = <String, String>{};
  for (final (email, first, last, show) in seeds) {
    final existing = app.users.findByEmail(email);
    final user =
        existing ??
        app.users.create(
          loginEmail: email,
          password: password,
          firstName: first,
          lastName: last,
        );
    ids[email] = user.id;
    app.presence.set(user.id, show);
    if (existing == null) {
      log.info('created ${user.id} $email');
    }
  }

  // Alice's roster = everyone else.
  final aliceId = ids['alice@rainbow-stub.local']!;
  for (final MapEntry(:key, :value) in ids.entries) {
    if (value == aliceId) continue;
    if (!app.roster.exists(aliceId, value)) {
      app.roster.add(aliceId, value);
      log.info('roster: alice -> $key');
    }
  }

  // Seed a demo bubble owned by Alice with everyone accepted.
  final existingBubbles = app.bubbles.listForUser(aliceId);
  if (existingBubbles.isEmpty) {
    final b = app.bubbles.create(
      ownerId: aliceId,
      name: 'Rainbow Stub Demo',
      topic: 'Chat about the stub server',
    );
    for (final MapEntry(:key, :value) in ids.entries) {
      if (value == aliceId) continue;
      app.bubbles.addMember(b.id, value, status: 'accepted');
      log.info('bubble ${b.id}: added $key');
    }
  }

  // Seed a couple of call-log entries.
  if (app.callLog.listFor(aliceId).isEmpty) {
    final bobId = ids['bob@rainbow-stub.local']!;
    final carolId = ids['carol@rainbow-stub.local']!;
    app.callLog.insert(
      ownerId: aliceId,
      peerJid: '$bobId@localhost',
      peerDisplay: 'Bob Marley',
      direction: 'incoming',
      state: 'answered',
      durationMs: 42000,
    );
    app.callLog.insert(
      ownerId: aliceId,
      peerJid: '$carolId@localhost',
      peerDisplay: 'Carol Danvers',
      direction: 'outgoing',
      state: 'missed',
    );
  }

  log.info('seed complete — login as alice@rainbow-stub.local / password');
  app.db.close();
}
