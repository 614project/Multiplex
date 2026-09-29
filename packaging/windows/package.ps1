# Packages the Windows release build as a portable zip and an Inno Setup installer.
# Usage: pwsh packaging/windows/package.ps1 -Version 1.2.0 -OutputDir dist   (after `flutter build windows --release`)
param(
  [Parameter(Mandatory)] [string] $Version,
  [Parameter(Mandatory)] [string] $OutputDir
)
$ErrorActionPreference = 'Stop'

$root = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$release = Join-Path $root 'build\windows\x64\runner\Release'
if (-not (Test-Path (Join-Path $release 'multiplex.exe'))) {
  throw "No release build found; run 'flutter build windows --release' first."
}
New-Item -ItemType Directory -Force -Path $OutputDir | Out-Null
$OutputDir = (Resolve-Path $OutputDir).Path

# Ship the Visual C++ runtime next to the executable, so the app starts on PCs that never
# installed the Visual C++ Redistributable.
$vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
$vs = & $vswhere -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
$crt = Get-ChildItem -Directory -Path (Join-Path $vs 'VC\Redist\MSVC\*\x64\Microsoft.VC*.CRT') |
  Sort-Object FullName | Select-Object -Last 1
if (-not $crt) { throw 'Visual C++ runtime redistributable not found.' }
foreach ($dll in 'msvcp140.dll', 'vcruntime140.dll', 'vcruntime140_1.dll') {
  Copy-Item (Join-Path $crt.FullName $dll) $release -Force
}

# Portable zip with a top-level Multiplex folder.
$staging = Join-Path ([IO.Path]::GetTempPath()) "multiplex-$([Guid]::NewGuid())"
$portable = Join-Path $staging 'Multiplex'
New-Item -ItemType Directory -Force -Path $staging | Out-Null
Copy-Item $release $portable -Recurse
$zip = Join-Path $OutputDir "Multiplex-$Version-windows-x64.zip"
Compress-Archive -Path $portable -DestinationPath $zip -Force
Remove-Item $staging -Recurse -Force
Write-Host "Wrote $zip"

# Installer.
$iscc = Join-Path ${env:ProgramFiles(x86)} 'Inno Setup 6\ISCC.exe'
if (-not (Test-Path $iscc)) {
  $found = Get-Command ISCC.exe -ErrorAction SilentlyContinue
  if ($found) {
    $iscc = $found.Source
  } else {
    choco install innosetup --no-progress -y | Out-Host
    if ($LASTEXITCODE) { throw "Installing Inno Setup failed ($LASTEXITCODE)." }
  }
}
& $iscc /Qp "/DAppVersion=$Version" "/DSourceDir=$release" "/DOutputDir=$OutputDir" (Join-Path $PSScriptRoot 'multiplex.iss')
if ($LASTEXITCODE) { throw "ISCC failed ($LASTEXITCODE)." }
Write-Host "Wrote $(Join-Path $OutputDir "Multiplex-$Version-windows-x64-setup.exe")"
