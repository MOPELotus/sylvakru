#ifndef Arch
  #define Arch "x64"
#endif
#ifndef AppVersion
  #define AppVersion "0.1.0"
#endif
[Setup]
AppId={{A7EE225A-906F-434D-A465-E05096057B61}
AppName=Linsen
AppVersion={#AppVersion}
AppPublisher=MOPELotus
DefaultDirName={localappdata}\Programs\Linsen
PrivilegesRequired=lowest
UninstallDisplayIcon={app}\Linsen.exe
OutputDir=..\dist
OutputBaseFilename=Linsen-{#AppVersion}-windows-{#Arch}-setup
Compression=lzma2
SolidCompression=yes
#if Arch == "arm64"
ArchitecturesAllowed=arm64
ArchitecturesInstallIn64BitMode=arm64
#else
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
#endif
[Files]
Source: "..\build\windows\{#Arch}\runner\Release\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs
Source: "..\NOTICE"; DestDir: "{app}"
Source: "..\LICENSE"; DestDir: "{app}"
[Icons]
Name: "{userprograms}\Linsen"; Filename: "{app}\Linsen.exe"
[Run]
Filename: "{app}\Linsen.exe"; Description: "Start Linsen"; Flags: nowait postinstall skipifsilent
