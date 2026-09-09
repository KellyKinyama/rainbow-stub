$ErrorActionPreference = 'Stop'
$base = 'http://localhost:8443'
$appAuth = 'Basic ' + [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes('65c681c01c8f11e9add8932b358ef81d:UYdu3wCXTdfyjImhURnIkZ0tac5J9XSLszIKBRUUWVB35b6nT3fWV2BhAGhojdBQ'))

function Show($title) { Write-Host ''; Write-Host "=== $title ===" -ForegroundColor Cyan }

Show 'login as alice'
$aliceBasic = 'Basic ' + [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes('alice@rainbow-stub.local:password'))
$login = Invoke-WebRequest "$base/api/rainbow/authentication/v1.0/login" -Headers @{ Authorization = $aliceBasic; 'x-rainbow-app-auth' = $appAuth } -UseBasicParsing
$loginJson = $login.Content | ConvertFrom-Json
$aliceId = $loginJson.loggedInUser.id
$token = $loginJson.token
$hdr = @{ Authorization = "Bearer $token" }
Write-Host "status=$($login.StatusCode) aliceId=$aliceId presence.show=$($loginJson.loggedInUser.presence.show)"

Show 'roster (alice.networks)'
$nets = Invoke-WebRequest "$base/api/rainbow/enduser/v1.0/users/networks" -Headers $hdr -UseBasicParsing
$netsJson = $nets.Content | ConvertFrom-Json
Write-Host "status=$($nets.StatusCode) total=$($netsJson.total)"
foreach ($e in $netsJson.data) {
    Write-Host ('  peer=' + $e.peerUser.displayName + ' <' + $e.peerUser.loginEmail + '> presence=' + $e.peerUser.presence.show)
}

Show 'search users containing "car"'
$srch = Invoke-WebRequest "$base/api/rainbow/enduser/v1.0/users?search=car" -Headers $hdr -UseBasicParsing
$srchJson = $srch.Content | ConvertFrom-Json
Write-Host "status=$($srch.StatusCode) total=$($srchJson.total) first=$($srchJson.data[0].displayName)"

Show 'get arbitrary user (bob) by id'
$bobId = ($netsJson.data | Where-Object { $_.peerUser.loginEmail -eq 'bob@rainbow-stub.local' }).peerId
$bob = Invoke-WebRequest "$base/api/rainbow/enduser/v1.0/users/$bobId" -Headers $hdr -UseBasicParsing
$bobJson = ($bob.Content | ConvertFrom-Json).data
Write-Host "status=$($bob.StatusCode) bob.id=$($bobJson.id) presence=$($bobJson.presence.show)"

Show 'set my presence to dnd/heads-down'
$pres = Invoke-WebRequest "$base/api/rainbow/enduser/v1.0/users/$aliceId/presences" -Method Post -Headers ($hdr + @{ 'content-type' = 'application/json' }) -Body '{"show":"dnd","status":"heads-down"}' -UseBasicParsing
Write-Host "status=$($pres.StatusCode) presence=$((($pres.Content | ConvertFrom-Json).data).presence.show)"

Show 'upload avatar (multipart via curl)'
$png = [Convert]::FromBase64String('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNkYAAAAAYAAjCB0C8AAAAASUVORK5CYII=')
$pngPath = Join-Path $env:TEMP 'rainbow-stub-a.png'
$bodyPath = Join-Path $env:TEMP 'rainbow-stub-up-resp.json'
[IO.File]::WriteAllBytes($pngPath, $png)
$httpCode = curl.exe -s -o $bodyPath -w '%{http_code}' `
    -H "Authorization: Bearer $token" `
    -F "photo=@${pngPath};type=image/png" `
    "$base/api/rainbow/enduser/v1.0/users/$aliceId/photo"
$upJson = (Get-Content -Raw $bodyPath | ConvertFrom-Json).data
Write-Host "status=$httpCode lastAvatarUpdateDate=$($upJson.lastAvatarUpdateDate)"

Show 'download avatar bytes'
$av = Invoke-WebRequest "$base/api/rainbow/enduser/v1.0/users/$aliceId/avatar" -Headers $hdr -UseBasicParsing
Write-Host ('status=' + $av.StatusCode + ' bytes=' + $av.RawContentLength + ' content-type=' + $av.Headers.'Content-Type')

Show 'add + remove roster entry (dave)'
$daveId = ($netsJson.data | Where-Object { $_.peerUser.loginEmail -eq 'dave@rainbow-stub.local' }).peerId
$del = Invoke-WebRequest "$base/api/rainbow/enduser/v1.0/users/networks/$daveId" -Method Delete -Headers $hdr -UseBasicParsing
Write-Host "delete dave status=$($del.StatusCode)"
$add = Invoke-WebRequest "$base/api/rainbow/enduser/v1.0/users/networks/$daveId" -Method Post -Headers $hdr -UseBasicParsing
Write-Host "add dave status=$($add.StatusCode)"

Write-Host ''
Write-Host 'PHASE 2 CHECKS DONE' -ForegroundColor Green
