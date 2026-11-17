#Requires -RunAsAdministrator
param(
    [string]$ServiceName = "PercentMeter",
    [string]$InstallDir = "C:\PercentMeter"
)

$ErrorActionPreference = "Stop"

Write-Host "Removing service $ServiceName ..."

$svc = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
if ($svc) {
    if ($svc.Status -ne "Stopped") {
        sc.exe stop $ServiceName | Out-Null
        Start-Sleep -Seconds 2
    }
    sc.exe delete $ServiceName | Out-Null
    Start-Sleep -Seconds 2
}

if (Test-Path -LiteralPath $InstallDir) {
    Remove-Item -LiteralPath $InstallDir -Recurse -Force
    Write-Host "Removed $InstallDir"
}

Write-Host "Uninstall done."
