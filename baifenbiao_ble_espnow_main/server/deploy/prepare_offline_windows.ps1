# Run on a Windows PC with internet to download offline deploy assets.
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
$ProjectRoot = Split-Path -Parent $ServerDir

function Find-LocalPythonZip {
    $candidates = @(
        (Join-Path $DeployDir $PythonEmbedZip),
        (Join-Path $ProjectRoot "include\$PythonEmbedZip"),
        (Join-Path $ServerDir $PythonEmbedZip)
    )
    foreach ($path in $candidates) {
        if (Test-Path -LiteralPath $path) {
            return (Resolve-Path -LiteralPath $path).Path
        }
    }
    return $null
}

function Write-Step([string]$Message) {
    Write-Host "[*] $Message" -ForegroundColor Cyan
}

function Download-File([string]$Url, [string]$Dest) {
    Write-Step "Downloading $Url"
    Invoke-WebRequest -Uri $Url -OutFile $Dest -UseBasicParsing
}

Write-Step "Prepare directories"
if (Test-Path -LiteralPath $TempDir) {
    Remove-Item -LiteralPath $TempDir -Recurse -Force -ErrorAction SilentlyContinue
}
New-Item -ItemType Directory -Path $WheelsDir, $EmbedDir, $NssmDir, $TempDir -Force | Out-Null

$localPythonZip = Find-LocalPythonZip
if ($localPythonZip) {
    Write-Step "Use local Python embed zip: $localPythonZip"
    $pythonZipPath = $localPythonZip
} else {
    $pythonZipPath = Join-Path $TempDir $PythonEmbedZip
    Download-File $PythonEmbedUrl $pythonZipPath
}

if (Test-Path -LiteralPath $EmbedDir) { Remove-Item -LiteralPath $EmbedDir -Recurse -Force }
New-Item -ItemType Directory -Path $EmbedDir -Force | Out-Null
Expand-Archive -LiteralPath $pythonZipPath -DestinationPath $EmbedDir -Force
$deployZipCopy = Join-Path $DeployDir $PythonEmbedZip
if ($pythonZipPath -ne (Resolve-Path -LiteralPath $deployZipCopy -ErrorAction SilentlyContinue).Path) {
    Copy-Item -LiteralPath $pythonZipPath -Destination $deployZipCopy -Force
}

if (-not (Test-Path -LiteralPath (Join-Path $DeployDir "get-pip.py"))) {
    Download-File $GetPipUrl (Join-Path $DeployDir "get-pip.py")
}

Write-Step "Download pip wheels for Python 3.12"
$pythonCmd = $null
if (Get-Command py -ErrorAction SilentlyContinue) { $pythonCmd = "py -3" }
elseif (Get-Command python -ErrorAction SilentlyContinue) { $pythonCmd = "python" }
else { throw "Python is required on this machine for pip download" }

if (Test-Path -LiteralPath $WheelsDir) {
    Remove-Item -LiteralPath "$WheelsDir\*" -Force -ErrorAction SilentlyContinue
}
$reqFile = Join-Path $ServerDir "requirements.txt"
$pipIndex = "https://pypi.org/simple"
$pipArgs = "-m pip download -d `"$WheelsDir`" -i `"$pipIndex`" --python-version 3.12 --platform win_amd64 --implementation cp --only-binary=:all:"
Invoke-Expression "$pythonCmd $pipArgs -r `"$reqFile`""
Invoke-Expression "$pythonCmd $pipArgs pip setuptools wheel packaging"

Write-Step "Download NSSM"
$nssmZip = Join-Path $TempDir "nssm.zip"
Download-File $NssmZipUrl $nssmZip
$nssmExtract = Join-Path $TempDir "nssm"
Expand-Archive -LiteralPath $nssmZip -DestinationPath $nssmExtract -Force
$nssmSrc = Get-ChildItem -Path $nssmExtract -Recurse -Filter "nssm.exe" |
    Where-Object { $_.FullName -match "win64" } |
    Select-Object -First 1
if (-not $nssmSrc) { throw "win64 nssm.exe not found in archive" }
Copy-Item -LiteralPath $nssmSrc.FullName -Destination (Join-Path $NssmDir "nssm.exe") -Force

Remove-Item -LiteralPath $TempDir -Recurse -Force -ErrorAction SilentlyContinue

$wheelCount = @(Get-ChildItem -LiteralPath $WheelsDir -Filter "*.whl").Count
$nssmPath = Join-Path $NssmDir "nssm.exe"
Write-Host ""
Write-Host "Done. Copy the whole server folder (including deploy) to USB." -ForegroundColor Green
Write-Host "  wheels: $wheelCount"
Write-Host "  python-embed: $EmbedDir"
Write-Host "  nssm: $nssmPath"
