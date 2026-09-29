; Inno Setup script for the Multiplex installer. Built by packaging/windows/package.ps1:
;   ISCC.exe /DAppVersion=1.2.0 /DSourceDir=<Release folder> /DOutputDir=<dist> multiplex.iss

#ifndef AppVersion
  #define AppVersion "0.0.0"
#endif
#ifndef SourceDir
  #define SourceDir "..\..\build\windows\x64\runner\Release"
#endif
#ifndef OutputDir
  #define OutputDir "..\..\dist"
#endif

[Setup]
AppId={{0F7CC1C0-25F4-4C47-9E89-08D359B1E4FA}
AppName=Multiplex
AppVersion={#AppVersion}
AppVerName=Multiplex {#AppVersion}
AppPublisher=614project
AppPublisherURL=https://github.com/614project/Multiplex
AppSupportURL=https://github.com/614project/Multiplex/issues
AppUpdatesURL=https://github.com/614project/Multiplex/releases
DefaultDirName={autopf}\Multiplex
DefaultGroupName=Multiplex
DisableProgramGroupPage=yes
; Installs per user without an administrator prompt; the dialog offers an all-users install.
PrivilegesRequired=lowest
PrivilegesRequiredOverridesAllowed=dialog
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
MinVersion=10.0
OutputDir={#OutputDir}
OutputBaseFilename=Multiplex-{#AppVersion}-windows-x64-setup
SetupIconFile=..\..\windows\runner\resources\app_icon.ico
UninstallDisplayIcon={app}\multiplex.exe
UninstallDisplayName=Multiplex
Compression=lzma2/max
SolidCompression=yes
WizardStyle=modern
CloseApplications=yes

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"
#if FileExists(AddBackslash(CompilerPath) + "Languages\Korean.isl")
Name: "korean"; MessagesFile: "compiler:Languages\Korean.isl"
#endif

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"; Flags: unchecked

[Files]
Source: "{#SourceDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{autoprograms}\Multiplex"; Filename: "{app}\multiplex.exe"
Name: "{autodesktop}\Multiplex"; Filename: "{app}\multiplex.exe"; Tasks: desktopicon

[Run]
Filename: "{app}\multiplex.exe"; Description: "{cm:LaunchProgram,Multiplex}"; Flags: nowait postinstall skipifsilent
