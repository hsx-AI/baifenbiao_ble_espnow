#Requires -RunAsAdministrator
param(
    [string]$ServiceName = "PercentMeter"
)

$ErrorActionPreference = "Stop"
$DeployDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$NssmExe = Join-Path $DeployDir "nssm\nssm.exe"
$InstallDir = "C:\PercentMeter"

Write-Host "正在卸载 $ServiceName ..."

$svc = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
if ($svc -and (Test-Path -LiteralPath $NssmExe)) {
    & $NssmExe stop $ServiceName confirm 2>$null
    Start-Sleep -Seconds 2
    & $NssmExe remove $ServiceName confirm
} elseif ($svc) {
    Stop-Service -Name $ServiceName -Force -ErrorAction SilentlyContinue
    sc.exe delete $ServiceName | Out-Null
}

if (Test-Path -LiteralPath $InstallDir) {
    Remove-Item -LiteralPath $InstallDir -Recurse -Force
    Write-Host "已删除 $InstallDir"
}

Write-Host "卸载完成。"
