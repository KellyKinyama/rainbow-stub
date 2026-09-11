# Roadmap

Where the rainbow-stub + rainbow_stub_consumer effort is going. Grouped
by ROI so you can pick a next task without re-reasoning about priority
each time.

- **Estimate legend:** S ≈ under a day · M ≈ 1–3 days · L ≈ 3–7 days · XL ≈ multi-week
- **Status legend:** ✅ done · 🟡 partial · ⬜ open · 🕒 deferred

Last updated: **2026-09-11**.

---

## Where we are today

- **Server** — `rainbow-stub` at commit `6a9046b` on `main`:
  - Phase 0–4 REST surface (auth, users, roster, presence, avatars, bubbles, files, call-log, push-tokens)
  - XMPP-over-WS with SASL PLAIN, resource binding, SM (with resume), carbons, MAM+RSM, MUC light, disco, ping, receipts
  - XEP-0166 Jingle passthrough (session-initiate / -accept / -terminate / transport-info), XEP-0424 retract, XEP-0444 reactions, XEP-0308 corrections
  - MUC group-call marker (`urn:rainbow:muc-call:1`) fan-out for bubble-scoped call signaling
  - Hardening (stanza size, queue caps, session caps, keepalive, SmRegistry per-user cap, XXE guard, HSTS + OWASP headers, CORS)
  - Observability (JSON logs, Prometheus `/metrics`, auto-generated TLS)
  - HTTP-only smoke config (`config/rainbow-stub-smoke.yaml`) for real-device runs
  - **41 tests**, all green
- **Client** — `rainbow_stub_consumer` at commit `bf6647d` on `feat/chat-ui-rearch`:
  - `rearch` capsules across the state layer, `flutter_chat_ui` for the message list, `flutter_webrtc` for calls
  - REST + XMPP-WS wiring, presence-aware contacts, 1:1 + MUC chat, MAM pagination, reactions, edits, retracts, replies, receipts, chat-states, SM resume
  - Attachments (file + camera), push-token registration
  - Full 1:1 audio + video calling with Jingle signaling, incoming-call banner, CallScreen full-bleed, camera-off graceful degradation, audible ringer on web + haptic on mobile
  - Group calls via ion-sfu JSON-RPC signaling with adaptive video grid
  - Windows + web + Android platform targets scaffolded, `--dart-define` runtime endpoint override
  - Debug-only diagnostics overlay (drag + long-press to hide)
  - **115/115 offline tests, 8/8 live-integration tests**, analyzer clean
- **UAT** — [UAT.md](UAT.md), 2026-09-09, pass, 14 HTTP requests, 0 errors
- **Live smoke** — Browser ↔ browser end-to-end verified: sign-in, 1:1 + group chat both directions, 1:1 audio + video, reactions, edits, retracts, MAM scroll, XEP-0198 resume; see [`rainbow_stub_consumer/docs/phase-live-smoke-log.md`](../../flutter/rainbow_stub_consumer/docs/phase-live-smoke-log.md).

> Wondering how this stacks up against WhatsApp / MS Teams? See **[§ 4](#4-product-parity--the-whatsappteams-gap)**
> for a feature grid, effort estimates by target ("full chat" / "small-team" /
> "WhatsApp-tier" / "Teams-tier"), and the closing-the-gap sequences in
> **[§ 9](#9-my-picks-if-you-only-do-one-thing-next)**.
>
> For the **React Native sample parity gap** (what `Rainbow-React-Native-Samples`
> ships that our Flutter client doesn't yet), see **[§ 7](#7-parity-with-the-rainbow-react-native-sample)**.

---

## 1. Highest ROI — closes UAT gaps

### 1.1 · 1:1 and group chat end-to-end test (S) — ⬜

- **What:** Two `RainbowXmppClient` instances (alice + bob) in one Dart test; alice sends `<message type="chat">`; bob receives it; assert body + `from`.
- **Where:** New `test/xmpp_chat_e2e_test.dart` in the Flutter project (or, if pure REST/WS is enough, in the stub project).
- **Acceptance:** Green on `flutter test` when the stub is running; skipped otherwise. Same test also covers `type="groupchat"` to a bubble both users are members of.
- **Depends on:** nothing.
- **Closes:** the "not exercised" note in [UAT.md § 6](UAT.md#6-areas-not-exercised-in-this-uat).

### 1.2 · File upload/download UI (M) — 🟡

- **What:** File picker in the chat composer → multipart `POST /fileServer/v1.0/files` → attach the descriptor id to the outgoing message → render as a card in the chat with a download button.
- **Where:** New `lib/rainbow/files_client.dart`, new `FileMessage` model, `ChatComposer` widget, tweaks to `ChatPage` / `BubbleChatPage`.
- **Acceptance:** Alice picks a PDF from disk, it shows up in Bob's session as a downloadable card. `FileAttachFinished` push event received in the UI (already fires server-side).
- **Depends on:** nothing.
- **Status 2026-09-11:** Upload path is complete (`AttachmentPicker` in `lib/ui/attachment_picker.dart` → REST upload → file descriptor attached as XMPP `<file/>` payload). **Download UI is still missing** — a received file bubble shows the name + MIME but has no tap-to-open / save action.

### 1.3 · Local message persistence (M) — ⬜

- **What:** SQLite-backed thread cache. On login, replay the last N messages from disk **and** fire an XMPP MAM `<query>` for anything newer.
- **Where:** New `lib/data/message_store.dart` using `sqflite`; hooked from `RainbowSession._handleIncomingMessage` and MAM response handling.
- **Acceptance:** Kill and relaunch the app; chats persist. Adding a message on device A appears on device B after login without losing history.
- **Depends on:** MAM UI wiring (currently only `xmpp_client.dart` speaks MAM; the session never queries it).

---

## 2. Wire compat + surface completeness

### 2.1 · React Native Rainbow sample end-to-end (M–L) — 🕒 superseded

- **What:** Point the unmodified [`react-native-rainbow-module`](../../node/Rainbow-React-Native-Samples) sample at the stub on an Android emulator; drive Login → Contacts → Chat → Bubbles → File share; fix each wire-compat gap the native SDK complains about; land a regression test on the stub for every gap.
- **Status 2026-09-11:** No longer the primary target — we now have a **Flutter reference client** (`rainbow_stub_consumer`) that exercises the same wire and is the first-class citizen. The RN sample is still a useful compatibility oracle but is not being driven end-to-end. See **[§ 7](#7-parity-with-the-rainbow-react-native-sample)** for the feature-parity gap between the Flutter client and the RN sample.

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

## 4. Product parity — the WhatsApp/Teams gap

This is the strategic framing for everything below. Where we are on the
messaging pyramid today, and roughly how far each layer is:

```
         ┌─────────────────────────────────────────┐
         │ Business platform (Teams-only)          │  ≈ 0%
         │ - Copilot, meetings, calendar,          │
         │   tabs SDK, external federation         │
         ├─────────────────────────────────────────┤
         │ Voice/video calling & meetings          │  ≈ 0%
         │ - P2P audio/video, group meetings,      │
         │   screen share, recording, background   │
         ├─────────────────────────────────────────┤
         │ Rich chat UX                            │  ≈ 15%
         │ - reactions, edits, threads, replies,   │
         │   voice notes, previews, search, sync   │
         ├─────────────────────────────────────────┤
         │ Reliability / scale / operations        │  ≈ 10%
         │ - federation, sharding, HA, DR,         │
         │   push notifications, offline queue     │
         ├─────────────────────────────────────────┤
         │ Security & compliance                   │  ≈ 5%
         │ - E2E encryption, retention, DLP,       │
         │   audit, SOC2/HIPAA/GDPR                │
         ├─────────────────────────────────────────┤
         │ Chat backbone                           │  ≈ 85%   ← we are here
         │ - login, roster, 1:1 chat, groups,      │
         │   presence, MAM history, receipts, SM   │
         └─────────────────────────────────────────┘
```

### 4.1 Feature grid (condensed)

Legend: ✅ done · 🟡 partial (wire ready, UI missing) · ⬜ missing

| Capability | WhatsApp | Teams | Us |
|---|---|---|---|
| 1:1 text chat | ✅ | ✅ | ✅ |
| Group chat | ✅ | ✅ | ✅ (bubbles) |
| Presence | 🟡 | ✅ | ✅ |
| Typing indicators | ✅ | ✅ | 🟡 wire ready |
| Delivery / read receipts | ✅ | ✅ | 🟡 wire ready |
| Message edit / delete | ✅ | ✅ | ⬜ |
| Reactions | ✅ | ✅ | ⬜ |
| Threads / quoted replies | 🟡 | ✅ | ⬜ |
| File attachments | ✅ | ✅ | 🟡 REST ready, no UI |
| Media previews / thumbnails | ✅ | ✅ | ⬜ |
| Voice notes | ✅ | ✅ | ⬜ |
| Message search | ✅ | ✅ | 🟡 MAM query works, no UI |
| Server history (MAM) | ✅ | ✅ | ✅ |
| @mentions + notifications | ✅ | ✅ | ⬜ |
| Push notifications | ✅ | ✅ | ⬜ (deferred § 6.3) |
| Voice calls | ✅ | ✅ | ⬜ (deferred § 6.1) |
| Video calls | ✅ | ✅ | ⬜ |
| Meetings + recording + transcription | — | ✅ | ⬜ (§ 6.5) |
| Screen share | ⬜ | ✅ | ⬜ |
| E2E encryption | ✅ | 🟡 | ⬜ (§ 6.4) |
| Retention + DLP + audit | ⬜ | ✅ | ⬜ (§ 6.6) |
| Admin console + SSO | ⬜ | ✅ | ⬜ (§ 6.6) |
| Horizontal scale | ✅ | ✅ | ⬜ (§ 6.7) |
| Global media CDN | ✅ | ✅ | ⬜ (§ 6.8) |
| Multi-device sync (linked) | ✅ | ✅ | 🟡 XMPP resources work; no synced read state |
| iOS / Android clients | ✅ | ✅ | ⬜ (§ 5.4 Android target) |
| Web + Desktop clients | ✅ | ✅ | 🟡 Windows + Web builds work |

### 4.2 Effort ladder — how far from each target

Rough calendar for one senior full-stack dev, no team politics.

| Target | What it adds on top of today | Estimate |
|---|---|---|
| **"Full-featured chat"** (Signal/Element-tier) | edits, reactions, threads, files UI, push, search, voice notes, media previews, **E2E encryption** | **~2–4 months** |
| **"Small-team collaboration"** (Slack MVP-tier) | + channels/permissions, @mentions, integrations, retention, admin | **+ 2–3 months** |
| **"WhatsApp-tier consumer chat"** | + voice/video calling, backup/restore, multi-device sync, iOS/Android polish, spam controls, phone identity | **~6–9 months from today** |
| **"Teams-tier enterprise collaboration"** | + meetings + recording + transcription, SSO/MFA, admin console, files/SharePoint-like, apps SDK, compliance controls | **~2–3 years for parity** |

### 4.3 What we already have that's competitive

- **Standards-compliant XMPP** (SASL, resource binding, SM, carbons, MAM+RSM, MUC light, ping, disco). Same wire the enterprise CPaaS vendors ship. That's the hardest single piece of a Teams-lite to get right, and it's done.
- **Observability from day one** — JSON structured logs + Prometheus `/metrics`. Most chat products don't have this at v0.1.
- **Hardened server-side** — stanza size caps, queue caps, SASL failure limits, MAM auth, XXE guard, HSTS. Not amateur.
- **Multi-platform client from one codebase** (Flutter Windows + Web + trivial Android/iOS).

### 4.4 What today's stack is honestly good for

- ✅ **CPaaS-SDK dev backend** (its stated purpose) — production-shape.
- ✅ **Internal chat backbone** — say, a 50-person dispatch board, IoT device chat, or a support-ticket-with-conversation product — with modest additions from § 5.
- ✅ **XMPP research testbed** — great for protocol experiments and load testing.
- ⬜ Consumer-facing chat — no push, no E2E, no calls, no scale (§ 6.3, § 6.4, § 6.1, § 6.7).
- ⬜ Enterprise collaboration — no admin, no SSO, no compliance, no meetings (§ 6.5, § 6.6).

---

## 5. Nice-to-haves

### 5.0 · Adopt `flutter_chat_ui` + `rearch` in the Flutter consumer (M) — ⬜

- **What:** Replace the hand-rolled chat bubbles with [`flutter_chat_ui`](https://pub.dev/packages/flutter_chat_ui); replace `provider` + `RainbowSession ChangeNotifier` with [`rearch`](https://pub.dev/packages/rearch) capsules.
- **Where:** `c:\www\flutter\rainbow_stub_consumer` — full plan in [`PLAN.md`](../../flutter/rainbow_stub_consumer/PLAN.md) with 8 phases (A–H) and per-phase acceptance criteria.
- **Bonus:** Phases D–H of the plan simultaneously close § 5.1 (edits), § 5.5 (reactions), § 5.6 (receipt UI), § 5.7 (typing UI), § 5.8 (threads), § 5.11 (media previews).
- **Estimate:** ≈ 8–10 working days for the full track; ≈ 3–4 days for phases A–D (visible UX win).
- **Acceptance:** as documented in `PLAN.md § 12 Definition of done`.

### 5.1 · XEP-0308 message correction (M) — ✅ (2026-09-11)

- **What:** Server: forward `<replace id="orig">` payload; update the stored message in the messages table. Client: long-press → edit; render corrected messages with an "edited" badge.
- **Landed in:** stub `session.dart` correction forwarding + `messages` update; client `xmpp_client.dart` `XmppMessageCorrection` event + `chat_actions_capsule.editPeer / editGroup` + long-press "Edit" tile in `ChatPage` / `BubbleChatPage`.

### 5.2 · XEP-0198 SM in the Flutter client (M) — ✅ (2026-09-10)

- **What:** After bind, send `<enable resume="true"/>`; track `hIn`/`hOut`; on WS drop, reconnect and send `<resume previd=… h=…/>`.
- **Landed in:** `lib/rainbow/xmpp_client.dart` — `_smEnabled` / `_smResumable` / `_smid` / `_hIn` / `_hOut` state machine, `resume()` method, outbound-stanza replay on resume. Phase-J log covers offline coverage, Phase-L covers live MAM+SM smoke.

### 5.3 · Dark mode / theme toggle (S) — ⬜

- **What:** Add `ThemeMode` state to `RainbowSession`; wire from the profile menu.
- **Acceptance:** Setting persists across app restarts (SharedPreferences).

### 5.4 · Android target (M) — ✅ (2026-09-10)

- **What:** `flutter create --platforms=android .` in the consumer; add `--dart-define=RAINBOW_HOST=10.0.2.2` support in `AppConfig.dev`; document cert-trust flow.
- **Landed in:** `android/` scaffold with WebRTC permissions + `minSdk=24`, `--dart-define` config injection (`STUB_SCHEME` / `STUB_HOST` / `STUB_PORT` / `SFU_URL`), `docs/live-smoke-test.md` runbook. HTTP-only `rainbow-stub-smoke.yaml` config on the server side removes the self-signed-cert trust headache.

### 5.5 · Message reactions (M) — ✅ (2026-09-11)

- **What:** XEP-0444 `<reactions xmlns="urn:xmpp:reactions:0">`. Server: forward + persist a reactions column keyed by message id. Client: emoji picker over a long-press.
- **Landed in:** stub `session.dart` reactions persist + fan-out; client `XmppReactions` event + `_reactionsChip` tap-to-toggle + long-press sheet.

### 5.6 · Delivery + read receipts UI surface (S) — ✅ (2026-09-11)

- **What:** The wire already forwards XEP-0184 receipts and XEP-0333 chat markers. All that's missing is rendering the ✓ / ✓✓ / read state in the chat bubble.
- **Landed in:** `ChatMessage.status` + `_stampStatus` reducer in `messages_capsule.dart` — receipts stamp `deliveredAt`, `displayed` markers stamp `seenAt`, and `flutter_chat_ui`'s default status icon promotes automatically. Sent-ack comes via XEP-0198 `<a h="N"/>` (see § 5.2).

### 5.7 · Typing indicator UI surface (S) — ✅ (2026-09-11)

- **What:** Wire already relays chat-states (`<composing/>`, `<paused/>`). Missing is rendering "…is typing" in the chat header.
- **Landed in:** `XmppChatState` event on the client, `peerIsTyping` reducer in `messages_capsule.dart`, banner row in `ChatPage` / `BubbleChatPage`. Auto-clears after 6 s of no `composing`.

### 5.8 · Threads / quoted replies (M) — ✅ (2026-09-11)

- **What:** XEP-0461 `<reply xmlns="urn:xmpp:reply:0" id="orig" to="jid"/>` plus a quoted-body render.
- **Landed in:** `_renderReply` on the client, `_readReplyTargetId` on the incoming path, `ChatReplyBanner` in the composer, quoted-card render above the bubble in `chat_widgets.dart`. Applies to both 1:1 and MUC.

### 5.9 · Message search UI (M) — ⬜

- **What:** Full-text search over local message store + server-side MAM `<query with … full-text>`. Simple search bar on the Contacts/Bubbles tabs.
- **Depends on:** § 1.3 local message persistence.
- **Acceptance:** Type a substring → results list groups matches by conversation with highlighted snippets.
- **Parity:** Closes "Message search" gap vs. WhatsApp + Teams.

### 5.10 · @mentions + local notifications (M) — ⬜

- **What:** Parse `@userId` (or `@nickname` for MUC), highlight in body, deliver a system notification if the app is backgrounded. Server side already has the message; only the parsing + local notification is new.
- **Acceptance:** In a bubble, alice types "@bob" → bob's client shows a distinct highlight + notification badge on the tab.
- **Parity:** Closes "@mentions + notifications" gap.

### 5.11 · Media previews / thumbnails (M) — ⬜

- **What:** Server: generate + serve thumbnails for image/video file descriptors (256×256 max). Client: render inline preview in the chat bubble with tap-to-open.
- **Depends on:** § 1.2 file upload UI.
- **Acceptance:** Attaching a JPG shows a compressed preview inline; attaching a PDF shows a filename+size card.
- **Parity:** Closes "Media previews / thumbnails" gap.

### 5.12 · Voice notes (M–L) — ⬜

- **What:** Client: hold-to-record button captures audio (Opus @ 24 kbps), uploads via existing file endpoint, sends a `<message>` with a `<audio-descriptor/>` payload. Server: persist as a file descriptor with a `duration_ms` field.
- **Acceptance:** Press-and-hold to record a 5 s clip → releases → sent → recipient sees a waveform + play button.
- **Parity:** Closes "Voice notes" gap.

---

## 6. Deferred bigger blocks

### 6.1 · SIP / Asterisk WebRTC calling (XL) — 🕒 superseded

- **Original phase 5** of the roadmap. Would have delivered SIP-signalled audio/video via [`dart-pbx`](../../dart-pbx) and [`dart-ari`](../../dart-ari).
- **Status 2026-09-11:** We took a different route — native XEP-0166 Jingle signalling in the stub + `flutter_webrtc` on the client, verified browser ↔ browser end-to-end. Delivers the same 1:1 audio + video coverage without dragging Asterisk into the loop. Group calls come via ion-sfu (see the client's `docs/ion-sfu-wsl.md`). Asterisk remains available for future PSTN/SIP bridging.
- **Parity delta:** ✅ closed "Voice calls" and "Video calls" gaps.

### 6.2 · Server-to-server federation (XL) — 🕒

- XEP-0220 dialback across two rainbow-stub instances.
- Only worth doing if a multi-tenant / multi-server demo is on the horizon.
- **Parity delta:** matches Teams external federation surface (not WhatsApp — WA is walled).

### 6.3 · Push notifications (L) — � partial

- Offline delivery via FCM/APNs, proxied by the stub. Requires per-device token registration + native SDK integration on Flutter.
- **Status 2026-09-11:** Token-registration wire is complete — client `pushCapsule` registers a fake per-session token via `POST /users/:id/push-tokens`; stub persists in `push_tokens` SQLite table and emits `would-push user=…` INFO log line when a message can't be delivered because the recipient has no active XMPP session. **Still missing:** actual FCM/APNs sender on the stub side and native push-token acquisition (via `firebase_messaging` or similar) on the client.
- **Parity delta:** wire-level surface ✓; user-visible push ✗.

### 6.4 · End-to-end encryption (XL) — ⬜

- **What:** Signal-protocol double ratchet + X3DH prekey server + safety-number verification.
- Requires substantial changes: the messages table stores ciphertext only, key material lives on the client, and the server can never MAM-index bodies. MAM becomes envelope-only.
- **Where:** New `lib/src/e2e/` module server-side; new `lib/rainbow/e2e/` client-side; changes to `MessageRepository`, `_handleMessage`.
- **Parity delta:** matches WhatsApp's headline promise; matches Teams' Teams-Premium E2E track.
- **Not compatible with:** server-side full-text search, retention scanning, DLP. Would need to be an opt-in feature.

### 6.5 · Meetings + recording + transcription (XL) — 🕒

- **What:** Group audio/video calls (up to N attendees) via an SFU (mediasoup, Janus, LiveKit). Recording via an egress bot. Live captions + post-call transcript via a locally-hosted Whisper / cloud STT.
- **Depends on:** § 6.1 as a prerequisite for 1:1 media stack.
- **Where:** Probably a sidecar service, not the shelf process. Signalling stays in XMPP (Jingle-over-XMPP is the natural fit).
- **Parity delta:** the biggest single Teams differentiator vs. WhatsApp.

### 6.6 · Admin console + SSO + retention + audit (XL) — ⬜

- **What:**
  - Admin web console (Flutter web) for user provisioning, bubble/room admin, presence override, message retention policies, and export.
  - SSO via OIDC + MFA (Azure AD / Okta / Auth0-friendly). Guest user flow.
  - Retention policies (per-tenant N days), legal hold, DLP scanning hooks.
  - Tamper-evident audit log (append-only, per-event signed).
- **Parity delta:** everything the "Enterprise" column in the feature grid needs.
- **Not code-only:** SOC 2 / HIPAA / GDPR require formal controls + external audit.

### 6.7 · Horizontal scale — Postgres + Redis + shelf workers (L–XL) — ⬜

- **What:**
  - Move SQLite → Postgres (drift's Postgres backend or `postgres` package).
  - Move `StanzaRouter` and `SmRegistry` into a Redis-backed pub/sub so multiple shelf workers behind a load-balancer can share sessions.
  - Sharding key: `userId` → worker.
- **Ceiling today:** single node, maybe ~2–5k concurrent XMPP sessions on decent hardware. Post-migration: horizontal.
- **Parity delta:** any consumer product needs this before onboarding a real user base.

### 6.8 · Global media CDN (L) — ⬜

- **What:** Instead of `data/files/` on local disk, upload user files to an object store (S3/R2/B2/Azure Blob), issue signed URLs, front with a CDN.
- **Parity delta:** matches WhatsApp/Teams media delivery speed globally.

### 6.9 · Compliance certifications (XL, not just code) — ⬜

- **What:** SOC 2 Type II, HIPAA BAA-ready, GDPR DPA templates, ISO 27001 alignment.
- Not something to schedule as a dev task; it's a company-level programme with policies, controls, external auditors, ~6–12 months + $$$.
- **Depends on:** § 6.6 for the technical controls.

---

## 7. Parity with the Rainbow-React-Native sample

Reference: the parity audit ran on 2026-09-11 against
`c:\www\node\Rainbow-React-Native-Samples\src` — see the summary in the
session log. The Flutter client covers **core chat + calls end-to-end**
and is **ahead** on reactions and edits. What's still missing to reach
feature parity with the RN reference, ordered by user-visible impact:

### 7.1 · Registration + Forgot-password screens (S) — ✅ (2026-09-11)

- **Landed in:** `rainbow_stub_consumer` commit `0174685`. `RestClient.selfRegisterSendEmail` / `selfRegister` / `resetPasswordSendEmail` / `resetPassword` wrap the corresponding stub routes. `lib/ui/register_page.dart` is a two-step form (email → confirm+password+names) that auto-signs-in on completion; `lib/ui/forgot_password_page.dart` is a two-step form (email → token+new password) that returns to the login screen. LoginPage now surfaces both as text buttons under the sign-in action. Dev-token is echoed in the response so demos skip the real mailbox.

### 7.2 · MyProfile view + edit (M) — ✅ (2026-09-11)

- **Landed in:** `rainbow_stub_consumer` commit `0174685`. `RainbowUser` grew `nickName`, `title`, `language`. `RestClient.updateMe` wraps `PUT /users/:id`. `AuthController` gains `refreshMe()` (re-fetches `GET /users/:id` and hot-swaps the `authStateCapsule` slot) and `updateMe(...)` (PUT + slot swap in one call). `lib/ui/profile_page.dart` renders a read-only avatar + field card with a refresh button; `lib/ui/profile_edit_page.dart` seeds fields from the current `me` and dispatches `auth.updateMe` on save. HomePage popup menu now surfaces "My profile" above the presence switcher. Avatar upload (`POST /users/:id/photo`) is not yet wired — UI shows an initials bubble until it is.

### 7.3 · 1:1 Conversations list (M) — ✅ (2026-09-11)

- **Landed in:** `rainbow_stub_consumer` commit `8e38a4d`. `conversationsCapsule` reduces every 1:1 `XmppChatMessage` the client observes into a peer-indexed recency slot, enriched via `rosterCapsule` for display names. `ConversationsTab` renders the sorted list with an avatar, direction-prefixed subtitle, and a today-time / DD-MM timestamp. HomePage nav becomes three tabs: **Recent** (default) | Contacts | Bubbles. Session-scoped by design — pre-existing threads stay in Contacts until the peer sends something or the user opens the thread (server-side conversations endpoint would need ROADMAP § 1.3 to hydrate history).

### 7.4 · Call history page (M) — ✅ (2026-09-11)

- **Landed in:** `rainbow_stub_consumer` commit `8e38a4d`. `CallLogEntry` client model wraps the stub's `/users/:id/calllogs` shape; `rest_client.listCallLogs` + `deleteCallLog` cover the missing CRUD. `callLogsCapsule` wraps rearch's `AsyncValue` lifecycle with a refresh + delete controller and hot-reloads on sign-in. `CallLogPage` renders a `SegmentedButton` (All / Missed), swipe-to-delete rows, and directional icons (`call_made`, `call_received`, `call_missed`, `call_end`, `error_outline`). Wired via HomePage popup menu → "Recent calls".

### 7.5 · Bubble management + invitations (M) — ✅ (2026-09-11)

- **Landed in:** `rainbow_stub_consumer` commit `cd9ce3f`. `rest_client` gains `roomInvitations`, `updateRoom`, `deleteRoom`, `inviteToRoom`, `setRoomMemberStatus`. `bubble_invitations_capsule.dart` surfaces pending invites for the signed-in user with an `entries` + `refresh` controller. `chat_actions_capsule` grows `updateBubble` / `deleteBubble` / `inviteToBubble` / `acceptBubbleInvitation` / `declineBubbleInvitation` / `leaveBubble` (accept/decline/leave all route through `setRoomMemberStatus` — accepted / declined). `lib/ui/bubble_details_page.dart` renders the header, accepted-member list, pending-invitation list, and buttons for invite (roster-filtered contact sheet excluding current members), leave (self), owner-only delete, plus an AppBar edit sheet for name + topic. `BubbleChatPage` AppBar carries an `info_outline` action that pushes the details page. `BubblesTab` pins an "Invitations (N)" section above the bubble list with per-card accept / decline buttons that refresh the capsule.

### 7.6 · File browser + download + preview (M) — ✅ (2026-09-11)

- **Landed in:** `rainbow_stub_consumer` commit `642768e`. `FileDescriptor` extended with `createdAt` / `ownerId` / `peer` (parsed from the stub's `creationDate` / `ownerId` / `peer` fields) to support sort + owner-only actions. `rest_client` gains `listSharedFiles(peerJid)` (backed by `GET /fileServer/v1.0/files?peer=`) and `deleteFile(id)`. `lib/ui/shared_files_page.dart` renders the per-peer file list with a PopupMenuButton for sort (Date / Name / Size), a refresh action, and `Dismissible` swipe-to-delete for the current user's own uploads. `lib/ui/file_preview_page.dart` shows a metadata card plus inline `Image.memory` for images (bytes fetched via the authed `downloadFileBytes`), a Copy-link action for every file, and an Open-link fallback via `url_launcher` for non-images. Both `ChatPage` and `BubbleChatPage` grow a `folder_open` AppBar action that opens `SharedFilesPage` with the peer's bare JID or the bubble MUC JID. Deps: `url_launcher`.

### 7.7 · Message forward + copy (S) — ✅ (2026-09-11)

- **Landed in:** `rainbow_stub_consumer` commit `0174685`. Copy was already wired (`CopyChoice` → `Clipboard.setData`). Forward adds `ForwardChoice` to `MessageActionChoice` + a Forward tile in the long-press sheet; `lib/ui/forward_picker.dart` lists joined rooms + roster contacts as a fullscreen dialog; both `chat_page.dart` and `bubble_chat_page.dart` route the picked target through the existing `chatActions.sendPeer` / `sendGroup`. Text-body forwarding only for now — forwarding an attachment carries the text body but not the file descriptor.

### 7.8 · Runtime permissions bootstrap (S) — ✅ (2026-09-11)

- **Landed in:** `rainbow_stub_consumer` commit `8e38a4d`. `pubspec` adds `permission_handler`; `permissionsCapsule` fires `Permission.[camera, microphone, notification].request()` once on sign-in and exposes a per-slot `PermissionsState`. Web is treated as unsupported (browsers gate on `getUserMedia` per-tab). HomePage renders an `errorContainer` banner with a Retry button whenever any of the three is denied — covers the RN sample's up-front rationale UX.

### 7.9 · Global search + connectivity banner (M) — ✅ (2026-09-11)

- **Landed in:** `rainbow_stub_consumer` commit `cd9ce3f`. `connectivity_plus` added; `connectivity_capsule.dart` subscribes to `Connectivity().onConnectivityChanged`, seeded with `checkConnectivity()` on mount and exposing a reactive `bool` (true when any transport is non-none). `HomePage` stacks an `_OfflineBanner` (surfaceContainerHighest + `wifi_off`) above content whenever `!online`, coexisting with the permissions banner. `ContactsTab` gains a filter-in-place search bar at the top (case-insensitive `display` / `loginEmail` contains) with a friendly empty state; `BubblesTab` gains an equivalent search bar (name / topic) with the invitations section always pinned above.

### 7.10 · Group-call advanced controls (M) — ⬜

- **Gap:** `GroupCallScreen` has mic / camera / leave only. RN
  `ConferenceCallComponent` also has loudspeaker, lock room,
  add-participant, delegate host, hide-view / share-view.
- **Sketch:** Extend `GroupCallManager` with `setLoudspeakerEnabled`
  / `lockRoom` / `promoteToHost`; wire buttons in
  `GroupCallScreen`. Requires matching ion-sfu control channel
  wire — some features may need custom XMPP payloads on top of the
  MUC-call marker (`urn:rainbow:muc-call:1`).
- **Estimate:** M.

**Sprint 1 (2026-09-11):** ✅ 7.1 + 7.2 + 7.7 landed in `rainbow_stub_consumer` commit `0174685` (registration, forgot-password, MyProfile, Forward).

**Sprint 2 (2026-09-11):** ✅ 7.3 + 7.4 + 7.8 landed in `rainbow_stub_consumer` commit `8e38a4d` (Conversations tab, Call-history page, runtime permissions bootstrap).

**Sprint 3 (2026-09-11):** ✅ 7.5 + 7.9 landed in `rainbow_stub_consumer` commit `cd9ce3f` (Bubble management + invitations, filter-in-place search on Contacts + Bubbles, connectivity banner).

**Sprint 4 (2026-09-11):** ✅ 7.6 landed in `rainbow_stub_consumer` commit `642768e` (per-peer shared files list with sort + swipe-to-delete + inline image preview).

**Remaining open:** 7.10 (Group-call advanced controls). Combined estimate M ≈ 2–3 days.

---

## 8. What's already done — quick history

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

## 9. My picks if you only do one thing next

- **Fastest visible win:** [§ 1.1 chat E2E test](#11--11-and-group-chat-end-to-end-test-s--) (S)
- **Most impressive stack exercise:** [§ 1.2 file upload UI](#12--file-uploaddownload-ui-m--) (M)
- **Biggest strategic milestone:** [§ 2.1 RN sample end-to-end](#21--react-native-rainbow-sample-end-to-end-ml--) (M–L)
- **Biggest single UX gap for a real user:** [§ 6.3 push notifications](#63--push-notifications-l--) (L)
- **Biggest strategic "we're serious about chat" signal:** [§ 6.4 E2E encryption](#64--end-to-end-encryption-xl--) (XL)

If in doubt, do § 1.1 — it costs almost nothing and moves "chat works" from anecdote to CI-enforced.

### Suggested closing-the-gap sequences

Depending on what target from § 4.2 you're aiming for, work these paths:

- **"Full-featured chat" target** — § 1.2 → § 1.3 → § 5.6 → § 5.7 → § 5.5 → § 5.1 → § 5.11 → § 6.3 → § 5.9 → § 5.10 → § 6.4
- **"Small-team collaboration" target** — the above + § 5.8 → § 6.6 (admin subset: SSO, retention)
- **"WhatsApp-tier"** — above through § 6.4 + § 5.12 (voice notes) + § 6.1 (calls) + § 5.4 (Android) + iOS work
- **"Teams-tier"** — everything, and prepare to hire

If in doubt, do § 1.1 — it costs almost nothing and moves "chat works" from anecdote to CI-enforced.
