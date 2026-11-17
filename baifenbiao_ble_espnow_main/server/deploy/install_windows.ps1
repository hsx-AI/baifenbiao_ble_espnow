#Requires -RunAsAdministrator
<#
.SYNOPSIS
  Offline deploy Percent Meter gateway to Windows with NSSM auto-start service.

.PARAMETER InstallDir
  Install path, default C:\PercentMeter

.PARAMETER SerialPort
  Gateway serial port, e.g. COM11. Leave empty for auto-detect.

.PARAMETER ServiceName
  Windows service name, default PercentMeter
#>
param(
    [string]$InstallDir = "C:\PercentMeter",
    [string]$SerialPort = "",
    [string]$ServiceName = "PercentMeter"
)

$ErrorActionPreference = "Stop"

$DeployDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$ServerDir = Split-Path -Parent $DeployDir
$WheelsDir = Join-Path $DeployDir "wheels"
$EmbedDir = Join-Path $DeployDir "python-embed"
$NssmExe = Join-Path $DeployDir "nssm\nssm.exe"

function Write-Step([string]$Message) {
    Write-Host "[*] $Message" -ForegroundColor Cyan
}

function Ensure-OfflineAssets {
    if (-not (Test-Path -LiteralPath $WheelsDir)) {
        throw "Missing wheels folder: $WheelsDir. Run prepare_offline_windows.ps1 first."
    }
    $wheelCount = @(Get-ChildItem -LiteralPath $WheelsDir -Filter "*.whl" -ErrorAction SilentlyContinue).Count
    if ($wheelCount -eq 0) {
        throw "wheels folder is empty. Run prepare_offline_windows.ps1 first."
    }
    if (-not (Test-Path -LiteralPath $NssmExe)) {
        throw "Missing NSSM: $NssmExe. Run prepare_offline_windows.ps1 first."
    }
    if (-not (Test-Path -LiteralPath $EmbedDir)) {
        throw "Missing embedded Python: $EmbedDir. Run prepare_offline_windows.ps1 first."
    }
}

function Invoke-Nssm {
    param(
        [Parameter(Mandatory = $true)][string]$Exe,
        [Parameter(ValueFromRemainingArguments = $true)][string[]]$NssmArgs
    )
    # NSSM prints normal status to stderr; with ErrorActionPreference=Stop that becomes a fatal error.
    $previous = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    $output = & $Exe @NssmArgs 2>&1
    $code = $LASTEXITCODE
    $ErrorActionPreference = $previous
    return [pscustomobject]@{
        ExitCode = $code
        Output   = @($output | ForEach-Object { "$_" })
    }
}

function Remove-WindowsService([string]$Name) {
    $existing = Get-Service -Name $Name -ErrorAction SilentlyContinue
    if (-not $existing) { return }

    Write-Step "Stop/remove existing service: $Name"
    # Prefer sc.exe so NSSM stderr cannot abort the script.
    if ($existing.Status -ne "Stopped") {
        sc.exe stop $Name | Out-Null
        $deadline = (Get-Date).AddSeconds(20)
        do {
            Start-Sleep -Milliseconds 400
            $existing = Get-Service -Name $Name -ErrorAction SilentlyContinue
        } while ($existing -and $existing.Status -ne "Stopped" -and (Get-Date) -lt $deadline)
    }

    sc.exe delete $Name | Out-Null
    $deadline = (Get-Date).AddSeconds(15)
    do {
        Start-Sleep -Milliseconds 400
        $existing = Get-Service -Name $Name -ErrorAction SilentlyContinue
    } while ($existing -and (Get-Date) -lt $deadline)

    if (Get-Service -Name $Name -ErrorAction SilentlyContinue) {
        throw "Failed to remove existing service $Name. Close services.msc and retry."
    }
}

function Copy-ServerFiles([string]$Target) {
    Write-Step "Copy server files to $Target"
    if (Test-Path -LiteralPath $Target) {
        Remove-Item -LiteralPath $Target -Recurse -Force
    }
    New-Item -ItemType Directory -Path $Target -Force | Out-Null

    $exclude = @("deploy", "__pycache__", "meter_history.db", "meter_history.db-shm", "meter_history.db-wal")
    Get-ChildItem -LiteralPath $ServerDir -Force | Where-Object {
        $exclude -notcontains $_.Name
    } | ForEach-Object {
        Copy-Item -LiteralPath $_.FullName -Destination $Target -Recurse -Force
    }
}

function Invoke-Pip([string]$PythonExe, [string[]]$PipArgs) {
    $previous = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    & $PythonExe -m pip @PipArgs 2>&1 | ForEach-Object {
        $line = "$_"
        # Hide PATH script warnings; they are normal for embedded Python.
        if ($line -match "which is not on PATH" -or $line -match "Consider adding this directory to PATH" -or $line -match "no-warn-script-location") {
            return
        }
        Write-Host $line
    }
    $code = $LASTEXITCODE
    $ErrorActionPreference = $previous
    if ($code -ne 0) {
        throw "pip failed with exit code $code"
    }
}

function Setup-EmbeddedPython([string]$Target) {
    Write-Step "Install embedded Python"
    $pythonRoot = Join-Path $Target "python"
    if (Test-Path -LiteralPath $pythonRoot) {
        Remove-Item -LiteralPath $pythonRoot -Recurse -Force
    }
    Copy-Item -LiteralPath $EmbedDir -Destination $pythonRoot -Recurse -Force

    $pthFiles = Get-ChildItem -LiteralPath $pythonRoot -Filter "python*._pth"
    foreach ($pth in $pthFiles) {
        $content = Get-Content -LiteralPath $pth.FullName
        $content = $content | ForEach-Object {
            if ($_ -match '^\s*#\s*import site') { 'import site' } else { $_ }
        }
        if ($content -notcontains 'import site') {
            $content += 'import site'
        }
        Set-Content -LiteralPath $pth.FullName -Value $content -Encoding ASCII
    }

    $pythonExe = Join-Path $pythonRoot "python.exe"
    if (-not (Test-Path -LiteralPath $pythonExe)) {
        throw "python.exe not found: $pythonExe"
    }

    $getPip = Join-Path $DeployDir "get-pip.py"
    if (Test-Path -LiteralPath $getPip) {
        Write-Step "Bootstrap pip (offline)"
        $previous = $ErrorActionPreference
        $ErrorActionPreference = "Continue"
        & $pythonExe $getPip --no-warn-script-location --no-index --find-links $WheelsDir 2>&1 | ForEach-Object {
            $line = "$_"
            if ($line -match "which is not on PATH" -or $line -match "Consider adding this directory to PATH") { return }
            Write-Host $line
        }
        if ($LASTEXITCODE -ne 0) { throw "get-pip.py failed with exit code $LASTEXITCODE" }
        $ErrorActionPreference = $previous
    }

    Write-Step "Install Python packages (offline)"
    $common = @(
        "install",
        "--no-index",
        "--find-links", $WheelsDir,
        "--no-warn-script-location",
        "--disable-pip-version-check"
    )
    Invoke-Pip $pythonExe ($common + @("pip", "setuptools", "wheel"))
    Invoke-Pip $pythonExe ($common + @("-r", (Join-Path $Target "requirements.txt")))
    return $pythonExe
}

function Write-ServiceEnv([string]$Target, [string]$Port) {
    $envFile = Join-Path $Target "service.env"
    $lines = @(
        "# PercentMeter service env (restart service after edit)",
        "SIMULATE=0",
        "SERIAL_BAUD=115200"
    )
    if ($Port) {
        $lines += "SERIAL_PORT=$Port"
    } else {
        $lines += "# SERIAL_PORT=COM11"
        $lines += "SERIAL_PORT="
    }
    Set-Content -LiteralPath $envFile -Value ($lines -join "`r`n") -Encoding ASCII
    return $envFile
}

function Install-NssmService(
    [string]$Name,
    [string]$PythonExe,
    [string]$WorkDir,
    [string]$EnvFile
) {
    Write-Step "Register Windows auto-start service: $Name"

    $installedNssm = Join-Path $WorkDir "nssm.exe"
    Copy-Item -LiteralPath $NssmExe -Destination $installedNssm -Force

    # Ensure a clean slate without calling "nssm stop" (stderr breaks PowerShell Stop mode).
    Remove-WindowsService -Name $Name

    $result = Invoke-Nssm -Exe $installedNssm install $Name $PythonExe "-m" "uvicorn" "app:app" "--host" "0.0.0.0" "--port" "8000"
    if ($result.ExitCode -ne 0) {
        throw "nssm install failed: $($result.Output -join ' ')"
    }

    $null = Invoke-Nssm -Exe $installedNssm set $Name AppDirectory $WorkDir
    $null = Invoke-Nssm -Exe $installedNssm set $Name DisplayName "Percent Meter Gateway"
    $null = Invoke-Nssm -Exe $installedNssm set $Name Description "BLE dial indicator gateway (FastAPI/WebSocket)"
    $null = Invoke-Nssm -Exe $installedNssm set $Name Start SERVICE_DELAYED_AUTO_START
    $null = Invoke-Nssm -Exe $installedNssm set $Name AppStdout (Join-Path $WorkDir "logs\service.out.log")
    $null = Invoke-Nssm -Exe $installedNssm set $Name AppStderr (Join-Path $WorkDir "logs\service.err.log")
    $null = Invoke-Nssm -Exe $installedNssm set $Name AppRotateFiles 1
    $null = Invoke-Nssm -Exe $installedNssm set $Name AppRotateBytes 1048576
    $null = Invoke-Nssm -Exe $installedNssm set $Name AppExit Default Restart
    $null = Invoke-Nssm -Exe $installedNssm set $Name AppRestartDelay 3000

    if (Test-Path -LiteralPath $EnvFile) {
        $envExtra = @()
        Get-Content -LiteralPath $EnvFile | ForEach-Object {
            $line = $_.Trim()
            if ($line -and -not $line.StartsWith("#") -and $line -match '=') {
                $key, $value = $line -split '=', 2
                if ($key.Trim()) {
                    $envExtra += "$($key.Trim())=$($value.Trim())"
                }
            }
        }
        if ($envExtra.Count -gt 0) {
            $null = Invoke-Nssm -Exe $installedNssm set $Name AppEnvironmentExtra @envExtra
        }
    }

    New-Item -ItemType Directory -Path (Join-Path $WorkDir "logs") -Force | Out-Null
    sc.exe config $Name start= delayed-auto | Out-Null

    Write-Step "Start service $Name"
    sc.exe start $Name | Out-Null
    $deadline = (Get-Date).AddSeconds(20)
    do {
        Start-Sleep -Milliseconds 500
        $svc = Get-Service -Name $Name -ErrorAction SilentlyContinue
    } while ($svc -and $svc.Status -ne "Running" -and (Get-Date) -lt $deadline)

    $svc = Get-Service -Name $Name -ErrorAction SilentlyContinue
    if (-not $svc) {
        throw "Service $Name was not created"
    }
    if ($svc.Status -ne "Running") {
        $errLog = Join-Path $WorkDir "logs\service.err.log"
        $hint = if (Test-Path $errLog) { Get-Content $errLog -Tail 30 -ErrorAction SilentlyContinue } else { @() }
        Write-Host "Service status: $($svc.Status)" -ForegroundColor Yellow
        if ($hint) {
            Write-Host "Recent stderr:" -ForegroundColor Yellow
            $hint | ForEach-Object { Write-Host "  $_" }
        }
        throw "Service $Name did not reach Running state. Check $errLog"
    }
}

Write-Host ""
Write-Host "========================================" -ForegroundColor Green
Write-Host " Percent Meter - Windows Offline Deploy" -ForegroundColor Green
Write-Host "========================================" -ForegroundColor Green
Write-Host "Source: $ServerDir"
Write-Host "Target: $InstallDir"
Write-Host ""

Ensure-OfflineAssets
Remove-WindowsService -Name $ServiceName
Copy-ServerFiles -Target $InstallDir
$venvPython = Setup-EmbeddedPython -Target $InstallDir
$envFile = Write-ServiceEnv -Target $InstallDir -Port $SerialPort
Install-NssmService -Name $ServiceName -PythonExe $venvPython -WorkDir $InstallDir -EnvFile $envFile

$svc = Get-Service -Name $ServiceName
Write-Host ""
Write-Host "Deploy OK." -ForegroundColor Green
Write-Host "  Service     : $ServiceName"
Write-Host "  Status      : $($svc.Status)"
Write-Host "  Auto-start  : delayed-auto (starts after Windows boot)"
Write-Host "  Install     : $InstallDir"
Write-Host "  Config      : $envFile"
Write-Host "  URL         : http://127.0.0.1:8000"
Write-Host ""
Write-Host "Manage:"
Write-Host "  Status  : Get-Service $ServiceName"
Write-Host "  Restart : Restart-Service $ServiceName"
Write-Host "  Stop    : Stop-Service $ServiceName"
Write-Host "  NSSM    : $InstallDir\nssm.exe"
Write-Host "  Remove  : .\uninstall_windows.ps1"
Write-Host ""
Write-Host "Note: PATH warnings from pip are normal and have been hidden." -ForegroundColor DarkGray
Write-Host ""
