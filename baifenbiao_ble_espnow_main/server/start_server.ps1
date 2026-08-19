param(
    [string]$Port = "",
    [switch]$Simulate
)

$ErrorActionPreference = "Stop"
$ScriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
Set-Location -LiteralPath $ScriptRoot

if ($Port) { $env:SERIAL_PORT = $Port }
if ($Simulate) { $env:SIMULATE = "1" } else { Remove-Item Env:SIMULATE -ErrorAction SilentlyContinue }

python -m uvicorn app:app --host 0.0.0.0 --port 8000
