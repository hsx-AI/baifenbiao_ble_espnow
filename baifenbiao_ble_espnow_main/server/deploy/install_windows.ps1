#Requires -RunAsAdministrator
<#
.SYNOPSIS
  离线一键部署百分表网关到 Windows，并注册开机自启服务（NSSM）。

.PARAMETER InstallDir
  安装目录，默认 C:\PercentMeter

.PARAMETER SerialPort
  主站串口，例如 COM11。留空则服务端自动扫描。

.PARAMETER ServiceName
  Windows 服务名，默认 PercentMeter
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
        throw "缺少离线 pip 包目录: $WheelsDir`n请先在有网电脑运行 prepare_offline_windows.ps1"
    }
    $wheelCount = @(Get-ChildItem -LiteralPath $WheelsDir -Filter "*.whl" -ErrorAction SilentlyContinue).Count
    if ($wheelCount -eq 0) {
        throw "wheels 目录为空，请先运行 prepare_offline_windows.ps1 下载依赖"
    }
    if (-not (Test-Path -LiteralPath $NssmExe)) {
        throw "缺少 NSSM: $NssmExe`n请先运行 prepare_offline_windows.ps1"
    }
    if (-not (Test-Path -LiteralPath $EmbedDir)) {
        throw "缺少嵌入式 Python: $EmbedDir`n请先运行 prepare_offline_windows.ps1"
    }
}

function Copy-ServerFiles([string]$Target) {
    Write-Step "复制服务端文件到 $Target"
    if (Test-Path -LiteralPath $Target) {
        Remove-Item -LiteralPath $Target -Recurse -Force
    }
    New-Item -ItemType Directory -Path $Target -Force | Out-Null

    $exclude = @("deploy", "__pycache__")
    Get-ChildItem -LiteralPath $ServerDir -Force | Where-Object {
        $exclude -notcontains $_.Name
    } | ForEach-Object {
        Copy-Item -LiteralPath $_.FullName -Destination $Target -Recurse -Force
    }
}

function Setup-EmbeddedPython([string]$Target) {
    Write-Step "安装嵌入式 Python"
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
        throw "未找到 $pythonExe"
    }

    $getPip = Join-Path $DeployDir "get-pip.py"
    if (Test-Path -LiteralPath $getPip) {
        Write-Step "初始化 pip"
        & $pythonExe $getPip --no-warn-script-location
    }

    Write-Step "离线安装 Python 依赖到嵌入式 Python"
    & $pythonExe -m pip install --no-index --find-links $WheelsDir pip setuptools wheel
    & $pythonExe -m pip install --no-index --find-links $WheelsDir -r (Join-Path $Target "requirements.txt")
    return $pythonExe
}

function Write-ServiceEnv([string]$Target, [string]$Port) {
    $envFile = Join-Path $Target "service.env"
    $lines = @(
        "# PercentMeter 服务环境变量（修改后请重启服务）",
        "SIMULATE=0",
        "SERIAL_BAUD=115200"
    )
    if ($Port) {
        $lines += "SERIAL_PORT=$Port"
    } else {
        $lines += "# SERIAL_PORT=COM11"
        $lines += "SERIAL_PORT="
    }
    Set-Content -LiteralPath $envFile -Value ($lines -join "`r`n") -Encoding UTF8
    return $envFile
}

function Install-NssmService(
    [string]$Name,
    [string]$PythonExe,
    [string]$WorkDir,
    [string]$EnvFile
) {
    Write-Step "注册 Windows 服务: $Name"

    $existing = Get-Service -Name $Name -ErrorAction SilentlyContinue
    if ($existing) {
        Write-Step "停止并移除旧服务"
        & $NssmExe stop $Name confirm 2>$null
        Start-Sleep -Seconds 2
        & $NssmExe remove $Name confirm
        Start-Sleep -Seconds 1
    }

    & $NssmExe install $Name $PythonExe "-m" "uvicorn" "app:app" "--host" "0.0.0.0" "--port" "8000"
    & $NssmExe set $Name AppDirectory $WorkDir
    & $NssmExe set $Name DisplayName "Percent Meter Gateway"
    & $NssmExe set $Name Description "BLE 百分表网关 Web 服务 (FastAPI/WebSocket)"
    & $NssmExe set $Name Start SERVICE_AUTO_START
    & $NssmExe set $Name AppStdout (Join-Path $WorkDir "logs\service.out.log")
    & $NssmExe set $Name AppStderr (Join-Path $WorkDir "logs\service.err.log")
    & $NssmExe set $Name AppRotateFiles 1
    & $NssmExe set $Name AppRotateBytes 1048576

  # 从 service.env 加载环境变量
    if (Test-Path -LiteralPath $EnvFile) {
        $envExtra = @()
        Get-Content -LiteralPath $EnvFile | ForEach-Object {
            $line = $_.Trim()
            if ($line -and -not $line.StartsWith("#") -and $line -match '=') {
                $name, $value = $line -split '=', 2
                if ($name.Trim()) {
                    $envExtra += "$($name.Trim())=$($value.Trim())"
                }
            }
        }
        if ($envExtra.Count -gt 0) {
            $envString = $envExtra -join "`n"
            & $NssmExe set $Name AppEnvironmentExtra $envString
        }
    }

    New-Item -ItemType Directory -Path (Join-Path $WorkDir "logs") -Force | Out-Null
    & $NssmExe start $Name
}

Write-Host ""
Write-Host "========================================" -ForegroundColor Green
Write-Host " 百分表网关 Windows 离线部署" -ForegroundColor Green
Write-Host "========================================" -ForegroundColor Green
Write-Host "源目录: $ServerDir"
Write-Host "安装到: $InstallDir"
Write-Host ""

Ensure-OfflineAssets
Copy-ServerFiles -Target $InstallDir
$venvPython = Setup-EmbeddedPython -Target $InstallDir
$envFile = Write-ServiceEnv -Target $InstallDir -Port $SerialPort
Install-NssmService -Name $ServiceName -PythonExe $venvPython -WorkDir $InstallDir -EnvFile $envFile

Write-Host ""
Write-Host "部署成功！" -ForegroundColor Green
Write-Host "  服务名: $ServiceName"
Write-Host "  安装目录: $InstallDir"
Write-Host "  环境配置: $envFile"
Write-Host "  访问地址: http://127.0.0.1:8000"
Write-Host ""
Write-Host "管理命令:"
Write-Host "  查看状态: Get-Service $ServiceName"
Write-Host "  重启服务: nssm restart $ServiceName  (或 services.msc)"
Write-Host "  卸载服务: .\uninstall_windows.ps1"
Write-Host ""
