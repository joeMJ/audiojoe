<#
.SYNOPSIS
    Baut die audiojoe-App für Windows und die signierte MSI (WiX 3.14).

.DESCRIPTION
    Nach dem Vorbild von tvjoe (tools/build-windows.ps1, packaging/windows/tvjoe.wxs). Ablauf:
      1. flutter build windows --release in clients\app. Ergebnis ist der Release-Ordner mit
         audiojoe.exe, flutter_windows.dll, den Plugin-DLLs, libmpv-2.dll (media_kit, Lizenz siehe
         THIRD_PARTY.md) und data\.
      2. Signatur von audiojoe.exe mit dem Zertifikat aus Cert:\CurrentUser\My (wie tvjoe).
      3. Dateiliste für WiX aus dem Release-Ordner, MSI mit candle/light (packaging\windows\audiojoe.wxs),
         pro Benutzer ohne Administratorrechte; MSI signieren, SHA-256-Prüfsumme daneben.
    Jeder Fehler wird mit Ursache und nächstem Schritt gemeldet. Ergebnis: target\windows\.

.PARAMETER WixDir
    Ordner mit candle.exe und light.exe (Vorgabe: Umgebungsvariable WIX bzw. deren bin, sonst
    C:\Program Files (x86)\WiX Toolset v3.14\bin).

.PARAMETER Thumbprint
    Fingerabdruck des Signaturzertifikats in Cert:\CurrentUser\My (mit privatem Schlüssel).

.PARAMETER TimestampUrl
    Zeitstempeldienst (RFC 3161).

.PARAMETER NoSign
    Nicht signieren (Probeläufe; dann sind auch nicht eingecheckte Änderungen erlaubt).

.PARAMETER NoMsi
    Nur die App bauen, keine MSI.
#>
param(
    [string]$WixDir = '',
    [string]$Thumbprint = '',
    [string]$TimestampUrl = 'http://timestamp.digicert.com',
    [switch]$NoSign,
    [switch]$NoMsi
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
if ($Version -notmatch '^\d+\.\d+\.\d+$') { Fehler "Version „$Version“ passt nicht zu einer MSI (nur a.b.c)." }
$head = (git -C $Root rev-parse --short HEAD).Trim()
$geaendert = [bool](git -C $Root status --porcelain)
Write-Host "Version $Version, Stand $head$(if ($geaendert) { ' (mit nicht eingecheckten Änderungen)' })"
if (-not $NoSign -and $geaendert) {
    Fehler 'Nicht eingecheckte Änderungen; so wird nicht signiert.' 'Änderungen einchecken oder -NoSign für einen Probelauf.'
}
if (-not (Get-Command flutter -ErrorAction SilentlyContinue)) { Fehler 'flutter nicht im PATH.' 'Flutter installieren und den bin-Ordner in den PATH nehmen.' }

$signtool = $null
if (-not $NoSign) {
    $signtool = Get-ChildItem "${env:ProgramFiles(x86)}\Windows Kits\10\bin\*\x64\signtool.exe" -ErrorAction SilentlyContinue |
        Sort-Object { [version]$_.Directory.Parent.Name } -Descending | Select-Object -First 1 -ExpandProperty FullName
    if (-not $signtool) { Fehler 'signtool.exe nicht gefunden.' 'Windows SDK installieren oder -NoSign.' }
    $cert = Get-ChildItem Cert:\CurrentUser\My | Where-Object Thumbprint -eq $Thumbprint
    if (-not $cert) { Fehler "Zertifikat $Thumbprint fehlt in Cert:\CurrentUser\My." 'Zertifikat mit privatem Schlüssel einspielen oder -Thumbprint angeben.' }
    if (-not $cert.HasPrivateKey) { Fehler "Zum Zertifikat $Thumbprint fehlt der private Schlüssel." }
}

if (-not $NoMsi) {
    if (-not $WixDir) {
        # Umgebungsvariable WIX (Ordner mit candle.exe bzw. dessen bin), sonst die ausgepackten
        # wix314-binaries (wie bei tvjoe/remotejoe), sonst der Installationsordner von WiX.
        $kandidaten = @()
        if ($env:WIX) { $kandidaten += @((Join-Path $env:WIX 'bin'), $env:WIX) }
        $kandidaten += @('C:\Program Files (x86)\WiX Toolset v3.14\bin')
        $WixDir = $kandidaten | Where-Object { Test-Path (Join-Path $_ 'candle.exe') } | Select-Object -First 1
        if (-not $WixDir) { $WixDir = $kandidaten[-1] }
    }
    $candle = Join-Path $WixDir 'candle.exe'
    $light = Join-Path $WixDir 'light.exe'
    if (-not (Test-Path $candle) -or -not (Test-Path $light)) {
        Fehler "WiX nicht gefunden unter $WixDir." 'wix314-binaries.zip (github.com/wixtoolset/wix3/releases) auspacken und -WixDir angeben, oder -NoMsi.'
    }
}

Schritt 'App bauen'
Push-Location $App
try {
    Ausfuehren 'flutter pub get' { flutter pub get }
    Ausfuehren 'flutter build windows' { flutter build windows --release }
} finally { Pop-Location }
if (-not (Test-Path (Join-Path $Release 'audiojoe.exe'))) { Fehler "audiojoe.exe fehlt in $Release." }
if (-not (Test-Path (Join-Path $Release 'libmpv-2.dll'))) { Fehler 'libmpv-2.dll fehlt.' 'Ohne sie gibt es keinen Ton; Bauausgabe von media_kit_libs_windows_audio prüfen.' }

if (-not $NoSign) {
    Schritt 'Eigenes Programm signieren'
    $exe = Join-Path $Release 'audiojoe.exe'
    Ausfuehren 'signtool sign (audiojoe.exe)' { & $signtool sign /sha1 $Thumbprint /fd SHA256 /tr $TimestampUrl /td SHA256 /d 'audiojoe' $exe }
    Ausfuehren 'Signatur prüfen (audiojoe.exe)' { & $signtool verify /pa /q $exe }
}

$groesse = (Get-ChildItem $Release -Recurse -File | Measure-Object Length -Sum).Sum
Write-Host ("Release-Ordner: {0} ({1} Dateien, {2:N0} MB)" -f $Release, (Get-ChildItem $Release -Recurse -File).Count, ($groesse / 1MB))
if ($NoMsi) { Write-Host 'Fertig (ohne MSI).'; exit 0 }

Schritt 'Dateiliste für WiX'
# Je Ordner eine Komponente mit Schlüssel in HKCU (pro Benutzer vorgeschrieben) und RemoveFolder;
# feste GUIDs aus dem relativen Pfad, damit Updates dieselben Komponenten erkennen.
$md5 = [Security.Cryptography.MD5]::Create()
function Guid-Aus([string]$Text) {
    $b = $md5.ComputeHash([Text.Encoding]::UTF8.GetBytes("audiojoe-msi:$Text"))
    $b[6] = ($b[6] -band 0x0f) -bor 0x30; $b[8] = ($b[8] -band 0x3f) -bor 0x80
    return ([guid]::new([byte[]]$b)).ToString().ToUpper()
}
function Id-Aus([string]$Prefix, [string]$Text) {
    $h = -join ($md5.ComputeHash([Text.Encoding]::UTF8.GetBytes($Text))[0..7] | ForEach-Object { $_.ToString('x2') })
    return "${Prefix}_$h"
}
function Xml([string]$s) { [Security.SecurityElement]::Escape($s) }
$sb = New-Object Text.StringBuilder
[void]$sb.AppendLine('<?xml version="1.0" encoding="utf-8"?>')
[void]$sb.AppendLine('<!-- Erzeugt von tools/build-windows.ps1, nicht von Hand ändern. -->')
[void]$sb.AppendLine('<Wix xmlns="http://schemas.microsoft.com/wix/2006/wi"><Fragment>')
$comps = New-Object Collections.Generic.List[string]
function Ordner([string]$Pfad, [string]$Rel) {
    $files = @(Get-ChildItem $Pfad -File | Sort-Object Name)
    $compId = Id-Aus 'c' "dir:$Rel"
    $comps.Add($compId)
    [void]$sb.AppendLine("<Component Id=`"$compId`" Guid=`"$(Guid-Aus "dir:$Rel")`" Win64=`"yes`">")
    [void]$sb.AppendLine("<RegistryValue Root=`"HKCU`" Key=`"Software\audiojoe\Installer\Ordner`" Name=`"$(Xml ($(if ($Rel) { $Rel } else { '.' })))`" Type=`"integer`" Value=`"1`" KeyPath=`"yes`" />")
    [void]$sb.AppendLine("<RemoveFolder Id=`"$(Id-Aus 'r' "dir:$Rel")`" On=`"uninstall`" />")
    foreach ($f in $files) {
        $relFile = if ($Rel) { "$Rel\$($f.Name)" } else { $f.Name }
        [void]$sb.AppendLine("<File Id=`"$(Id-Aus 'f' "file:$relFile")`" Name=`"$(Xml $f.Name)`" Source=`"$(Xml $f.FullName)`" KeyPath=`"no`" />")
    }
    [void]$sb.AppendLine('</Component>')
    foreach ($d in (Get-ChildItem $Pfad -Directory | Sort-Object Name)) {
        $relDir = if ($Rel) { "$Rel\$($d.Name)" } else { $d.Name }
        [void]$sb.AppendLine("<Directory Id=`"$(Id-Aus 'd' "dir:$relDir")`" Name=`"$(Xml $d.Name)`">")
        Ordner $d.FullName $relDir
        [void]$sb.AppendLine('</Directory>')
    }
}
New-Item -ItemType Directory -Force $Out | Out-Null
[void]$sb.AppendLine('<DirectoryRef Id="INSTALLDIR">')
Ordner $Release ''
[void]$sb.AppendLine('</DirectoryRef>')
[void]$sb.AppendLine('<ComponentGroup Id="AppFiles">')
foreach ($c in $comps) { [void]$sb.AppendLine("<ComponentRef Id=`"$c`" />") }
[void]$sb.AppendLine('</ComponentGroup>')
[void]$sb.AppendLine('</Fragment></Wix>')
$filesWxs = Join-Path $Out 'files.wxs'
[IO.File]::WriteAllText($filesWxs, $sb.ToString(), (New-Object Text.UTF8Encoding $false))
Write-Host "$($comps.Count) Ordner"

Schritt 'MSI bauen (candle, light)'
$wxs = Join-Path $Root 'packaging\windows\audiojoe.wxs'
$ico = Join-Path $App 'windows\runner\resources\app_icon.ico'
$obj = Join-Path $Out 'obj'
New-Item -ItemType Directory -Force $obj | Out-Null
$msiName = "audiojoe-$Version-windows-x86_64.msi"
$msi = Join-Path $Out $msiName
Ausfuehren 'candle' { & $candle -nologo -arch x64 -ext WixUtilExtension "-dVersion=$Version" "-dIconFile=$ico" -out "$obj\" $wxs $filesWxs }
# ICE91: Dateien im Benutzerprofil bei einer Installation pro Benutzer (gewollt).
# ICE61: Dieselbe Version ersetzt sich selbst (AllowSameVersionUpgrades; gewollt).
Ausfuehren 'light' { & $light -nologo -spdb -ext WixUtilExtension -sice:ICE91 -sice:ICE61 -out $msi "$obj\audiojoe.wixobj" "$obj\files.wixobj" }

if (-not $NoSign) {
    Schritt 'MSI signieren'
    Ausfuehren 'signtool sign (MSI)' { & $signtool sign /sha1 $Thumbprint /fd SHA256 /tr $TimestampUrl /td SHA256 /d "audiojoe $Version" $msi }
}

Schritt 'Prüfsumme'
$hash = (Get-FileHash $msi -Algorithm SHA256).Hash.ToLower()
[IO.File]::WriteAllText("$msi.sha256", "$hash  $msiName`n", (New-Object Text.UTF8Encoding $false))
Write-Host ("Fertig: {0} ({1:N1} MB)" -f $msi, ((Get-Item $msi).Length / 1MB))
Write-Host "SHA-256: $hash"
