# rainbow-stub

Wire-compatible stub of the Alcatel-Lucent **Rainbow** CPaaS backend for
local development of `react-native-rainbow-module` apps and Flutter
clients.

- HTTP: `shelf` on port `8443` (TLS by default, auto-generated cert)
- XMPP/WS: hand-rolled RFC 7395 server at `/websocket`
- WebRTC: delegated to Asterisk (deferred)

> **New here?** See [RUNBOOK.md](RUNBOOK.md) — full setup, tests,
> troubleshooting, and how to point a Flutter or React Native client
> at this stub.

## Quickstart

```powershell
cd c:\www\dart\rainbow-stub
dart pub get
dart run tool/gen_cert.dart          # self-signed TLS
dart run tool/seed.dart              # seed alice@rainbow-stub.local / password
dart run bin/server.dart
```

Then point the RN sample at it — edit `android/app/src/main/assets/rainbow-config.json`
(and `ios/rainbow-config.json`):

```json
{
  "HOST": "10.0.2.2:8443",
  "APP_ID": "65c681c01c8f11e9add8932b358ef81d",
  "SEC_KEY": "UYdu3wCXTdfyjImhURnIkZ0tac5J9XSLszIKBRUUWVB35b6nT3fWV2BhAGhojdBQ"
}
```

## Layout

| Path | Purpose |
|---|---|
| `bin/server.dart` | Entrypoint |
| `lib/src/auth/` | `/authentication/v1.0/*` + self-register + reset-password |
| `lib/src/users/` | `/enduser/v1.0/users/*` |
| `lib/src/db/` | SQLite schema + `AppDatabase` |
| `lib/src/util/` | IDs, error envelope, JSON helpers, logging |
| `config/` | YAML config (overridable) |
| `tool/` | `gen_cert.dart`, `seed.dart` |
| `docker/` | Dockerfile + compose (joins `dart-pbx` on `rainbow-net`) |

## Roadmap

Full grouped-by-ROI roadmap with estimates and acceptance criteria:
**[ROADMAP.md](ROADMAP.md)**.

Snapshot of the phase timeline:

- [x] Phase 0 — scaffold, TLS, `/health`
- [x] Phase 1 — auth REST (login/logout/renew, self-register, reset-password), users REST
- [x] Phase 2 — roster, avatars, presence
- [x] Phase 3 — XMPP-over-WS (SASL, binding, 1:1 chat, MAM, chat states)
- [x] Phase 4 — bubbles, files, call-log, XMPP push events
- [x] Phase 5-XMPP hardening — ping, disco, roster IQ, presence probe, MUC light, receipts
- [x] Batch — XEP-0198 SM (enable/ack/resume), XEP-0280 carbons, bubble MAM, XEP-0313 RSM
- [x] Hardening — stanza size, queue caps, session caps, keepalive, MAM auth, SASL cap
- [x] Observability — TLS auto-gen + HSTS, JSON logs, Prometheus `/metrics`, XXE guard
- [x] Flutter consumer (`c:\www\flutter\rainbow_stub_consumer`) + UAT record
- [ ] Phase 5-SIP — Asterisk ARI bridge for P2P + ConfBridge *(deferred)*
