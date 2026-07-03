; ==============================================================================
; Pro AutoZoom (Ultimate Community Edition) - Inno Setup Script
; Encoding: UTF-8
; Version: 1.0
; Author:  gipstamusic
; URL:     https://github.com/gipstamusic/pro-autozoom-obs
;
; BUILD INSTRUCTIONS
; ------------------
; 1. Install Inno Setup 6 from https://jrsoftware.org/isinfo.php
; 2. Place this .iss file in the same folder as your source files:
;       Pro_auto_zoom_ultimate_v1.0_community_edition.lua
;       README.md
;       LICENSE
;       help.html
;       SetupIcon.ico   (optional - remove the SetupIconFile line below if absent)
;       CHANGELOG.md    (optional - remove the matching [Files] line below if absent)
; 3. Open this .iss file in the Inno Setup IDE and click Build > Compile.
;    Or from command line: iscc.exe "ProAutoZoom_Setup.iss"
; 4. The output installer will be placed in the Output\ subfolder.
;
; PORTABLE OBS DETECTION STRATEGY
; --------------------------------
; OBS can be installed in three ways:
;   (A) Standard installer  -> scripts live in %APPDATA%\obs-studio\basic\scripts
;   (B) Microsoft Store     -> scripts live in a sandboxed AppData location
;   (C) Portable            -> scripts live next to obs64.exe, anywhere the user chose
;
; This installer handles all three:
;   1. Checks HKCU registry for the standard OBS install path.
;   2. Falls back to %APPDATA%\obs-studio\basic\scripts if registry is absent.
;   3. If neither exists, leaves the dir field blank so the user can browse.
;   4. A [Code] section validates the chosen path before allowing install to proceed,
;      and warns (but does not block) if the folder doesn't look like a scripts dir.
;   5. A "Portable OBS?" hint is shown on the directory page explaining where to browse.
; ==============================================================================


; -- APP IDENTITY --------------------------------------------------------------
[Setup]
AppId={{A3F7C2D1-84BE-4E10-B2C5-9F6D0E8A1234}
AppName=Pro AutoZoom (Ultimate Community Edition)
AppVersion=1.0
AppVerName=Pro AutoZoom v1.0 Community Edition
AppPublisher=gipstamusic
AppPublisherURL=https://lnk.bio/gipstamusic
AppSupportURL=https://github.com/gipstamusic/pro-autozoom-obs/issues
AppUpdatesURL=https://github.com/gipstamusic/pro-autozoom-obs/releases

; -- OUTPUT --------------------------------------------------------------------
OutputDir=Output
OutputBaseFilename=ProAutoZoom_v1.0_Setup
SetupIconFile=SetupIcon.ico
; Remove the line above if you don't have SetupIcon.ico in your folder
; UninstallDisplayIcon={app}\Pro_auto_zoom_ultimate_v1.0_community_edition.lua

; -- INSTALLER APPEARANCE ------------------------------------------------------
WizardStyle=modern
; Optionally point to a 164x314 WizardImage and 55x58 WizardSmallImage:
; WizardImageFile=InstallerBanner.bmp
; WizardSmallImageFile=InstallerSmall.bmp

; -- BEHAVIOUR -----------------------------------------------------------------
DefaultDirName={code:GetDefaultInstallDir}
DisableProgramGroupPage=yes
AllowNoIcons=yes
PrivilegesRequired=lowest
PrivilegesRequiredOverridesAllowed=dialog

; -- COMPRESSION ---------------------------------------------------------------
Compression=lzma2/ultra
SolidCompression=yes

; -- WINDOWS VERSION -----------------------------------------------------------
MinVersion=10.0

; -- LICENCE -------------------------------------------------------------------
LicenseFile=LICENSE


; -- FILES TO INSTALL ----------------------------------------------------------
[Files]
; The Lua script goes into the chosen scripts folder (the install dir)
Source: "Pro_auto_zoom_ultimate_v1.0_community_edition.lua"; \
    DestDir: "{app}"; \
    Flags: ignoreversion

; Docs go into a subfolder so they're easy to find but don't clutter the scripts dir
Source: "LICENSE";      DestDir: "{app}\ProAutoZoom"; Flags: ignoreversion
Source: "help.html";    DestDir: "{app}\ProAutoZoom"; Flags: ignoreversion
; CHANGELOG.md - include if present, silently skipped if not
Source: "CHANGELOG.md"; DestDir: "{app}\ProAutoZoom"; Flags: ignoreversion skipifsourcedoesntexist


; -- SHORTCUTS -----------------------------------------------------------------
[Icons]
; Desktop shortcut to the help guide (optional -- users can untick this)
Name: "{userdesktop}\Pro AutoZoom Help"; \
    Filename: "{app}\ProAutoZoom\help.html"; \
    Tasks: desktophelp

; Start Menu shortcut to the help guide
Name: "{userprograms}\Pro AutoZoom\Help Guide"; \
    Filename: "{app}\ProAutoZoom\help.html"

Name: "{userprograms}\Pro AutoZoom\View on GitHub"; \
    Filename: "https://github.com/gipstamusic/pro-autozoom-obs"

Name: "{userprograms}\Pro AutoZoom\Uninstall Pro AutoZoom"; \
    Filename: "{uninstallexe}"


; -- OPTIONAL TASKS ------------------------------------------------------------
[Tasks]
Name: desktophelp; \
    Description: "Create a desktop shortcut to the Help Guide"; \
    GroupDescription: "Additional shortcuts:"; \
    Flags: unchecked


; -- POST-INSTALL ACTIONS ------------------------------------------------------
[Run]
; Offer to open the help guide after install
Filename: "{app}\ProAutoZoom\help.html"; \
    Description: "Open the Help Guide now (recommended for first-time setup)"; \
    Flags: postinstall shellexec skipifsilent unchecked

; Offer to open the OBS scripts folder so the user can add the script in OBS
Filename: "{app}"; \
    Description: "Open the OBS scripts folder (so you can add it in OBS)"; \
    Flags: postinstall shellexec skipifsilent unchecked


; -- UNINSTALL CLEANUP ---------------------------------------------------------
[UninstallDelete]
; Remove the docs subfolder on uninstall (the Lua file itself is handled automatically)
Type: filesandordirs; Name: "{app}\ProAutoZoom"


; ==============================================================================
; CODE SECTION
; Handles:
;   1. Auto-detecting the OBS scripts directory (standard install & registry)
;   2. Showing a friendly explanation on the directory page for portable OBS users
;   3. Validating that the chosen path looks like an OBS scripts folder
; ==============================================================================
[Code]
const
  // Newline constant -- avoids #13#10 inline which Inno Setup's preprocessor
  // misreads as a preprocessor directive when it appears mid-expression.
  NL = #13#10;

  // Standard per-user OBS scripts path (non-portable install)
  STANDARD_SCRIPTS_SUBPATH = 'obs-studio\basic\scripts';

  // Registry key written by the official OBS installer
  OBS_REG_KEY  = 'Software\OBS Studio';
  OBS_REG_VAL  = '';   // Default value -- contains the OBS install root


// -- HELPERS ------------------------------------------------------------------

// Try to find the OBS scripts folder automatically.
// Priority:
//   1. Standard AppData path (works for ~90% of users)
//   2. Registry-based path  (for users who changed the install location)
//   3. Empty string         (portable users -- let them browse)
function FindOBSScriptsDir(): String;
var
  AppDataPath: String;
  RegInstallPath: String;
  Candidate: String;
begin
  Result := '';

  // -- Option 1: standard %APPDATA% location ------------------------------
  AppDataPath := ExpandConstant('{userappdata}');
  Candidate   := AppDataPath + '\' + STANDARD_SCRIPTS_SUBPATH;

  if DirExists(Candidate) then
  begin
    Result := Candidate;
    Exit;
  end;

  // -- Option 2: registry (official OBS installer writes this key) ---------
  // The key holds the OBS *install* root (e.g. C:\Program Files\obs-studio).
  // The scripts folder is always in the user's AppData regardless of install
  // location, so this is really just a secondary confirmation that OBS is
  // installed -- we still point at AppData for the scripts path.
  if RegQueryStringValue(HKCU, OBS_REG_KEY, OBS_REG_VAL, RegInstallPath) then
  begin
    // OBS is installed (standard). If we get here, the AppData path should
    // have existed, but create it just in case OBS was never launched.
    if not DirExists(Candidate) then
      ForceDirectories(Candidate);

    if DirExists(Candidate) then
    begin
      Result := Candidate;
      Exit;
    end;
  end;

  // -- Option 3: not found -- leave blank so the user browses ---------------
  // Portable OBS users will need to browse to:
  //   <wherever they put OBS>\config\obs-studio\basic\scripts
  // The directory page label below explains this.
  Result := '';
end;


// Returns the default install dir used by [Setup] DefaultDirName={code:...}
function GetDefaultInstallDir(Param: String): String;
var
  Found: String;
begin
  Found := FindOBSScriptsDir();

  if Found <> '' then
    Result := Found
  else
    // Leave as a descriptive placeholder -- the user will need to browse.
    // Using the standard path as a starting point even if it doesn't exist
    // yet, so the user sees the right shape of path and can correct it.
    Result := ExpandConstant('{userappdata}\') + STANDARD_SCRIPTS_SUBPATH;
end;


// -- INIT WIZARD --------------------------------------------------------------
// Runs after the wizard is created. We customise the directory page label to
// explain what the path should be and help portable OBS users.
procedure InitializeWizard();
begin
  // The directory page description is the subtitle under "Select Destination"
  // Override it with useful guidance.
  WizardForm.DirEdit.Hint :=
    'This must be the OBS Studio scripts folder. ' +
    'If you use portable OBS, browse to: ' +
    '[your OBS folder]\config\obs-studio\basic\scripts';

  // Make the hint visible on hover -- also set it on the browse button
  WizardForm.DirBrowseButton.Hint := WizardForm.DirEdit.Hint;
  WizardForm.DirEdit.ShowHint     := True;
  WizardForm.DirBrowseButton.ShowHint := True;
end;


// -- PATH VALIDATION ----------------------------------------------------------
// Called when the user clicks Next on the directory selection page.
// Warns if the path doesn't look like an OBS scripts folder, but lets them
// proceed anyway (they might know something we don't).
function NextButtonClick(CurPageID: Integer): Boolean;
var
  ChosenDir: String;
  PathLower: String;
  Msg: String;
  Answer: Integer;
begin
  Result := True;   // Default: allow proceeding

  if CurPageID = wpSelectDir then
  begin
    ChosenDir := WizardForm.DirEdit.Text;
    PathLower := Lowercase(ChosenDir);

    // -- Check 1: does it at least contain 'obs' somewhere? --------------
    if Pos('obs', PathLower) = 0 then
    begin
      Msg :=
        'The selected folder does not appear to be an OBS Studio scripts folder:' +
        NL + NL +
        '  ' + ChosenDir +
        NL + NL +
        'The folder should be inside an OBS directory and end with:' + NL +
        '  ...\obs-studio\basic\scripts' + NL + NL +
        'If you use portable OBS, browse to:' + NL +
        '  [your OBS folder]\config\obs-studio\basic\scripts' + NL + NL +
        'Install here anyway?';

      Answer := MsgBox(Msg, mbConfirmation, MB_YESNO);
      Result  := (Answer = IDYES);
      Exit;
    end;

    // -- Check 2: does it end with \scripts? -----------------------------
    if Copy(PathLower, Length(PathLower) - 6, 7) <> 'scripts' then
    begin
      Msg :=
        'The selected folder doesn''t end with "\scripts":' +
        NL + NL +
        '  ' + ChosenDir +
        NL + NL +
        'The Lua script must go into the OBS scripts folder:' + NL +
        '  ...\obs-studio\basic\scripts' + NL + NL +
        'Installing to the wrong folder means OBS won''t find the script.' +
        NL + NL +
        'Install here anyway?';

      Answer := MsgBox(Msg, mbConfirmation, MB_YESNO);
      Result  := (Answer = IDYES);
      Exit;
    end;

    // -- Check 3: does the folder actually exist? -------------------------
    // If not, offer to create it (might be first time OBS was launched, etc.)
    if not DirExists(ChosenDir) then
    begin
      Msg :=
        'The folder does not exist yet:' +
        NL + NL +
        '  ' + ChosenDir +
        NL + NL +
        'This is normal if OBS has never been opened before.' + NL +
        'The installer will create the folder.' + NL + NL +
        'Make sure OBS is installed before you try to use the script.' +
        NL + NL +
        'Continue?';

      Answer := MsgBox(Msg, mbConfirmation, MB_YESNO);
      Result  := (Answer = IDYES);
      // Inno Setup will create missing destination dirs automatically, so no
      // manual ForceDirectories() call needed here.
      Exit;
    end;

  end; // CurPageID = wpSelectDir
end;


// -- CUSTOM DIRECTORY PAGE SUBTITLE ------------------------------------------
// Show a short note below the directory input reminding about portable OBS.
// We do this by appending a note to the page's description label after the
// wizard has been created.
procedure CurPageChanged(CurPageID: Integer);
begin
  if CurPageID = wpSelectDir then
  begin
    // The DirSelectPage description is editable at runtime.
    WizardForm.SelectDirLabel.Caption :=
      'The script must be placed in the OBS Studio scripts folder.' + NL +
      NL +
      'Standard install (auto-detected):' + NL +
      '  %APPDATA%\obs-studio\basic\scripts' + NL +
      NL +
      'Portable OBS -- browse to:' + NL +
      '  [your OBS folder]\config\obs-studio\basic\scripts' + NL +
      NL +
      'Not sure? Open OBS, go to Tools > Scripts, and click + to see' + NL +
      'which folder OBS is looking in.';
  end;
end;
