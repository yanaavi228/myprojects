# Публичная ссылка через бесплатный туннель Cloudflare.
# Сайт станет доступен из интернета по адресу вида https://xxxx.trycloudflare.com
# Работает, пока открыто это окно и включён компьютер. Остановить: Ctrl+C

$port = 8585

# 1. Локальный сервер должен быть запущен
$up = Test-NetConnection -ComputerName localhost -Port $port -InformationLevel Quiet -WarningAction SilentlyContinue
if (-not $up) {
    Write-Host 'Запускаю локальный сервер...'
    Start-Process powershell -ArgumentList "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$PSScriptRoot\server.ps1`""
    Start-Sleep -Seconds 1
}

# 2. cloudflared: проверить, при необходимости установить через winget
$cf = Get-Command cloudflared -ErrorAction SilentlyContinue
if (-not $cf) {
    Write-Host 'Устанавливаю cloudflared через winget...'
    winget install -e --id Cloudflare.cloudflared --accept-source-agreements --accept-package-agreements --silent
    $env:Path = [System.Environment]::GetEnvironmentVariable('Path', 'Machine') + ';' + [System.Environment]::GetEnvironmentVariable('Path', 'User')
    $cf = Get-Command cloudflared -ErrorAction SilentlyContinue
    if (-not $cf) {
        Write-Host 'Не удалось установить cloudflared автоматически.' -ForegroundColor Red
        Write-Host 'Установите вручную: winget install Cloudflare.cloudflared'
        exit 1
    }
}

Write-Host ''
Write-Host 'Туннель запускается. Ниже появится публичная ссылка вида https://xxxx.trycloudflare.com' -ForegroundColor Green
Write-Host 'Отправляйте её кому угодно. Ссылка живёт, пока открыто это окно.'
Write-Host ''
cloudflared tunnel --url "http://localhost:$port"
