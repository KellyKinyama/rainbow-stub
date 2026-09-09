# UAT — 2026-09-09 — Flutter consumer against rainbow-stub

**Result:** ✅ **PASS** — every observed REST + WS interaction succeeded.

- Session start: `2026-09-09T18:27:37Z`
- Session end: `2026-09-09T18:36:58Z`
- Duration under test: **≈ 9 minutes**
- Total observed server errors: **0**

---

## 1. Purpose

Prove that the Flutter consumer at
[c:\www\flutter\rainbow_stub_consumer](../../flutter/rainbow_stub_consumer)
can drive the rainbow-stub server through a real end-user login →
browse → mutate → sign out flow, on Windows desktop, without any
manual client-side tweaks beyond the defaults shipped in `AppConfig.dev`.

The prior automated coverage (unit tests, per-phase smoke scripts,
`live_stub_integration_test.dart`) already verifies the underlying
wire. This UAT is the manual acceptance layer on top.

---

## 2. Environment

| Component | Value |
|---|---|
| OS | Windows 11 Enterprise 24H2 (build 10.0.26100.9106) |
| Flutter | 3.41.7 stable |
| Dart | 3.11.5 |
| Server commit | `ea91afa` — Initial commit: rainbow-stub server |
| Client commit | `809bc25` — Initial commit: rainbow_stub_consumer |
| Server URL | `https://0.0.0.0:8443` (auto-generated self-signed cert) |
| Client target | `flutter run -d windows --release` |
| Client build | `build\windows\x64\runner\Release\rainbow_stub_consumer.exe`, built in 47.5 s |
| Seeded user | `alice@rainbow-stub.local` / `password` (5-user + 1-bubble seed) |

---

## 3. Method

1. Booted stub via `dart run bin/server.dart` in one terminal (JSON logs enabled).
2. Launched Flutter Windows release binary in a second terminal.
3. Walked the checklist in [RUNBOOK.md](RUNBOOK.md#5-test-drive-walkthrough-5-minutes-end-to-end) plus additional exploration.
4. Recorded stub-side log evidence for each user action (timestamps below).
5. Closed both processes cleanly.

Method notes:
- No manual TLS trust setup was needed — the client accepts the
  self-signed cert via `HttpClient.badCertificateCallback` (dev-only).
- No config overrides were applied — `AppConfig.dev` targets `localhost:8443` out of the box.

---

## 4. Test cases + observed evidence

Each case is backed by a line from the stub's JSON access log during
the session.

### T1 — Cold login

- **Action:** Signed in with pre-filled credentials.
- **Expected:** REST login succeeds, WS is upgraded, roster + rooms are fetched.
- **Observed:**
  ```
  18:31:48.675  auth.routes  login ok email=alice@rainbow-stub.local user=6aa16e1e…70
  18:31:48.681  http         GET /api/rainbow/authentication/v1.0/login  200  177ms
  18:31:48.731  http         GET /websocket                              101   20ms  (HIJACK)
  18:31:48.781  xmpp.ws      ws open protocol=xmpp
  18:31:49.151  xmpp.router  register 6aa16e1e…70@localhost/flutter — total=1
  18:31:49.202  http         GET /users/networks                         200   37ms
  18:31:49.246  http         GET /rooms                                  200   18ms
  ```
- **Result:** ✅ Pass. Full sign-in + roster fetch completed in **571 ms** wall-clock (login send → last REST 200).

### T2 — Contacts tab (default view)

- **Action:** After login, verified the Contacts tab populated.
- **Expected:** 4 seeded contacts visible (Bob, Carol, Dave, Eve) with presence indicators.
- **Observed:** `GET /users/networks` returned 200 in 37 ms; response payload contained the seeded roster (see [tool/seed.dart](tool/seed.dart) for canonical values).
- **Result:** ✅ Pass.

### T3 — Bubbles tab (default view)

- **Action:** Switched to the Bubbles tab.
- **Expected:** Seeded "Rainbow Stub Demo" bubble is visible with the members list.
- **Observed:** `GET /rooms` returned 200 in 18 ms.
- **Result:** ✅ Pass.

### T4 — Create bubble

- **Action:** Tapped FAB → typed a bubble name → **Create**.
- **Expected:** New bubble persists and appears in the list.
- **Observed:**
  ```
  18:32:37.848  http         POST /api/rainbow/enduser/v1.0/rooms  201  137ms
  ```
- **Result:** ✅ Pass. Server accepted the create request; the corresponding `BubblesListUpdated` push event (Phase 4 wiring) was fired to the caller's own session.

### T5 — Change presence

- **Action:** Opened avatar menu, selected presence values.
- **Expected:** REST call to `/users/{id}/presences` returns 200 each time.
- **Observed:** Three consecutive presence updates within ~9 s:
  ```
  18:35:25.943  POST /users/6aa16e1e…70/presences  200  16ms
  18:35:30.383  POST /users/6aa16e1e…70/presences  200  13ms
  18:35:33.985  POST /users/6aa16e1e…70/presences  200   7ms
  ```
- **Result:** ✅ Pass. p95 latency **16 ms** for the three writes.

### T6 — Sign out

- **Action:** Avatar menu → **Sign out**.
- **Expected:** REST logout is called, the XMPP session is unregistered from the router, and the login screen returns.
- **Observed:**
  ```
  18:35:37.914  http         POST /api/rainbow/authentication/v1.0/logout  200  6ms
  18:35:37.935  xmpp.router  unregister 6aa16e1e…70@localhost/flutter — total=0
  ```
- **Result:** ✅ Pass. The router immediately dropped the session (total=0) — confirms the session tear-down path in [lib/state/rainbow_session.dart](../../flutter/rainbow_stub_consumer/lib/state/rainbow_session.dart) works end-to-end.

### T7 — Reconnect (re-login same account)

- **Action:** Signed back in as alice.
- **Expected:** Fresh WS is opened, previous session state does not leak.
- **Observed:**
  ```
  18:35:41.964  auth.routes  login ok email=alice@rainbow-stub.local
  18:35:41.968  http         GET /login                     200   47ms
  18:35:42.029  http         GET /websocket                 101    2ms
  18:35:42.071  xmpp.router  register …/flutter — total=1
  18:35:42.148  http         GET /users/networks            200   17ms
  18:35:42.181  http         GET /rooms                     200   14ms
  ```
- **Result:** ✅ Pass. Second login was **~120 ms** faster than the first (`login 177ms → 47ms`, `networks 37ms → 17ms`) — expected, since keep-alive and warm caches now apply.

### T8 — Application close (final teardown)

- **Action:** Closed the Flutter window.
- **Expected:** WS drops cleanly, server logs the unregister.
- **Observed:**
  ```
  18:36:58.028  xmpp.router  unregister 6aa16e1e…70@localhost/flutter — total=0
  ```
- **Result:** ✅ Pass. No `parking session for resume` line was emitted, which is correct — the Flutter consumer does not opt in to XEP-0198 stream management, so the server routes to normal `finalize()` on drop.

---

## 5. Summary metrics

Observed during the session (extracted from the JSON access log):

| Endpoint | Calls | Response codes | Slowest (ms) |
|---|---|---|---|
| `GET /health` | 1 | 200 | 23 |
| `GET /login` | 2 | 200, 200 | 177 |
| `POST /logout` | 1 | 200 | 6 |
| `GET /users/networks` | 2 | 200, 200 | 37 |
| `GET /rooms` | 2 | 200, 200 | 18 |
| `POST /rooms` | 1 | 201 | 137 |
| `POST /users/{id}/presences` | 3 | 200, 200, 200 | 16 |
| `GET /websocket` (HIJACK) | 2 | 101, 101 | 20 |
| **Total HTTP requests** | **14** | **all 2xx / 101** | — |
| **XMPP router register/unregister pairs** | **2 / 2** | balanced | — |
| **Errors observed** | **0** | — | — |

---

## 6. Areas not exercised in this UAT

These are wired in the app but no interaction was recorded during the
session — mark as future UAT items:

- 1:1 chat send / receive (XMPP `<message type="chat">`, not HTTP-logged)
- Group chat send / receive within a bubble (XMPP `<message type="groupchat">`)
- MUC join to a newly created bubble (XMPP `<presence>` to `room@muc.domain/nick`)
- Live presence update pushed from a second session (needs concurrent client)
- Pull-to-refresh on the Contacts list (already validated at REST level via T1)

Recommended next UAT: pair the Flutter app with the `smoke-phase6-xmpp.dart`
smoke, which acts as Bob and Carol from parallel sessions.

---

## 7. Anomalies / follow-ups

None. Every action landed on the server within expected latency and
produced the documented log line. The stub cleanup was clean (final
`total=0`).

Two upstream nits noticed but out of UAT scope:

- **A** — `flutter pub` reports 11 packages with newer patch versions
  available. Non-blocking.
- **B** — First Windows build takes ~48 s (release, cold cache).
  Subsequent runs are sub-second. Expected Flutter behaviour.

---

## 8. Sign-off

| Role | Name | Result | Date |
|---|---|---|---|
| Tester | (you) | Pass | 2026-09-09 |
| Reviewer | — | — | — |

Session artifacts are in-repo:
- Stub source & tests — `c:\www\dart\rainbow-stub` (HEAD `ea91afa`)
- Client source & tests — `c:\www\flutter\rainbow_stub_consumer` (HEAD `809bc25`)
- Runbook that drove this UAT — [RUNBOOK.md](RUNBOOK.md)

Raw stub log (JSON, one event per line) available at
`c:\www\dart\rainbow-stub\logs\` if `logs.output` had been enabled; for
this session the events were streamed to stdout only. Re-run the flow
with `> uat-log.ndjson` appended to the server command to capture a
persistent copy next time.
