$root = $PSScriptRoot
$listener = New-Object System.Net.Sockets.TcpListener([System.Net.IPAddress]::Any, 8585)
$listener.Start()
$ip = (Get-NetIPAddress -AddressFamily IPv4 | Where-Object { $_.IPAddress -notlike '127.*' -and $_.PrefixOrigin -ne 'WellKnown' } | Select-Object -First 1).IPAddress
Write-Host 'Server: http://localhost:8585/'
if ($ip) { Write-Host "LAN:    http://${ip}:8585/  (для других устройств в этой сети)" }
$handler = {
    param($client, $root)
    $mime = @{ '.html'='text/html; charset=utf-8'; '.js'='text/javascript; charset=utf-8'; '.css'='text/css; charset=utf-8'; '.png'='image/png'; '.jpg'='image/jpeg'; '.svg'='image/svg+xml'; '.ico'='image/x-icon' }
    $usersFile = Join-Path $root 'users.json'
    $mu = New-Object System.Threading.Mutex($false, 'SQLTrainerUsers')

    function Send-Json($stream, $code, $obj) {
        $bytes = [System.Text.Encoding]::UTF8.GetBytes((ConvertTo-Json $obj -Compress -Depth 6))
        $head = [System.Text.Encoding]::ASCII.GetBytes("HTTP/1.1 $code`r`nContent-Type: application/json; charset=utf-8`r`nContent-Length: $($bytes.Length)`r`nConnection: close`r`n`r`n")
        $stream.Write($head, 0, $head.Length); $stream.Write($bytes, 0, $bytes.Length)
    }
    function Get-HashPw($pw, $salt) {
        try { $k = New-Object System.Security.Cryptography.Rfc2898DeriveBytes($pw, [System.Text.Encoding]::UTF8.GetBytes($salt), 100000, [System.Security.Cryptography.HashAlgorithmName]::SHA256) }
        catch { $k = New-Object System.Security.Cryptography.Rfc2898DeriveBytes($pw, [System.Text.Encoding]::UTF8.GetBytes($salt), 100000) }
        ([BitConverter]::ToString($k.GetBytes(32))).Replace('-', '').ToLower()
    }
    function Load-Users {
        $users = @{}
        if (Test-Path $usersFile) {
            try {
                $o = Get-Content $usersFile -Raw -Encoding UTF8 | ConvertFrom-Json
                foreach ($pr in $o.PSObject.Properties) { $users[$pr.Name] = @{ salt = '' + $pr.Value.salt; hash = '' + $pr.Value.hash } }
            } catch {}
        }
        return $users
    }
    function Check-Auth($u, $h) {
        $users = Load-Users
        return ($users.ContainsKey($u) -and $users[$u].hash -eq $h -and $h.Length -gt 0)
    }

    try {
        $client.ReceiveTimeout = 5000
        $client.SendTimeout = 5000
        $client.NoDelay = $true
        $stream = $client.GetStream()
        $buf = New-Object byte[] 8192
        $ms = New-Object System.IO.MemoryStream
        $headEnd = -1; $len = 0
        try {
            while ($true) {
                $n = $stream.Read($buf, 0, 8192)
                if ($n -le 0) { break }
                $ms.Write($buf, 0, $n)
                $all = $ms.ToArray()
                if ($headEnd -lt 0) {
                    $txt = [System.Text.Encoding]::ASCII.GetString($all)
                    $idx = $txt.IndexOf("`r`n`r`n")
                    if ($idx -ge 0) {
                        $headEnd = $idx + 4
                        if ($txt -match '(?im)^Content-Length:\s*(\d+)') { $len = [Math]::Min([int]$Matches[1], 1048576) }
                    }
                }
                if ($headEnd -ge 0 -and $all.Length -ge $headEnd + $len) { break }
                if ($all.Length -gt 2097152) { break }
            }
        } catch [System.IO.IOException] {}
        $all = $ms.ToArray()
        $req = ''; $body = ''
        if ($headEnd -ge 0) {
            $req = [System.Text.Encoding]::ASCII.GetString($all, 0, $headEnd)
            $take = [Math]::Min($all.Length - $headEnd, $len)
            if ($take -gt 0) { $body = [System.Text.Encoding]::UTF8.GetString($all, $headEnd, $take) }
        } else {
            $req = [System.Text.Encoding]::ASCII.GetString($all)
        }

        $method = ''; $target = ''
        if ($req -match '(?m)^(GET|POST)\s+([^\s]+)') { $method = $Matches[1]; $target = $Matches[2] }
        $path = [System.Uri]::UnescapeDataString(($target -split '\?')[0]).TrimStart('/')
        $query = @{}
        if ($target -match '\?(.+)$') {
            foreach ($pair in $Matches[1].Split('&')) {
                $kv = $pair.Split('=', 2)
                if ($kv.Count -eq 2) { $query[[System.Uri]::UnescapeDataString($kv[0])] = [System.Uri]::UnescapeDataString($kv[1]) }
            }
        }

        # ----- API: общие аккаунты и песочницы на сервере -----
        if ($path -match '^api/') {
            try {
                if ($path -eq 'api/ping') { Send-Json $stream '200 OK' @{ ok = $true } }
                elseif ($path -eq 'api/auth' -and $method -eq 'POST') {
                    $d = $body | ConvertFrom-Json
                    $u = ('' + $d.u).ToLower().Trim()
                    $p = '' + $d.p
                    if ($u -notmatch '^[a-z0-9_.-]{3,20}$') { Send-Json $stream '400 Bad Request' @{ error = 'Некорректный логин.' } }
                    elseif ($p.Length -lt 6) { Send-Json $stream '400 Bad Request' @{ error = 'Пароль не короче 6 символов.' } }
                    else {
                        $mu.WaitOne()
                        try {
                            $users = Load-Users
                            if ($d.op -eq 'reg') {
                                if ($users.ContainsKey($u)) { Send-Json $stream '409 Conflict' @{ error = 'Такой логин уже занят.' } }
                                else {
                                    $salt = [Guid]::NewGuid().ToString('N')
                                    $h = Get-HashPw $p $salt
                                    $users[$u] = @{ salt = $salt; hash = $h }
                                    [System.IO.File]::WriteAllText($usersFile, (ConvertTo-Json $users -Compress -Depth 6), (New-Object System.Text.UTF8Encoding($false)))
                                    Send-Json $stream '200 OK' @{ ok = $true; h = $h }
                                }
                            } else {
                                if (-not $users.ContainsKey($u) -or (Get-HashPw $p $users[$u].salt) -ne $users[$u].hash) { Send-Json $stream '403 Forbidden' @{ error = 'Неверный логин или пароль.' } }
                                else { Send-Json $stream '200 OK' @{ ok = $true; h = $users[$u].hash } }
                            }
                        } finally { $mu.ReleaseMutex() }
                    }
                }
                elseif ($path -eq 'api/sandbox') {
                    $u = ''; $h = ''; $logIn = @()
                    if ($method -eq 'GET') { $u = ('' + $query['u']).ToLower(); $h = '' + $query['h'] }
                    else { $d = $body | ConvertFrom-Json; $u = ('' + $d.u).ToLower(); $h = '' + $d.h; $logIn = @($d.log) }
                    $sbFile = Join-Path $root ('sb-' + ($u -replace '[^a-z0-9_.-]', '') + '.json')
                    if (-not (Check-Auth $u $h)) { Send-Json $stream '403 Forbidden' @{ error = 'Нет доступа.' } }
                    elseif ($method -eq 'GET') {
                        $log = @()
                        if (Test-Path $sbFile) { try { $log = @((Get-Content $sbFile -Raw -Encoding UTF8 | ConvertFrom-Json).log) } catch {} }
                        Send-Json $stream '200 OK' @{ ok = $true; log = $log }
                    }
                    elseif ($method -eq 'POST') {
                        $mu.WaitOne()
                        try {
                            [System.IO.File]::WriteAllText($sbFile, (ConvertTo-Json @{ log = $logIn } -Compress -Depth 6), (New-Object System.Text.UTF8Encoding($false)))
                            Send-Json $stream '200 OK' @{ ok = $true }
                        } finally { $mu.ReleaseMutex() }
                    }
                    else { Send-Json $stream '405 Method Not Allowed' @{ error = 'Метод не поддерживается.' } }
                }
                else { Send-Json $stream '404 Not Found' @{ error = 'Неизвестный API.' } }
            } catch { Send-Json $stream '500 Internal Server Error' @{ error = 'Ошибка сервера.' } }
            $stream.Flush()
            try { $client.Close() } catch {}
            return
        }

        # ----- Статика -----
        if ([string]::IsNullOrEmpty($path)) { $path = 'index.html' }
        $file = Join-Path $root $path
        if ($method -eq 'GET' -and (Test-Path $file -PathType Leaf) -and $path -notmatch '\.\.') {
            $bytes = [System.IO.File]::ReadAllBytes($file)
            $ctype = $mime[[System.IO.Path]::GetExtension($file).ToLower()]
            if (-not $ctype) { $ctype = 'application/octet-stream' }
            $head = [System.Text.Encoding]::ASCII.GetBytes("HTTP/1.1 200 OK`r`nContent-Type: $ctype`r`nContent-Length: $($bytes.Length)`r`nCache-Control: no-cache`r`nConnection: close`r`n`r`n")
            $stream.Write($head, 0, $head.Length)
            $stream.Write($bytes, 0, $bytes.Length)
        } else {
            $head = [System.Text.Encoding]::ASCII.GetBytes("HTTP/1.1 404 Not Found`r`nContent-Length: 0`r`nConnection: close`r`n`r`n")
            $stream.Write($head, 0, $head.Length)
        }
        $stream.Flush()
    } catch { try { [System.IO.File]::AppendAllText((Join-Path $root 'server-error.log'), ("$(Get-Date -Format o) " + ($_ | Out-String) + "`n")) } catch {} }
    try { $client.Close() } catch {}
}

# Несколько посетителей одновременно: каждое подключение обрабатывается в своём потоке
$pool = [runspacefactory]::CreateRunspacePool(1, 32)
$pool.Open()
$jobs = New-Object System.Collections.ArrayList
while ($true) {
    $client = $listener.AcceptTcpClient()
    $ps = [powershell]::Create()
    $ps.RunspacePool = $pool
    $ps.AddScript($handler).AddArgument($client).AddArgument($root) | Out-Null
    $jobs.Add(@{ ps = $ps; h = $ps.BeginInvoke() }) | Out-Null
    for ($i = $jobs.Count - 1; $i -ge 0; $i--) {
        if ($jobs[$i].h.IsCompleted) { $jobs[$i].ps.Dispose(); $jobs.RemoveAt($i) }
    }
}
