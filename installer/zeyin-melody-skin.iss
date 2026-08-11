#ifndef AppVersion
  #error AppVersion must be supplied by build-release.ps1
#endif
#ifndef StageRoot
  #error StageRoot must be supplied by build-release.ps1
#endif
#ifndef OutputDir
  #error OutputDir must be supplied by build-release.ps1
#endif

#define AppName "Zeyin Melody Skin for Codex"
#define AppPublisher "Zeyin Melody Skin for Codex contributors"
#define RepositoryUrl "https://github.com/yousizaitianqiong/Zeyin-Melody-Skin-for-Codex"
#define ReleasesUrl "https://github.com/yousizaitianqiong/Zeyin-Melody-Skin-for-Codex/releases"
#define PowerShellPath "{sysnative}\WindowsPowerShell\v1.0\powershell.exe"
#define PersistentPowerShellPath "{win}\System32\WindowsPowerShell\v1.0\powershell.exe"

[Setup]
AppId={{9FA2CB1B-2212-4661-8F9F-F94FA81F2A14}
AppName={#AppName}
AppVersion={#AppVersion}
AppVerName={#AppName} {#AppVersion}
AppPublisher={#AppPublisher}
AppPublisherURL={#RepositoryUrl}
AppSupportURL={#RepositoryUrl}
AppUpdatesURL={#ReleasesUrl}
DefaultDirName={localappdata}\Programs\ZeyinMelodySkin
DefaultGroupName={#AppName}
DisableProgramGroupPage=yes
PrivilegesRequired=lowest
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
MinVersion=10.0
WizardStyle=modern
Compression=lzma2/ultra64
SolidCompression=yes
OutputDir={#OutputDir}
OutputBaseFilename=ZeyinMelodySkin-Setup-v{#AppVersion}
SetupIconFile={#StageRoot}\payload\assets\zeyin-melody-skin.ico
UninstallDisplayIcon={app}\payload\assets\zeyin-melody-skin.ico
UninstallDisplayName={#AppName}
LicenseFile={#StageRoot}\LICENSE.txt
VersionInfoVersion={#AppVersion}.0
VersionInfoCompany={#AppPublisher}
VersionInfoDescription={#AppName} Windows installer
VersionInfoProductName={#AppName}
VersionInfoProductVersion={#AppVersion}
SetupMutex=Local\ZeyinMelodySkin.Setup
AppMutex=Local\ZeyinMelodySkin.Tray
CloseApplications=no
RestartApplications=no
RestartIfNeededByRun=no
ChangesAssociations=no
ChangesEnvironment=no
UsePreviousTasks=yes
SetupLogging=yes

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"
Name: "chinesesimplified"; MessagesFile: "{#StageRoot}\languages\ChineseSimplified.isl"

[Messages]
english.ConfirmUninstall=Uninstall will close Codex, restore its official appearance, remove the Zeyin Melody runtime, and delete all Zeyin Melody state.%n%nContinue?
chinesesimplified.ConfirmUninstall=卸载将关闭 Codex、恢复官方外观、移除 Zeyin Melody 运行时，并删除全部 Zeyin Melody 状态。%n%n是否继续？

[Tasks]
Name: "desktopicon"; Description: "Create desktop shortcuts"; GroupDescription: "Additional shortcuts:"; Flags: unchecked
Name: "startup"; Description: "Start the Zeyin Melody tray when I sign in"; GroupDescription: "Startup:"; Flags: unchecked

[Files]
Source: "{#StageRoot}\setup-bootstrap.ps1"; DestDir: "{tmp}"; Flags: dontcopy noencryption
Source: "{#StageRoot}\payload\*"; DestDir: "{tmp}\payload"; Flags: dontcopy noencryption recursesubdirs createallsubdirs
Source: "{#StageRoot}\setup-bootstrap.ps1"; DestDir: "{app}"; Flags: ignoreversion
Source: "{#StageRoot}\LICENSE.txt"; DestDir: "{app}"; Flags: ignoreversion
Source: "{#StageRoot}\NOTICE.md"; DestDir: "{app}"; Flags: ignoreversion
Source: "{#StageRoot}\payload\*"; DestDir: "{app}\payload"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{group}\Zeyin Melody Skin for Codex"; Filename: "{#PersistentPowerShellPath}"; Parameters: "-NoProfile -STA -WindowStyle Hidden -ExecutionPolicy RemoteSigned -File ""{app}\setup-bootstrap.ps1"" -LaunchTray"; WorkingDir: "{app}"; IconFilename: "{app}\payload\assets\zeyin-melody-skin.ico"
Name: "{group}\恢复 Codex 官方外观"; Filename: "{#PersistentPowerShellPath}"; Parameters: "-NoProfile -STA -ExecutionPolicy RemoteSigned -File ""{app}\setup-bootstrap.ps1"" -RestoreOfficial"; WorkingDir: "{app}"; IconFilename: "{app}\payload\assets\zeyin-melody-skin.ico"
Name: "{userdesktop}\Zeyin Melody Skin for Codex"; Filename: "{#PersistentPowerShellPath}"; Parameters: "-NoProfile -STA -WindowStyle Hidden -ExecutionPolicy RemoteSigned -File ""{app}\setup-bootstrap.ps1"" -LaunchTray"; WorkingDir: "{app}"; IconFilename: "{app}\payload\assets\zeyin-melody-skin.ico"; Tasks: desktopicon
Name: "{userdesktop}\恢复 Codex 官方外观"; Filename: "{#PersistentPowerShellPath}"; Parameters: "-NoProfile -STA -ExecutionPolicy RemoteSigned -File ""{app}\setup-bootstrap.ps1"" -RestoreOfficial"; WorkingDir: "{app}"; IconFilename: "{app}\payload\assets\zeyin-melody-skin.ico"; Tasks: desktopicon
Name: "{userstartup}\Zeyin Melody Skin for Codex"; Filename: "{#PersistentPowerShellPath}"; Parameters: "-NoProfile -STA -WindowStyle Hidden -ExecutionPolicy RemoteSigned -File ""{app}\setup-bootstrap.ps1"" -LaunchTray -Silent"; WorkingDir: "{app}"; IconFilename: "{app}\payload\assets\zeyin-melody-skin.ico"; Tasks: startup

[Run]
Filename: "{#PowerShellPath}"; Parameters: "-NoProfile -STA -WindowStyle Hidden -ExecutionPolicy RemoteSigned -File ""{app}\setup-bootstrap.ps1"" -LaunchTray"; WorkingDir: "{app}"; Description: "Launch the Zeyin Melody tray"; Flags: nowait postinstall skipifsilent

[Code]
function PowerShellArguments(
  const ScriptPath: String;
  const ActionArguments: String;
  const Silent: Boolean
): String;
begin
  Result := '-NoProfile -STA -WindowStyle Hidden -ExecutionPolicy RemoteSigned -File ' +
    AddQuotes(ScriptPath) + ' ' + ActionArguments;
  if Silent then
    Result := Result + ' -Silent';
end;

function RunBootstrap(
  const ScriptPath: String;
  const ActionArguments: String;
  const Silent: Boolean;
  var ExitCode: Integer
): Boolean;
begin
  Result := Exec(
    ExpandConstant('{#PowerShellPath}'),
    PowerShellArguments(ScriptPath, ActionArguments, Silent),
    ExtractFileDir(ScriptPath),
    SW_HIDE,
    ewWaitUntilTerminated,
    ExitCode
  );
end;

function PrepareToInstall(var NeedsRestart: Boolean): String;
var
  ExitCode: Integer;
  TemporaryBootstrap: String;
begin
  Result := '';
  ExtractTemporaryFiles('{tmp}\setup-bootstrap.ps1');
  ExtractTemporaryFiles('{tmp}\payload\*');
  TemporaryBootstrap := ExpandConstant('{tmp}\setup-bootstrap.ps1');
  if not RunBootstrap(TemporaryBootstrap, '-Preflight', WizardSilent, ExitCode) then
    Result := 'Zeyin Melody preflight could not be started.'
  else if ExitCode <> 0 then
    Result := 'Zeyin Melody preflight rejected this installation. Follow the displayed recovery guidance, then retry.';
end;

procedure CurStepChanged(CurStep: TSetupStep);
var
  ExitCode: Integer;
  TemporaryBootstrap: String;
begin
  if CurStep <> ssInstall then
    exit;
  TemporaryBootstrap := ExpandConstant('{tmp}\setup-bootstrap.ps1');
  if not RunBootstrap(TemporaryBootstrap, '-Install', WizardSilent, ExitCode) then
    RaiseException('Zeyin Melody initialization could not be started.');
  if ExitCode <> 0 then
    RaiseException(
      'Zeyin Melody initialization failed (exit code ' + IntToStr(ExitCode) +
      '). Installed application files were not committed.'
    );
end;

procedure CurUninstallStepChanged(CurUninstallStep: TUninstallStep);
var
  ExitCode: Integer;
begin
  if CurUninstallStep <> usUninstall then
    exit;
  if not RunBootstrap(ExpandConstant('{app}\setup-bootstrap.ps1'), '-Uninstall', True, ExitCode) then
    RaiseException('Zeyin Melody restoration could not be started. Recovery material was preserved.');
  if ExitCode <> 0 then
    RaiseException(
      'Zeyin Melody could not restore Codex (exit code ' + IntToStr(ExitCode) +
      '). Recovery material was preserved and uninstall was stopped.'
    );
end;
