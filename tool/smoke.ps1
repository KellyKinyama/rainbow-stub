$ErrorActionPreference = 'Stop'
$base = 'http://localhost:8443'
$appAuth = 'Basic ' + [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes('65c681c01c8f11e9add8932b358ef81d:UYdu3wCXTdfyjImhURnIkZ0tac5J9XSLszIKBRUUWVB35b6nT3fWV2BhAGhojdBQ'))

function Show($title) { Write-Host ""; Write-Host "=== $title ===" -ForegroundColor Cyan }

Show 'health'
$h = Invoke-WebRequest "$base/health" -UseBasicParsing
Write-Host "status=$($h.StatusCode) body=$($h.Content)"

Show 'login (valid)'
$aliceBasic = 'Basic ' + [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes('alice@rainbow-stub.local:password'))
$login = Invoke-WebRequest "$base/api/rainbow/authentication/v1.0/login" -Headers @{ Authorization = $aliceBasic; 'x-rainbow-app-auth' = $appAuth } -UseBasicParsing
$loginJson = $login.Content | ConvertFrom-Json
Write-Host "status=$($login.StatusCode) userId=$($loginJson.loggedInUser.id) token=$($loginJson.token) expiresIn=$($loginJson.expiresIn)"

Show 'GET self'
$self = Invoke-WebRequest "$base/api/rainbow/enduser/v1.0/users/$($loginJson.loggedInUser.id)" -Headers @{ Authorization = "Bearer $($loginJson.token)" } -UseBasicParsing
$selfJson = $self.Content | ConvertFrom-Json
Write-Host "status=$($self.StatusCode) email=$($selfJson.data.loginEmail) displayName=$($selfJson.data.displayName)"

Show 'PUT self (update jobTitle)'
$put = Invoke-WebRequest "$base/api/rainbow/enduser/v1.0/users/$($loginJson.loggedInUser.id)" -Method Put -Headers @{ Authorization = "Bearer $($loginJson.token)"; 'content-type' = 'application/json' } -Body '{"jobTitle":"Product Owner"}' -UseBasicParsing
$putJson = $put.Content | ConvertFrom-Json
Write-Host "status=$($put.StatusCode) jobTitle=$($putJson.data.jobTitle)"

Show 'renew'
$ren = Invoke-WebRequest "$base/api/rainbow/authentication/v1.0/renew" -Headers @{ Authorization = "Bearer $($loginJson.token)" } -UseBasicParsing
$renJson = $ren.Content | ConvertFrom-Json
Write-Host "status=$($ren.StatusCode) newToken=$($renJson.token)"

Show 'old token now revoked'
try {
    Invoke-WebRequest "$base/api/rainbow/enduser/v1.0/users/$($loginJson.loggedInUser.id)" -Headers @{ Authorization = "Bearer $($loginJson.token)" } -UseBasicParsing | Out-Null
    Write-Host 'UNEXPECTED: revoked token still works'
} catch {
    Write-Host "status=$($_.Exception.Response.StatusCode.value__)"
}

Show 'login rejects wrong password'
try {
    $bad = 'Basic ' + [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes('alice@rainbow-stub.local:wrongpassword'))
    Invoke-WebRequest "$base/api/rainbow/authentication/v1.0/login" -Headers @{ Authorization = $bad; 'x-rainbow-app-auth' = $appAuth } -UseBasicParsing | Out-Null
    Write-Host 'UNEXPECTED: bad password accepted'
} catch {
    Write-Host "status=$($_.Exception.Response.StatusCode.value__)"
}

Show 'login rejects unknown app'
try {
    $badApp = 'Basic ' + [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes('nope:nope'))
    Invoke-WebRequest "$base/api/rainbow/authentication/v1.0/login" -Headers @{ Authorization = $aliceBasic; 'x-rainbow-app-auth' = $badApp } -UseBasicParsing | Out-Null
    Write-Host 'UNEXPECTED: bad app accepted'
} catch {
    Write-Host "status=$($_.Exception.Response.StatusCode.value__)"
}

Show 'self-register: send email'
$newEmail = "bob-$(Get-Random -Maximum 999999)@rainbow-stub.local"
$reg = Invoke-WebRequest "$base/api/rainbow/enduser/v1.0/users/self-register/send-email" -Method Post -Headers @{ 'x-rainbow-app-auth' = $appAuth; 'content-type' = 'application/json' } -Body "{`"email`":`"$newEmail`"}" -UseBasicParsing
$devTok = ($reg.Content | ConvertFrom-Json).data.devToken
Write-Host "status=$($reg.StatusCode) email=$newEmail devToken=$devTok"

Show 'self-register: validate token'
$val = Invoke-WebRequest "$base/api/rainbow/enduser/v1.0/users/self-register/validate-token" -Method Post -Headers @{ 'x-rainbow-app-auth' = $appAuth; 'content-type' = 'application/json' } -Body "{`"token`":`"$devTok`"}" -UseBasicParsing
Write-Host "status=$($val.StatusCode) body=$($val.Content)"

Show 'self-register: create account'
$body = @{ token = $devTok; password = 'secret'; firstName = 'Bob'; lastName = 'Marley' } | ConvertTo-Json -Compress
$create = Invoke-WebRequest "$base/api/rainbow/enduser/v1.0/users/self-register" -Method Post -Headers @{ 'x-rainbow-app-auth' = $appAuth; 'content-type' = 'application/json' } -Body $body -UseBasicParsing
$createJson = $create.Content | ConvertFrom-Json
Write-Host "status=$($create.StatusCode) newId=$($createJson.data.id) email=$($createJson.data.loginEmail)"

Show 'login as new user'
$bobBasic = 'Basic ' + [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes("$($newEmail):secret"))
$bl = Invoke-WebRequest "$base/api/rainbow/authentication/v1.0/login" -Headers @{ Authorization = $bobBasic; 'x-rainbow-app-auth' = $appAuth } -UseBasicParsing
$blJson = $bl.Content | ConvertFrom-Json
Write-Host "status=$($bl.StatusCode) displayName=$($blJson.loggedInUser.displayName)"

Show 'reset password: send email'
$rp = Invoke-WebRequest "$base/api/rainbow/enduser/v1.0/users/reset-password/send-email" -Method Post -Headers @{ 'x-rainbow-app-auth' = $appAuth; 'content-type' = 'application/json' } -Body "{`"email`":`"$newEmail`"}" -UseBasicParsing
$rpTok = ($rp.Content | ConvertFrom-Json).data.devToken
Write-Host "status=$($rp.StatusCode) resetToken=$rpTok"

Show 'reset password: apply'
$rpBody = @{ token = $rpTok; password = 'brandnew' } | ConvertTo-Json -Compress
$rpApply = Invoke-WebRequest "$base/api/rainbow/enduser/v1.0/users/reset-password" -Method Post -Headers @{ 'x-rainbow-app-auth' = $appAuth; 'content-type' = 'application/json' } -Body $rpBody -UseBasicParsing
Write-Host "status=$($rpApply.StatusCode) body=$($rpApply.Content)"

Show 'login with new password'
$bobBasic2 = 'Basic ' + [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes("$($newEmail):brandnew"))
$bl2 = Invoke-WebRequest "$base/api/rainbow/authentication/v1.0/login" -Headers @{ Authorization = $bobBasic2; 'x-rainbow-app-auth' = $appAuth } -UseBasicParsing
Write-Host "status=$($bl2.StatusCode) userId=$((($bl2.Content | ConvertFrom-Json).loggedInUser).id)"

Show 'logout'
$lo = Invoke-WebRequest "$base/api/rainbow/authentication/v1.0/logout" -Method Post -Headers @{ Authorization = "Bearer $($bl2.Content | ConvertFrom-Json | Select-Object -ExpandProperty token)" } -UseBasicParsing
Write-Host "status=$($lo.StatusCode) body=$($lo.Content)"

Write-Host ""
Write-Host 'ALL CHECKS DONE' -ForegroundColor Green
