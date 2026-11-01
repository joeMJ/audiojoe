<#
.SYNOPSIS
    Baut die audiojoe-App für Windows und das Installationsprogramm (Inno Setup).

.DESCRIPTION
    Nach dem Vorbild von tvjoe (tools/build-windows.ps1). Ablauf:
      1. flutter build windows --release in clients\app (lädt beim ersten Lauf libmpv-2.dll von
         media-kit/libmpv-win32-audio-build, Lizenz siehe THIRD_PARTY.md).
      2. Signatur von audiojoe.exe und der mitgelieferten DLLs mit dem Zertifikat aus
         Cert:\CurrentUser\My (wie tvjoe).
      3. Installationsprogramm mit Inno Setup 6 (packaging\windows\audiojoe.iss), pro Benutzer ohne
         Administratorrechte; signieren, SHA-256-Prüfsumme daneben.
    Jeder Fehler wird mit Ursache und nächstem Schritt gemeldet. Ergebnis: target\windows\.

.PARAMETER Iscc
    Pfad zu ISCC.exe (Vorgabe: Inno Setup 6 im Benutzer- oder Programmordner).

.PARAMETER Thumbprint
    Fingerabdruck des Signaturzertifikats in Cert:\CurrentUser\My (mit privatem Schlüssel).

.PARAMETER TimestampUrl
    Zeitstempeldienst (RFC 3161).

.PARAMETER NoSign
    Nicht signieren (Probeläufe; dann sind auch nicht eingecheckte Änderungen erlaubt).
#>
param(
    [string]$Iscc = '',
    [string]$Thumbprint = '',
    [string]$TimestampUrl = 'http://timestamp.digicert.com',
    [switch]$NoSign
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Fehler([string]$Text, [string]$Hilfe = '') {
    Write-Host "FEHLER: $Text" -ForegroundColor Red
    if ($Hilfe) { Write-Host "  Abhilfe: $Hilfe" -ForegroundColor Yellow }
    exit 1
}
function Schritt([string]$Text) { Write-Host "== $Text" -ForegroundColor Cyan }
function Ausfuehren([string]$Was, [scriptblock]$Block) {
    & $Block
    if ($LASTEXITCODE -ne 0) { Fehler "$Was ist fehlgeschlagen (Rückgabewert $LASTEXITCODE)." 'Meldungen oberhalb prüfen.' }
}

$Root = Split-Path -Parent $PSScriptRoot
$App = Join-Path $Root 'clients\app'
$Out = Join-Path $Root 'target\windows'
$Release = Join-Path $App 'build\windows\x64\runner\Release'

Schritt 'Version, Stand und Werkzeuge'
$line = Select-String -Path (Join-Path $App 'pubspec.yaml') -Pattern '^version:\s*([0-9.]+)' | Select-Object -First 1
if (-not $line) { Fehler 'Version in clients\app\pubspec.yaml nicht gefunden.' }
$Version = $line.Matches[0].Groups[1].Value
$head = (git -C $Root rev-parse --short HEAD).Trim()
$geaendert = [bool](git -C $Root status --porcelain)
Write-Host "Version $Version, Stand $head$(if ($geaendert) { ' (mit nicht eingecheckten Änderungen)' })"
if (-not $NoSign -and $geaendert) {
    Fehler 'Nicht eingecheckte Änderungen; so wird nicht signiert.' 'Änderungen einchecken oder -NoSign für einen Probelauf.'
}
if (-not (Get-Command flutter -ErrorAction SilentlyContinue)) { Fehler 'flutter nicht im PATH.' 'Flutter installieren und den bin-Ordner in den PATH nehmen.' }
if (-not $Iscc) {
    $Iscc = @("$env:LOCALAPPDATA\Programs\Inno Setup 6\ISCC.exe", "${env:ProgramFiles(x86)}\Inno Setup 6\ISCC.exe", "$env:ProgramFiles\Inno Setup 6\ISCC.exe") |
        Where-Object { Test-Path $_ } | Select-Object -First 1
}
if (-not $Iscc -or -not (Test-Path $Iscc)) { Fehler 'Inno Setup 6 (ISCC.exe) nicht gefunden.' 'Inno Setup 6 installieren (jrsoftware.org) oder -Iscc angeben.' }

$signtool = $null
if (-not $NoSign) {
    $signtool = Get-ChildItem "${env:ProgramFiles(x86)}\Windows Kits\10\bin\*\x64\signtool.exe" -ErrorAction SilentlyContinue |
        Sort-Object { [version]$_.Directory.Parent.Name } -Descending | Select-Object -First 1 -ExpandProperty FullName
    if (-not $signtool) { Fehler 'signtool.exe nicht gefunden.' 'Windows SDK installieren oder -NoSign.' }
    $cert = Get-ChildItem Cert:\CurrentUser\My | Where-Object Thumbprint -eq $Thumbprint
    if (-not $cert) { Fehler "Zertifikat $Thumbprint fehlt in Cert:\CurrentUser\My." 'Zertifikat mit privatem Schlüssel einspielen oder -Thumbprint angeben.' }
    if (-not $cert.HasPrivateKey) { Fehler "Zum Zertifikat $Thumbprint fehlt der private Schlüssel." }
}
function Signieren([string[]]$Dateien) {
    if ($NoSign) { return }
    Ausfuehren 'Signieren' { & $signtool sign /sha1 $Thumbprint /fd sha256 /tr $TimestampUrl /td sha256 /q @Dateien }
}

Schritt 'App bauen'
Push-Location $App
try {
    Ausfuehren 'flutter pub get' { flutter pub get }
    Ausfuehren 'flutter build windows' { flutter build windows --release }
} finally { Pop-Location }
if (-not (Test-Path (Join-Path $Release 'audiojoe.exe'))) { Fehler "audiojoe.exe fehlt in $Release." }
if (-not (Test-Path (Join-Path $Release 'libmpv-2.dll'))) { Fehler 'libmpv-2.dll fehlt.' 'Ohne sie gibt es keinen Ton; Bauausgabe von media_kit_libs_windows_audio prüfen.' }

Schritt 'Signieren'
Signieren (@(Join-Path $Release 'audiojoe.exe') + @(Get-ChildItem $Release -Filter *.dll | Select-Object -ExpandProperty FullName))

Schritt 'Installationsprogramm'
New-Item -ItemType Directory -Force -Path $Out | Out-Null
Ausfuehren 'Inno Setup' { & $Iscc /Q "/DAppVersion=$Version" "/DSourceDir=$Release" "/DOutputDir=$Out" (Join-Path $Root 'packaging\windows\audiojoe.iss') }
$Setup = Join-Path $Out "audiojoe-$Version-windows-x86_64-setup.exe"
if (-not (Test-Path $Setup)) { Fehler "$Setup wurde nicht erzeugt." }
Signieren @($Setup)
$hash = (Get-FileHash -Algorithm SHA256 $Setup).Hash.ToLower()
"$hash  $(Split-Path -Leaf $Setup)" | Set-Content -Encoding ascii "$Setup.sha256"
Write-Host "Fertig: $Setup" -ForegroundColor Green
Write-Host "SHA-256: $hash"
