$ErrorActionPreference = 'Stop'
$base = 'http://localhost:8443'
$appAuth = 'Basic ' + [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes('65c681c01c8f11e9add8932b358ef81d:UYdu3wCXTdfyjImhURnIkZ0tac5J9XSLszIKBRUUWVB35b6nT3fWV2BhAGhojdBQ'))

function Show($t) { Write-Host ''; Write-Host "=== $t ===" -ForegroundColor Cyan }

Show 'login alice'
$aliceBasic = 'Basic ' + [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes('alice@rainbow-stub.local:password'))
$login = Invoke-WebRequest "$base/api/rainbow/authentication/v1.0/login" -Headers @{ Authorization = $aliceBasic; 'x-rainbow-app-auth' = $appAuth } -UseBasicParsing
$loginJson = $login.Content | ConvertFrom-Json
$aliceId = $loginJson.loggedInUser.id
$token = $loginJson.token
$hdr = @{ Authorization = "Bearer $token" }
Write-Host "aliceId=$aliceId"

Show 'GET /rooms (existing bubbles for alice)'
$rooms = Invoke-WebRequest "$base/api/rainbow/enduser/v1.0/rooms" -Headers $hdr -UseBasicParsing
$roomsJson = $rooms.Content | ConvertFrom-Json
Write-Host "status=$($rooms.StatusCode) total=$($roomsJson.total)"
foreach ($b in $roomsJson.data) { Write-Host "  $($b.name) (id=$($b.id)) members=$($b.users.Count)" }

Show 'POST /rooms (create Smoke Room)'
$create = Invoke-WebRequest "$base/api/rainbow/enduser/v1.0/rooms" -Method Post -Headers ($hdr + @{ 'content-type' = 'application/json' }) -Body '{"name":"Smoke Room","topic":"live smoke"}' -UseBasicParsing
$newB = ($create.Content | ConvertFrom-Json).data
Write-Host "status=$($create.StatusCode) bubbleId=$($newB.id)"

Show 'invite bob'
$bobLogin = Invoke-WebRequest "$base/api/rainbow/authentication/v1.0/login" -Headers @{ Authorization = ('Basic ' + [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes('bob@rainbow-stub.local:password'))); 'x-rainbow-app-auth' = $appAuth } -UseBasicParsing
$bobId = ($bobLogin.Content | ConvertFrom-Json).loggedInUser.id
$inv = Invoke-WebRequest "$base/api/rainbow/enduser/v1.0/rooms/$($newB.id)/users" -Method Post -Headers ($hdr + @{ 'content-type' = 'application/json' }) -Body "{`"userId`":`"$bobId`"}" -UseBasicParsing
Write-Host "status=$($inv.StatusCode)"

Show 'bob accepts'
$bobHdr = @{ Authorization = "Bearer $((($bobLogin.Content | ConvertFrom-Json).token))" }
$acc = Invoke-WebRequest "$base/api/rainbow/enduser/v1.0/rooms/$($newB.id)/users/$bobId" -Method Put -Headers ($bobHdr + @{ 'content-type' = 'application/json' }) -Body '{"status":"accepted"}' -UseBasicParsing
Write-Host "status=$($acc.StatusCode) member status=$((($acc.Content | ConvertFrom-Json).data.users | Where-Object userId -eq $bobId).status)"

Show 'file: create descriptor + upload + download'
$desc = Invoke-WebRequest "$base/api/rainbow/fileServer/v1.0/files" -Method Post -Headers ($hdr + @{ 'content-type' = 'application/json' }) -Body "{`"peer`":`"$bobId@localhost`",`"peerType`":`"user`",`"fileName`":`"notes.txt`",`"mime`":`"text/plain`"}" -UseBasicParsing
$fileId = ($desc.Content | ConvertFrom-Json).data.id
Write-Host "descriptor status=$($desc.StatusCode) fileId=$fileId"

$tmp = Join-Path $env:TEMP 'rainbow-stub-smoke-notes.txt'
'hello from smoke' | Out-File -Encoding ascii $tmp -NoNewline
$up = curl.exe -s -o - -w '%{http_code}' -X PUT -H "Authorization: Bearer $token" -H 'content-type: text/plain' --data-binary "@$tmp" "$base/api/rainbow/fileServer/v1.0/files/$fileId/data"
Write-Host "upload http=$($up.Substring($up.Length - 3))"

$body = curl.exe -s -H "Authorization: Bearer $token" "$base/api/rainbow/fileServer/v1.0/files/$fileId/data"
Write-Host "download body='$body'"

Show 'GET /rooms (should include Smoke Room)'
$rooms2 = Invoke-WebRequest "$base/api/rainbow/enduser/v1.0/rooms" -Headers $hdr -UseBasicParsing
$rooms2Json = $rooms2.Content | ConvertFrom-Json
Write-Host "total=$($rooms2Json.total)"

Show 'call log (seeded 2 entries)'
$calls = Invoke-WebRequest "$base/api/rainbow/enduser/v1.0/users/$aliceId/calllogs" -Headers $hdr -UseBasicParsing
$callsJson = $calls.Content | ConvertFrom-Json
Write-Host "status=$($calls.StatusCode) total=$($callsJson.total) unreadMissed=$($callsJson.unreadMissed)"
foreach ($c in $callsJson.data) { Write-Host "  $($c.direction) $($c.state) $($c.peerDisplayName) $($c.duration)ms" }

Write-Host ''
Write-Host 'PHASE 4 CHECKS DONE' -ForegroundColor Green
