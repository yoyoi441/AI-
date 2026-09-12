; トークン見張り番 - Windows installer script (Inno Setup 6.x)
;
; Build steps:
;   1. Publish the app first (produces the single-file self-contained exe this script
;      packages):
;         dotnet publish -c Release -p:PublishProfile=win-x64
;      (or in Visual Studio: right-click the project -> Publish -> "win-x64")
;   2. Install Inno Setup (free): https://jrsoftware.org/isdl.php
;   3. Open this file in the Inno Setup Compiler and click Compile, or from a command
;      prompt with Inno Setup's bin dir on PATH:
;         ISCC installer\TokenMihariban.iss
;   4. Output: installer\Output\TokenMiharibanSetup.exe
;
; Per-user install (no admin rights, no UAC prompt) to LocalAppData, matching how the
; app already stores everything else per-user (%AppData%\TokenMihariban\settings.json,
; HKCU launch-at-login key) rather than machine-wide.

#define MyAppName "トークン見張り番"
#ifndef MyAppVersion
  #define MyAppVersion "0.5.0"
#endif
#define MyAppExeName "TokenMihariban.exe"
#define MyPublishDir "..\TokenMihariban\bin\Release\net8.0-windows\win-x64\publish"

[Setup]
; Fixed GUID so future versions upgrade in place instead of installing side-by-side.
AppId={{E7B4A1F0-6C2D-4B8E-9A3F-5D1C2E8B7A44}
AppName={#MyAppName}
AppVersion={#MyAppVersion}
AppPublisher={#MyAppName}
DefaultDirName={autopf}\{#MyAppName}
DefaultGroupName={#MyAppName}
DisableProgramGroupPage=yes
PrivilegesRequired=lowest
PrivilegesRequiredOverridesAllowed=dialog
; If a previous version of the app is running (same Mutex name as App.xaml.cs), Setup
; detects it and prompts the user to close it automatically instead of failing on a
; locked file.
AppMutex=TokenMihariban_SingleInstance_9F3A1C
; x64compatible needs Inno Setup 6.3+. If ISCC errors with "unknown identifier
; x64compatible", you have an older Inno Setup - replace both lines below with: x64
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
OutputDir=Output
OutputBaseFilename=TokenMiharibanSetup
SetupIconFile=..\TokenMihariban\Assets\app.ico
UninstallDisplayIcon={app}\{#MyAppExeName}
Compression=lzma2/max
SolidCompression=yes
WizardStyle=modern

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"
Name: "japanese"; MessagesFile: "compiler:Languages\Japanese.isl"

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"; Flags: unchecked

[Files]
; Publish output only - the folder must exist (run dotnet publish first) or ISCC fails
; with a clear "file not found" error rather than silently packaging a stale build.
Source: "{#MyPublishDir}\*"; DestDir: "{app}"; Flags: recursesubdirs createallsubdirs ignoreversion

[Icons]
Name: "{group}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"
Name: "{group}\{cm:UninstallProgram,{#MyAppName}}"; Filename: "{uninstallexe}"
Name: "{autodesktop}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"; Tasks: desktopicon

[Run]
Filename: "{app}\{#MyAppExeName}"; Description: "{cm:LaunchProgram,{#StringChange(MyAppName, '&', '&&')}}"; Flags: nowait postinstall skipifsilent

[Code]
// The app's own Settings -> General "launch at login" toggle writes this exact
// HKCU Run value (see UI/LaunchAtLogin.cs). If the user enabled it, clean it up on
// uninstall so Windows isn't left with a Run entry pointing at a deleted exe.
procedure CurUninstallStepChanged(CurUninstallStep: TUninstallStep);
begin
  if CurUninstallStep = usUninstall then
  begin
    RegDeleteValue(HKEY_CURRENT_USER, 'Software\Microsoft\Windows\CurrentVersion\Run', 'TokenMihariban');
  end;
end;
