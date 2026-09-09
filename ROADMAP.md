# Roadmap

Where the rainbow-stub + rainbow_stub_consumer effort is going. Grouped
by ROI so you can pick a next task without re-reasoning about priority
each time.

- **Estimate legend:** S ≈ under a day · M ≈ 1–3 days · L ≈ 3–7 days · XL ≈ multi-week
- **Status legend:** ✅ done · 🟡 partial · ⬜ open · 🕒 deferred

Last updated: **2026-09-09**.

---

## Where we are today

- **Server** — `rainbow-stub` at commit `09df0a8` on `main`:
  - Phase 0–4 REST surface (auth, users, roster, presence, avatars, bubbles, files, call-log)
  - XMPP-over-WS with SASL PLAIN, resource binding, SM, carbons, MAM+RSM, MUC light, disco, ping, receipts
  - Hardening (stanza size, queue caps, session caps, keepalive, SmRegistry per-user cap, XXE guard, HSTS + OWASP headers)
  - Observability (JSON logs, Prometheus `/metrics`, auto-generated TLS)
  - **41 tests**, all green
- **Client** — `rainbow_stub_consumer` at commit `809bc25` on `main`:
  - REST + XMPP-WS wiring, presence-aware contacts, 1:1 chat, bubbles, MUC join
  - Windows + Web build targets working; Android not yet added
  - 3 unit + 3 integration tests
- **UAT** — [UAT.md](UAT.md), 2026-09-09, pass, 14 HTTP requests, 0 errors

---

## 1. Highest ROI — closes UAT gaps

### 1.1 · 1:1 and group chat end-to-end test (S) — ⬜

- **What:** Two `RainbowXmppClient` instances (alice + bob) in one Dart test; alice sends `<message type="chat">`; bob receives it; assert body + `from`.
- **Where:** New `test/xmpp_chat_e2e_test.dart` in the Flutter project (or, if pure REST/WS is enough, in the stub project).
- **Acceptance:** Green on `flutter test` when the stub is running; skipped otherwise. Same test also covers `type="groupchat"` to a bubble both users are members of.
- **Depends on:** nothing.
- **Closes:** the "not exercised" note in [UAT.md § 6](UAT.md#6-areas-not-exercised-in-this-uat).

### 1.2 · File upload/download UI (M) — ⬜

- **What:** File picker in the chat composer → multipart `POST /fileServer/v1.0/files` → attach the descriptor id to the outgoing message → render as a card in the chat with a download button.
- **Where:** New `lib/rainbow/files_client.dart`, new `FileMessage` model, `ChatComposer` widget, tweaks to `ChatPage` / `BubbleChatPage`.
- **Acceptance:** Alice picks a PDF from disk, it shows up in Bob's session as a downloadable card. `FileAttachFinished` push event received in the UI (already fires server-side).
- **Depends on:** nothing.

### 1.3 · Local message persistence (M) — ⬜

- **What:** SQLite-backed thread cache. On login, replay the last N messages from disk **and** fire an XMPP MAM `<query>` for anything newer.
- **Where:** New `lib/data/message_store.dart` using `sqflite`; hooked from `RainbowSession._handleIncomingMessage` and MAM response handling.
- **Acceptance:** Kill and relaunch the app; chats persist. Adding a message on device A appears on device B after login without losing history.
- **Depends on:** MAM UI wiring (currently only `xmpp_client.dart` speaks MAM; the session never queries it).

---

## 2. Wire compat + surface completeness

### 2.1 · React Native Rainbow sample end-to-end (M–L) — ⬜

- **What:** Point the unmodified [`react-native-rainbow-module`](../../node/Rainbow-React-Native-Samples) sample at the stub on an Android emulator; drive Login → Contacts → Chat → Bubbles → File share; fix each wire-compat gap the native SDK complains about; land a regression test on the stub for every gap.
- **Where:** Almost all fixes will be in `c:\www\dart\rainbow-stub` — endpoint shapes, header casings, field names.
- **Acceptance:** RN sample logs in as alice, shows all 4 roster contacts with correct presence, sends and receives a 1:1 message, joins the seed bubble, sends a group message. Each fix has a matching `test/` entry.
- **Depends on:** Android emulator + rooted image for cert install (see [RUNBOOK § 4c](RUNBOOK.md#4c-android-emulator)).
- **Blocks:** advertising the stub as "wire-compatible with the real Rainbow backend" publicly.

### 2.2 · Registration + Forgot-password screens (S) — ⬜

- **What:** UI over the stub's `/self-register/*` and `/reset-password/*` endpoints, which are already tested (Phase 1).
- **Where:** `lib/ui/register_page.dart`, `lib/ui/forgot_password_page.dart`; small `AuthGate` change to route to them from the login screen.
- **Acceptance:** Cold-boot user, tap "Register", complete self-register (email → token → account creation), land on login screen with the new email pre-filled.

### 2.3 · User profile / settings screen (M) — ⬜

- **What:** Read/write `/users/:id` (already `PUT`-supported by the server). Change password via the reset-password flow. Avatar upload via existing `/users/:id/photo`.
- **Where:** `lib/ui/profile_page.dart`, new `RainbowSession.updateMe(...)` methods.
- **Acceptance:** Edit displayName / jobTitle → save → re-open, values persisted. Upload a JPG → avatar changes across all sessions of the user.

---

## 3. Server hardening & prod-readiness

### 3.1 · REST rate limiting (S) — ⬜

- **What:** Per-IP token bucket in front of `/login` (default 10 req/s, burst 20) + a low ceiling on `/self-register/send-email` and `/reset-password/send-email`.
- **Where:** New `lib/src/util/rate_limiter.dart`, `Middleware _rateLimit(...)` in `app.dart`.
- **Acceptance:** 21 rapid `/login` posts from one IP → 21st returns `429`. Metric `rainbow_stub_http_ratelimited_total{path,ip}` counts drops.
- **Depends on:** nothing.
- **Closes:** the only remaining item in [the last hardening batch's "not addressed" list](../../dart/rainbow-stub/README.md).

### 3.2 · Docker compose bring-up (S) — 🟡

- **What:** Validate the existing [docker/Dockerfile](docker/Dockerfile). Add a `HEALTHCHECK curl -fk https://localhost:8443/health || exit 1`. Confirm `docker compose up` boots to healthy in < 30 s.
- **Where:** `docker/Dockerfile`, `docker/docker-compose.yml`.
- **Acceptance:** Cold `docker compose up -d`; `docker ps` shows healthy after ~15 s; `curl -sk https://localhost:8443/health` returns 200 from the host.
- **Depends on:** Docker Desktop.

### 3.3 · GitHub Actions CI (S) — ⬜

- **What:** Two workflows — one per repo — running `dart analyze` + `dart test` and `flutter analyze` + `flutter test`. Coverage badge in the README.
- **Where:** `.github/workflows/dart.yml`, `.github/workflows/flutter.yml`.
- **Acceptance:** Push to `main` triggers a green run within 3 min per repo.
- **Depends on:** git remote configured.

---

## 4. Nice-to-haves

### 4.1 · XEP-0308 message correction (M) — ⬜

- **What:** Server: forward `<replace id="orig">` payload; update the stored message in the messages table. Client: long-press → edit; render corrected messages with an "edited" badge.
- **Acceptance:** Alice edits a sent message; Bob's UI updates in place without duplicate bubbles.

### 4.2 · XEP-0198 SM in the Flutter client (M) — ⬜

- **What:** After bind, send `<enable resume="true"/>`; track `hIn`/`hOut`; on WS drop, reconnect and send `<resume previd=… h=…/>`.
- **Where:** `lib/rainbow/xmpp_client.dart`.
- **Acceptance:** Toggle the OS wifi off/on mid-chat; messages resume delivery without a full re-login. Server's `SmRegistry.claim()` returns non-null on the resume.
- **Depends on:** nothing; server support already lives in [lib/src/xmpp/session.dart](lib/src/xmpp/session.dart).

### 4.3 · Dark mode / theme toggle (S) — ⬜

- **What:** Add `ThemeMode` state to `RainbowSession`; wire from the profile menu.
- **Acceptance:** Setting persists across app restarts (SharedPreferences).

### 4.4 · Android target (M) — ⬜

- **What:** `flutter create --platforms=android .` in the consumer; add `--dart-define=RAINBOW_HOST=10.0.2.2` support in `AppConfig.dev`; document cert-trust flow (already partially in [RUNBOOK § 4c](RUNBOOK.md#4c-android-emulator)).
- **Acceptance:** Login screen renders on an Android emulator hitting the host-machine stub.

---

## 5. Deferred bigger blocks

### 5.1 · SIP / Asterisk WebRTC calling (XL) — 🕒

- **Original phase 5** of the roadmap. The [`dart-pbx`](../../dart-pbx) and [`dart-ari`](../../dart-ari) projects are ready to plug into.
- **Deferred** by user request until higher-ROI XMPP work landed. Reopen when a specific call-flow requirement drives it.

### 5.2 · Server-to-server federation (XL) — 🕒

- XEP-0220 dialback across two rainbow-stub instances. Only worth doing if a multi-tenant / multi-server demo is on the horizon.

### 5.3 · Push notifications (L) — 🕒

- Offline delivery via FCM/APNs, proxied by the stub. Requires per-device token registration + native SDK integration on Flutter.

---

## 6. What's already done — quick history

For context, the biggest chunks already shipped:

| Phase | Highlights | Tests |
|---|---|---|
| ✅ Phase 0 | Scaffold, Docker, `/health`, CI-ready structure | — |
| ✅ Phase 1 | Auth REST (login, logout, renew, self-register, reset-password) | 5 |
| ✅ Phase 2 | Users, roster, avatars, presence | 6 |
| ✅ Phase 3 | XMPP-over-WS: SASL, binding, 1:1 chat, presence, MAM, chat states | 4 |
| ✅ Phase 4 | Bubbles, files, call-log, XMPP push events | 5 |
| ✅ Phase 5-XMPP | Ping, disco, roster IQ, presence probe, MUC light, receipts | 7 |
| ✅ Batch | XEP-0198 SM (enable/ack/resume), XEP-0280 carbons, bubble MAM, XEP-0313 RSM | 7 |
| ✅ Hardening | Stanza size, queue caps, session caps, keepalive, SASL cap, MAM auth | 3 |
| ✅ Observability | TLS auto-gen + HSTS, JSON structured logs, Prometheus `/metrics`, XXE guard | 4 |
| ✅ Flutter consumer | REST + XMPP-WS client, Login/Contacts/Bubbles/Chat UI, Windows + Web | 3 unit + 3 integ |
| ✅ Runbook | [RUNBOOK.md](RUNBOOK.md) + [UAT.md](UAT.md) | — |

Total: **~41 stub tests + 6 consumer tests, 0 errors on UAT, 2 git repos on `main`**.

---

## 7. My picks if you only do one thing next

- **Fastest visible win:** [§ 1.1 chat E2E test](#11--11-and-group-chat-end-to-end-test-s--) (S)
- **Most impressive stack exercise:** [§ 1.2 file upload UI](#12--file-uploaddownload-ui-m--) (M)
- **Biggest strategic milestone:** [§ 2.1 RN sample end-to-end](#21--react-native-rainbow-sample-end-to-end-ml--) (M–L)

If in doubt, do § 1.1 — it costs almost nothing and moves "chat works" from anecdote to CI-enforced.
