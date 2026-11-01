; audiojoe for Windows 10/11 – Inno Setup 6 script. Installs per user, without administrator
; rights, into %LOCALAPPDATA%\Programs\audiojoe. Built by tools/build-windows.ps1:
;   iscc /DAppVersion=0.0.20 /DSourceDir=<flutter release folder> /DOutputDir=<folder> audiojoe.iss

#ifndef AppVersion
  #error AppVersion missing (iscc /DAppVersion=…)
#endif
#ifndef SourceDir
  #define SourceDir "..\..\clients\app\build\windows\x64\runner\Release"
#endif
#ifndef OutputDir
  #define OutputDir "..\..\target\windows"
#endif

[Setup]
AppId={{8E9B9DEE-E487-4D93-9DC9-F988BB4A6C28}
AppName=audiojoe
AppVersion={#AppVersion}
AppVerName=audiojoe {#AppVersion}
AppPublisher=joeMJ
AppPublisherURL=https://github.com/joeMJ/audiojoe
AppSupportURL=https://github.com/joeMJ/audiojoe/issues
DefaultDirName={localappdata}\Programs\audiojoe
DefaultGroupName=audiojoe
DisableProgramGroupPage=yes
PrivilegesRequired=lowest
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
MinVersion=10.0
LicenseFile=..\..\LICENSE
SetupIconFile=..\..\clients\app\windows\runner\resources\app_icon.ico
UninstallDisplayIcon={app}\audiojoe.exe
OutputDir={#OutputDir}
OutputBaseFilename=audiojoe-{#AppVersion}-windows-x86_64-setup
Compression=lzma2/max
SolidCompression=yes
WizardStyle=modern
CloseApplications=yes

[Languages]
Name: "de"; MessagesFile: "compiler:Languages\German.isl"
Name: "en"; MessagesFile: "compiler:Default.isl"

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"; Flags: unchecked

[Files]
; The whole Flutter release folder: audiojoe.exe, flutter_windows.dll, plugins, libmpv-2.dll, data\
Source: "{#SourceDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs
Source: "..\..\LICENSE"; DestDir: "{app}\licenses"; DestName: "LICENSE.txt"; Flags: ignoreversion
Source: "..\..\THIRD_PARTY.md"; DestDir: "{app}\licenses"; Flags: ignoreversion
Source: "..\..\THIRD_PARTY_LICENSES.txt"; DestDir: "{app}\licenses"; Flags: ignoreversion

[Icons]
Name: "{autoprograms}\audiojoe"; Filename: "{app}\audiojoe.exe"
Name: "{autodesktop}\audiojoe"; Filename: "{app}\audiojoe.exe"; Tasks: desktopicon

[Run]
Filename: "{app}\audiojoe.exe"; Description: "{cm:LaunchProgram,audiojoe}"; Flags: nowait postinstall skipifsilent
