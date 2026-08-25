# 在有网络的 Windows 上运行，下载离线部署所需资源到 deploy 目录。
#Requires -Version 5.1
$ErrorActionPreference = "Stop"

$DeployDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$ServerDir = Split-Path -Parent $DeployDir
$WheelsDir = Join-Path $DeployDir "wheels"
$EmbedDir = Join-Path $DeployDir "python-embed"
$NssmDir = Join-Path $DeployDir "nssm"
$TempDir = Join-Path $DeployDir "_prepare_tmp"

$PythonVersion = "3.12.7"
$PythonEmbedZip = "python-$PythonVersion-embed-amd64.zip"
$PythonEmbedUrl = "https://www.python.org/ftp/python/$PythonVersion/$PythonEmbedZip"
$NssmZipUrl = "https://nssm.cc/release/nssm-2.24.zip"
$GetPipUrl = "https://bootstrap.pypa.io/get-pip.py"

function Write-Step([string]$Message) {
    Write-Host "[*] $Message" -ForegroundColor Cyan
}

function Download-File([string]$Url, [string]$Dest) {
    Write-Step "下载 $Url"
    Invoke-WebRequest -Uri $Url -OutFile $Dest -UseBasicParsing
}

Write-Step "清理并创建目录"
if (Test-Path -LiteralPath $TempDir) { Remove-Item -LiteralPath $TempDir -Recurse -Force }
New-Item -ItemType Directory -Path $WheelsDir, $EmbedDir, $NssmDir, $TempDir -Force | Out-Null

Download-File $PythonEmbedUrl (Join-Path $TempDir $PythonEmbedZip)
if (Test-Path -LiteralPath $EmbedDir) { Remove-Item -LiteralPath $EmbedDir -Recurse -Force }
New-Item -ItemType Directory -Path $EmbedDir -Force | Out-Null
Expand-Archive -LiteralPath (Join-Path $TempDir $PythonEmbedZip) -DestinationPath $EmbedDir -Force

Download-File $GetPipUrl (Join-Path $DeployDir "get-pip.py")

Write-Step "下载 pip wheels"
$pythonCmd = $null
if (Get-Command python -ErrorAction SilentlyContinue) { $pythonCmd = "python" }
elseif (Get-Command py -ErrorAction SilentlyContinue) { $pythonCmd = "py -3" }
else { throw "需要本机 Python 以执行 pip download" }

$reqFile = Join-Path $ServerDir "requirements.txt"
Invoke-Expression "$pythonCmd -m pip download -r `"$reqFile`" -d `"$WheelsDir`""
Invoke-Expression "$pythonCmd -m pip download pip setuptools wheel -d `"$WheelsDir`""

Write-Step "下载 NSSM"
$nssmZip = Join-Path $TempDir "nssm.zip"
Download-File $NssmZipUrl $nssmZip
$nssmExtract = Join-Path $TempDir "nssm"
Expand-Archive -LiteralPath $nssmZip -DestinationPath $nssmExtract -Force
$nssmSrc = Get-ChildItem -Path $nssmExtract -Recurse -Filter "nssm.exe" |
    Where-Object { $_.FullName -match "win64" } |
    Select-Object -First 1
if (-not $nssmSrc) { throw "未找到 win64 nssm.exe" }
Copy-Item -LiteralPath $nssmSrc.FullName -Destination (Join-Path $NssmDir "nssm.exe") -Force

Remove-Item -LiteralPath $TempDir -Recurse -Force

$wheelCount = @(Get-ChildItem -LiteralPath $WheelsDir -Filter "*.whl").Count
Write-Host ""
Write-Host "完成。可将整个 server 目录（含 deploy）复制到 U 盘。" -ForegroundColor Green
Write-Host "  wheels: $wheelCount 个"
Write-Host "  python-embed: $EmbedDir"
Write-Host "  nssm: $(Join-Path $NssmDir 'nssm.exe')"
