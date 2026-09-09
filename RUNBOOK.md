# Rainbow Stub — Runbook

Everything you need to boot the rainbow-stub server, run the Flutter
consumer against it, and (optionally) point the React Native Rainbow
sample at it — from a cold start.

- **Server** (Dart): `c:\www\dart\rainbow-stub`
- **Flutter consumer**: `c:\www\flutter\rainbow_stub_consumer`
- **RN sample** (upstream, unmodified): `c:\www\node\Rainbow-React-Native-Samples`

---

## 0. Prerequisites

| Tool | Version used | Where |
|---|---|---|
| Dart SDK | ≥ 3.6 | Comes with Flutter — `C:\flutter\flutter_windows_3.27.4-stable\flutter\bin\dart.exe` |
| Flutter SDK | 3.41.7 stable | `C:\flutter\flutter_windows_3.27.4-stable\flutter\bin\flutter.bat` |
| OpenSSL | any recent | Used by the stub for auto-generated TLS certs. Git-for-Windows ships one; verify with `openssl version` |
| PowerShell | any | Terminals below assume `powershell.exe` (Windows PowerShell 5.1) |
| curl.exe | Windows 10+ built-in | Used by smoke scripts |
| Node.js + Yarn | ≥ 20 | Only for the RN sample. Skip if not using it |
| Chrome or Edge | latest | Only for the Flutter Web target |
| Visual Studio 2022 | Community, with "Desktop development with C++" | Only for the Flutter Windows target |

Add the Flutter bin folder to your `PATH` if you don't want to type the
full path every time:

```powershell
$env:PATH = "C:\flutter\flutter_windows_3.27.4-stable\flutter\bin;$env:PATH"
flutter --version
```

---

## 1. First-time setup

Do this once per machine.

### 1a. Stub

```powershell
cd c:\www\dart\rainbow-stub
dart pub get
```

That downloads deps and produces `.dart_tool/`. No further build step
needed — the stub runs directly from source.

### 1b. Flutter consumer

```powershell
cd c:\www\flutter\rainbow_stub_consumer
flutter pub get
```

Optional pre-build so first launch is fast:

```powershell
flutter build windows --release
# or, for web:
flutter build web --release
```

### 1c. RN sample (only if you plan to test it)

```powershell
cd c:\www\node\Rainbow-React-Native-Samples
yarn install
```

---

## 2. Boot the stub

The one-liner path most days:

```powershell
cd c:\www\dart\rainbow-stub
dart run tool/seed.dart          # only needed on first boot or after wiping data/
dart run bin/server.dart
```

You should see:

```
{"ts":"…","message":"TLS cert missing — auto-generating self-signed pair"}
{"ts":"…","message":"generated self-signed cert at ./certs/rainbow-stub.crt"}
{"ts":"…","message":"rainbow-stub listening on https://0.0.0.0:8443"}
```

**Sanity check** in another terminal:

```powershell
curl.exe -sk https://localhost:8443/health
# → {"ok":true}
```

### Default seed data

`tool/seed.dart` creates these accounts (all password `password`):

| Email | Role |
|---|---|
| `alice@rainbow-stub.local` | Primary account. Owns "Rainbow Stub Demo" bubble. Roster contains bob, carol, dave, eve |
| `bob@rainbow-stub.local` | Contact / member |
| `carol@rainbow-stub.local` | Contact / member (default presence: away) |
| `dave@rainbow-stub.local` | Contact / member (default presence: dnd) |
| `eve@rainbow-stub.local` | Contact / member (default presence: offline) |

Plus two call-log entries against Alice and one shared bubble.

### Wipe and reseed

```powershell
Remove-Item c:\www\dart\rainbow-stub\data -Recurse -Force -ErrorAction SilentlyContinue
dart run tool/seed.dart
```

### Configuration

Everything lives in `config/rainbow-stub.yaml`. The most useful keys:

| Key | Default | Effect |
|---|---|---|
| `host` | `0.0.0.0` | Bind address |
| `port` | `8443` | HTTPS port |
| `publicHost` | `localhost` | XMPP domain and CN of the auto-generated cert |
| `tls.enabled` | `true` | `false` = HTTP-only |
| `tls.autoGenerate` | `true` | Regenerate cert on boot if missing |
| `logs.format` | `json` | Switch to `text` for human-readable stdout |
| `metrics.enabled` | `true` | Toggle `/metrics` endpoint |

Point at a non-default config:

```powershell
dart run bin/server.dart --config path\to\my.yaml
```

### Graceful shutdown

Press **Ctrl-C** in the server's terminal. You'll see the sessions being
closed cleanly:

```
{"level":"INFO","message":"SIGINT — shutting down"}
{"logger":"rainbow-stub","message":"shutdown — closing 0 sessions (active=0 parked=0)"}
```

---

## 3. Test the stub

### 3a. Unit + integration tests (fast)

```powershell
cd c:\www\dart\rainbow-stub
dart test                              # full suite (≈ 40 tests)
dart test test/auth_test.dart          # just auth
dart test test/xmpp_batch_test.dart    # just XMPP-batch (SM/carbons/MAM/RSM)
```

Windows-flaky note: one multipart avatar test can occasionally fail on
the first run due to `dart:HttpClient` TIME_WAIT pressure. It has
`retry: 2` and always passes within three attempts.

### 3b. Live smoke scripts

Each phase has its own smoke script. All assume the server is running
on `https://localhost:8443` with the default seed.

```powershell
# Phase 1 — REST auth end-to-end
powershell -NoProfile -File c:\www\dart\rainbow-stub\tool\smoke.ps1

# Phase 2 — Roster + avatars + presence + search
powershell -NoProfile -File c:\www\dart\rainbow-stub\tool\smoke-phase2.ps1

# Phase 3 — XMPP-over-WS handshake + 1:1 chat + presence
dart run c:\www\dart\rainbow-stub\tool\smoke-phase3.dart

# Phase 4 — Bubbles + files + call log + XMPP push events
powershell -NoProfile -File c:\www\dart\rainbow-stub\tool\smoke-phase4.ps1

# Phase 5 XMPP hardening — ping / disco / roster / presence probe
dart run c:\www\dart\rainbow-stub\tool\smoke-phase5-xmpp.dart

# Phase 6 batch — SM enable/ack/resume + carbons + bubble MAM + RSM
dart run c:\www\dart\rainbow-stub\tool\smoke-phase6-xmpp.dart
```

### 3c. Manual probes

```powershell
# Health
curl.exe -sk https://localhost:8443/health

# Prometheus metrics (Prometheus text format)
curl.exe -sk https://localhost:8443/metrics

# Login as alice, capture bearer
$user = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes('alice@rainbow-stub.local:password'))
$app  = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes('65c681c01c8f11e9add8932b358ef81d:UYdu3wCXTdfyjImhURnIkZ0tac5J9XSLszIKBRUUWVB35b6nT3fWV2BhAGhojdBQ'))
$login = curl.exe -sk -H "authorization: Basic $user" -H "x-rainbow-app-auth: Basic $app" `
    https://localhost:8443/api/rainbow/authentication/v1.0/login | ConvertFrom-Json
$token = $login.token
Write-Host "token=$token userId=$($login.loggedInUser.id)"

# Fetch roster
curl.exe -sk -H "authorization: Bearer $token" `
    https://localhost:8443/api/rainbow/enduser/v1.0/users/networks | ConvertFrom-Json | Format-List
```

---

## 4. Run the Flutter consumer

### 4a. Windows desktop (fastest turnaround)

```powershell
cd c:\www\flutter\rainbow_stub_consumer
flutter run -d windows
```

Or the pre-built exe:

```powershell
c:\www\flutter\rainbow_stub_consumer\build\windows\x64\runner\Release\rainbow_stub_consumer.exe
```

The login screen is pre-filled with `alice@rainbow-stub.local` /
`password`. Click **Sign in**.

### 4b. Web (Chrome)

```powershell
flutter run -d chrome
```

Chrome will complain about the self-signed cert on first hit — click
**Advanced → Proceed to localhost (unsafe)** for both `:8443` and the
WebSocket handshake (same origin).

### 4c. Android emulator

The emulator sees the host machine as `10.0.2.2`. Override the config
at run-time with `--dart-define`:

```powershell
flutter run -d emulator-5554 --dart-define=RAINBOW_HOST=10.0.2.2
```

If you added this, extend `lib/config.dart` to read
`bool.fromEnvironment('RAINBOW_HOST')` (small edit — see the TODO in
that file).

You also need the emulator to trust the stub's self-signed cert:

```powershell
adb push c:\www\dart\rainbow-stub\certs\rainbow-stub.crt /data/local/tmp/
adb shell "su 0 mv /data/local/tmp/rainbow-stub.crt /system/etc/security/cacerts/"
adb reboot
```

(Requires a rooted emulator image — the "Google APIs" image, not
"Google Play".)

### 4d. Flutter tests

```powershell
cd c:\www\flutter\rainbow_stub_consumer
flutter test                              # unit tests only (3 pass)
flutter test test/live_stub_integration_test.dart  # requires stub running
```

The live integration test skips itself gracefully if the stub isn't
reachable at `https://localhost:8443/health`.

---

## 5. Test-drive walkthrough (5 minutes end-to-end)

Terminal A — start the stub:

```powershell
cd c:\www\dart\rainbow-stub
dart run tool/seed.dart            # only if data/ is empty
dart run bin/server.dart
```

Terminal B — start the Flutter consumer:

```powershell
cd c:\www\flutter\rainbow_stub_consumer
flutter run -d windows
```

In the Flutter app:

1. Sign in as `alice@rainbow-stub.local` / `password`.
2. Contacts tab shows Bob (online / green), Carol (away / orange),
   Dave (dnd / red), Eve (offline / grey).
3. Tap **Bob** → send "hello from Windows".
4. Tap **Bubbles** → open "Rainbow Stub Demo" → send a group message.
5. Tap the avatar (top-right) → switch presence to **away**.
6. In Terminal A, watch the JSON log stream — you'll see the
   corresponding REST + WS + stanza-router lines fire.

Verify metrics went up:

```powershell
curl.exe -sk https://localhost:8443/metrics | Select-String rainbow_stub_
```

Sign out from the app; the stub logs
`unregister … total=0` and presence goes to offline.

---

## 6. Point the RN Rainbow sample at the stub (optional)

Only relevant if you want to prove the native `react-native-rainbow-module`
SDK works against our stub.

1. Edit `c:\www\node\Rainbow-React-Native-Samples\android\app\src\main\assets\rainbow-config.json`
   so the first entry becomes:

   ```json
   {
       "HOST": "10.0.2.2:8443",
       "APP_ID": "65c681c01c8f11e9add8932b358ef81d",
       "SEC_KEY": "UYdu3wCXTdfyjImhURnIkZ0tac5J9XSLszIKBRUUWVB35b6nT3fWV2BhAGhojdBQ"
   }
   ```

2. Push the stub's TLS cert into the emulator's trust store (§4c).

3. Boot the stub, seed it, then:

   ```powershell
   cd c:\www\node\Rainbow-React-Native-Samples
   yarn install
   yarn android
   ```

4. Log in with the same `alice / password` credentials.

Expect some rough edges — the RN SDK exercises fields we may not have
tested against yet. Report what it complains about; each one becomes a
regression test on the stub side.

---

## 7. Common troubleshooting

| Symptom | Fix |
|---|---|
| `openssl: command not found` on stub boot | Install Git for Windows, or set `tls.enabled: false` in the yaml to fall back to HTTP |
| `TLS handshake failed` from the client | The stub regenerated its cert; either restart the client or trust the new `certs/rainbow-stub.crt` |
| `Address already in use` on port 8443 | `Get-Process dart | Stop-Process -Force` or change `port:` in the yaml |
| `dart:HttpClient` `Connection closed while receiving data` (Flutter multipart avatar upload) | Known Windows TIME_WAIT flake — retry. The stub returns 200 within 20 ms; the client just gives up too early |
| Chrome refuses the WS connection | Trust the cert for `https://localhost:8443` first (visit `/health` and click through) |
| Flutter build for Windows silently hangs | Install "Desktop development with C++" in the Visual Studio Installer |
| Android emulator can't reach `localhost:8443` | Use `10.0.2.2:8443` — emulators translate the host loopback that way |
| RN SDK returns `Unknown` login error | Almost always the app auth header. Confirm `APP_ID` and `SEC_KEY` match `config/rainbow-stub.yaml` `auth.appId`/`auth.appSecret` |
| Stub log says `oversize frame` and drops the WS | Client sent > 128 KB stanza. Raise `XmppLimits.maxFrameBytes` in `lib/src/xmpp/session.dart` if legitimate |
| Stub log says `too many SASL failures` | Wait a moment, connect a fresh WS. Cap is 3 per stream |

---

## 8. Reset the world

Wipe **all** stub state — DB, uploaded files, avatars, TLS certs:

```powershell
Remove-Item c:\www\dart\rainbow-stub\data,c:\www\dart\rainbow-stub\certs\rainbow-stub.crt,c:\www\dart\rainbow-stub\certs\rainbow-stub.key -Recurse -Force -ErrorAction SilentlyContinue
```

Next boot regenerates certs and creates an empty DB. Re-run
`dart run tool/seed.dart` to repopulate demo users.

---

## 9. Where things live

### rainbow-stub (Dart server)

| Path | What |
|---|---|
| `bin/server.dart` | Entry point, TLS auto-gen, SIGINT handler |
| `lib/src/app.dart` | Shelf pipeline, middleware, route mounting, `RainbowStubApp.shutdown()` |
| `lib/src/config/config.dart` | Config classes; loaded from `config/rainbow-stub.yaml` |
| `lib/src/auth/` | REST auth: login, logout, renew, self-register, reset-password |
| `lib/src/users/` | Users + roster + avatars + presence |
| `lib/src/bubbles/` | Rooms + members + group chat storage |
| `lib/src/files/` | File descriptors + upload/download |
| `lib/src/calllog/` | Call log entries |
| `lib/src/messages/` | 1:1 chat storage + MAM slice |
| `lib/src/events/event_pusher.dart` | XMPP push events on REST mutations |
| `lib/src/xmpp/session.dart` | XmppWsSession state machine, SM, MAM, MUC, ping, roster IQ, disco |
| `lib/src/xmpp/router.dart` | Per-user session registry + fan-out |
| `lib/src/xmpp/ws_server.dart` | shelf_web_socket adapter |
| `lib/src/metrics/metrics.dart` | Prometheus text-format registry |
| `lib/src/util/logging.dart` | JSON + text loggers |
| `lib/src/db/schema.sql` | SQLite tables |
| `test/` | 41 tests across auth, users, xmpp, bubbles/files/calllog, hardening, obs |
| `tool/` | seed, gen_cert, smoke scripts per phase |
| `config/rainbow-stub.yaml` | Tunables |
| `data/` (ignored) | Runtime SQLite + blobs |
| `certs/` (ignored) | Runtime TLS cert + key |

### rainbow_stub_consumer (Flutter client)

| Path | What |
|---|---|
| `lib/main.dart` | Entry — instantiates `RainbowConsumerApp(AppConfig.dev)` |
| `lib/app.dart` | `MaterialApp` + `_AuthGate` |
| `lib/config.dart` | `AppConfig.dev` — base URL, WS URL, `x-rainbow-app-auth` |
| `lib/rainbow/rest_client.dart` | HTTP client (self-signed accepted) |
| `lib/rainbow/xmpp_client.dart` | WebSocket + RFC 7395 XMPP + SASL PLAIN + bind |
| `lib/rainbow/models.dart` | Rainbow-shaped JSON models |
| `lib/state/rainbow_session.dart` | `ChangeNotifier` owning REST + XMPP |
| `lib/ui/` | Login, Home (Contacts + Bubbles tabs), Chat, BubbleChat |
| `test/models_test.dart` | Unit tests for JSON parsing |
| `test/live_stub_integration_test.dart` | End-to-end vs. running stub |

---

## 10. Where to look next

- **Grafana / Prometheus** — scrape `https://localhost:8443/metrics`
  and build a dashboard around `rainbow_stub_xmpp_sessions` and the
  HTTP histogram
- **Enable REST rate limits** — token bucket in front of `/login` to
  cover credential-stuffing (not yet implemented — see the roadmap in
  `README.md`)
- **Extend the Flutter consumer** — file uploads, avatars, message
  editing (XEP-0308), blocking (XEP-0191)
- **Add Android target** — `flutter create --platforms=android .` in
  the consumer folder, then follow §4c
