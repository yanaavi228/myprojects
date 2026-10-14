# Настройка хостинга на этом компьютере. Запустить ОДИН РАЗ от имени администратора:
# правый клик по файлу -> "Выполнить с PowerShell" (от администратора)
# или: powershell -ExecutionPolicy Bypass -File setup-hosting.ps1 (в консоли администратора)

$ErrorActionPreference = 'Stop'
if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host 'Нужны права администратора. Запустите PowerShell от имени администратора и повторите.' -ForegroundColor Red
    exit 1
}

$port = 8585
$dir = $PSScriptRoot

# 1. Брандмауэр: разрешить входящие подключения на порт сайта
if (-not (Get-NetFirewallRule -DisplayName 'SQL Trainer 8585' -ErrorAction SilentlyContinue)) {
    New-NetFirewallRule -DisplayName 'SQL Trainer 8585' -Direction Inbound -Protocol TCP -LocalPort $port -Action Allow | Out-Null
    Write-Host "[OK] Брандмауэр: порт $port открыт для входящих"
} else {
    Write-Host '[--] Правило брандмауэра уже существует'
}

# 2. Автозапуск сервера при входе в Windows (скрытое окно)
$action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$dir\server.ps1`""
$trigger = New-ScheduledTaskTrigger -AtLogOn
Register-ScheduledTask -TaskName 'SQLTrainerServer' -Action $action -Trigger $trigger -Force | Out-Null
Write-Host '[OK] Автозапуск: сервер будет стартовать при входе в Windows'

# 3. Запустить сервер прямо сейчас, если ещё не запущен
$up = Test-NetConnection -ComputerName localhost -Port $port -InformationLevel Quiet -WarningAction SilentlyContinue
if (-not $up) {
    Start-Process powershell -ArgumentList "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$dir\server.ps1`""
    Write-Host '[OK] Сервер запущен'
}

$ip = (Get-NetIPAddress -AddressFamily IPv4 | Where-Object { $_.IPAddress -notlike '127.*' -and $_.PrefixOrigin -ne 'WellKnown' } | Select-Object -First 1).IPAddress
Write-Host ''
Write-Host "Готово! Сайт доступен в вашей сети: http://${ip}:$port/" -ForegroundColor Green
Write-Host 'Совет: закрепите этот IP за компьютером в настройках роутера (резервирование DHCP), чтобы адрес не менялся.'
Write-Host 'Чтобы открыть доступ из интернета, запустите share-public.ps1'
