; Inno Setup script for World Brief.
;   "C:\Program Files (x86)\Inno Setup 6\ISCC.exe" /DAppVersion=1.0.0 packaging\windows\worldbrief.iss
; Produces dist\WorldBrief-<version>-setup.exe: a per-user install that needs no administrator.

#ifndef AppVersion
  #define AppVersion "1.0.0"
#endif
#define AppName "World Brief"
#define AppExe "worldbrief.exe"
#define AppPublisher "World Brief"

[Setup]
AppId={{8B0A5F42-4C1E-4E8D-9B3A-6F2D7C1E5A90}
AppName={#AppName}
AppVersion={#AppVersion}
AppVerName={#AppName} {#AppVersion}
AppPublisher={#AppPublisher}
DefaultDirName={autopf}\WorldBrief
DefaultGroupName={#AppName}
DisableProgramGroupPage=yes
DisableDirPage=no
; Per-user by default: no UAC prompt, and the app can update itself in place.
PrivilegesRequiredOverridesAllowed=dialog
PrivilegesRequired=lowest
OutputDir=..\..\dist
OutputBaseFilename=WorldBrief-{#AppVersion}-setup
SetupIconFile=..\icons\icon.ico
UninstallDisplayIcon={app}\{#AppExe}
UninstallDisplayName={#AppName}
WizardStyle=modern
WizardSmallImageFile=wizard-small.bmp
WizardImageFile=wizard-large.bmp
Compression=lzma2/max
SolidCompression=yes
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
MinVersion=10.0
LicenseFile=
AppComments=Fifteen minutes a day. Every nation's press. Both sides.

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"

[Tasks]
Name: "desktopicon"; Description: "Create a &desktop shortcut"; GroupDescription: "Shortcuts:"
Name: "startup"; Description: "Start World Brief when I sign in, and keep the brief up to date in the background"; GroupDescription: "Startup:"; Flags: unchecked

[Files]
Source: "..\..\dist\worldbrief\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{group}\{#AppName}"; Filename: "{app}\{#AppExe}"
Name: "{group}\Uninstall {#AppName}"; Filename: "{uninstallexe}"
Name: "{autodesktop}\{#AppName}"; Filename: "{app}\{#AppExe}"; Tasks: desktopicon
Name: "{userstartup}\{#AppName}"; Filename: "{app}\{#AppExe}"; Parameters: "--background"; Tasks: startup

[Run]
Filename: "{app}\{#AppExe}"; Description: "Open {#AppName} now"; Flags: nowait postinstall skipifsilent

[UninstallDelete]
Type: filesandordirs; Name: "{app}\_internal\__pycache__"

[Code]
// The window is an Edge WebView2 control. Windows 11 always has the runtime; some Windows 10
// machines do not, so offer to fetch Microsoft's small bootstrapper rather than failing later.
function WebView2Installed(): Boolean;
var
  Value: String;
begin
  Result :=
    RegQueryStringValue(HKLM, 'SOFTWARE\WOW6432Node\Microsoft\EdgeUpdate\Clients\{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}', 'pv', Value) or
    RegQueryStringValue(HKLM, 'SOFTWARE\Microsoft\EdgeUpdate\Clients\{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}', 'pv', Value) or
    RegQueryStringValue(HKCU, 'SOFTWARE\Microsoft\EdgeUpdate\Clients\{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}', 'pv', Value);
end;

procedure CurStepChanged(CurStep: TSetupStep);
var
  TempFile: String;
  ResultCode: Integer;
begin
  if (CurStep = ssPostInstall) and (not WebView2Installed()) then
  begin
    if MsgBox('World Brief draws its window with the Microsoft Edge WebView2 runtime, which is ' +
              'not installed on this PC.' + #13#10#13#10 +
              'Download and install it now? Without it World Brief will open in your default ' +
              'browser instead.', mbConfirmation, MB_YESNO) = IDYES then
    begin
      TempFile := ExpandConstant('{tmp}\MicrosoftEdgeWebview2Setup.exe');
      if DownloadTemporaryFile('https://go.microsoft.com/fwlink/p/?LinkId=2124703',
                               'MicrosoftEdgeWebview2Setup.exe', '', nil) > 0 then
        Exec(TempFile, '/silent /install', '', SW_SHOW, ewWaitUntilTerminated, ResultCode);
    end;
  end;
end;

// The database, the briefs and any language packages belong to the user, not to the program:
// leave them in place unless the person uninstalling says otherwise.
procedure CurUninstallStepChanged(CurUninstallStep: TUninstallStep);
var
  DataDir: String;
begin
  if CurUninstallStep = usPostUninstall then
  begin
    DataDir := ExpandConstant('{localappdata}\WorldBrief');
    if DirExists(DataDir) then
      if MsgBox('Also delete the news database, saved briefs and installed language packages?' +
                #13#10#13#10 + DataDir, mbConfirmation, MB_YESNO or MB_DEFBUTTON2) = IDYES then
        DelTree(DataDir, True, True, True);
  end;
end;
