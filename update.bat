@echo off
setlocal
REM ===========================================================================
REM  LazCraft updater - single file.
REM  Put this next to init.lua:  ...\MacroQuest\lua\Lazcraft\update.bat
REM  Then double-click it.
REM
REM  Running this gives you the current files. Anything listed in the manifest
REM  is brought to the published version - local edits to those files are
REM  replaced (the old copy goes to a timestamped backup folder). Settings\ and
REM  Logs\ are never listed, so per-character settings always survive.
REM
REM  Updates are decided PER FILE, by hash - not by the code version. Editing
REM  merchants.ini alone ships to everyone without touching init.lua.
REM
REM  The PowerShell that does the work is at the bottom of this same file,
REM  after the LAST #PSSTART# marker. cmd never reaches it; PowerShell reads
REM  this file and runs that half. [-1] not [1]: the marker name also appears
REM  in these comments and in the command below, so only the final split is
REM  guaranteed to be the script body.
REM ===========================================================================

set "LC_BASEURL=https://raw.githubusercontent.com/sebbun123/Lazcraft/main"

REM  No argument = the repo root, where init.lua already lives.
REM  Pass a name to use a subfolder instead, e.g.  update.bat test
set "LC_CHANNEL=%~1"
set "LC_TARGET=%~dp0"

echo.
echo   LazCraft updater
if "%LC_CHANNEL%"=="" (echo   source  : repo root) else (echo   source  : %LC_CHANNEL%)
echo   folder  : %LC_TARGET%
echo.

powershell -NoProfile -ExecutionPolicy Bypass -Command "$b=[IO.File]::ReadAllText('%~f0'); iex (($b -split '#PSSTART#')[-1])"

:done
echo.
echo   ---- finished. Press any key to close. ----
pause >nul
endlocal
exit /b

#PSSTART#
$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$BaseUrl   = $env:LC_BASEURL
$Channel   = $env:LC_CHANNEL
$TargetDir = $env:LC_TARGET
$root      = if ([string]::IsNullOrWhiteSpace($Channel)) { $BaseUrl } else { "$BaseUrl/$Channel" }
$stage     = Join-Path $env:TEMP ("lc_update_" + [guid]::NewGuid().ToString('N'))

function Say($m, $c = 'Gray') { Write-Host "  $m" -ForegroundColor $c }
function Sha($p) { if (Test-Path $p) { (Get-FileHash -Path $p -Algorithm SHA256).Hash.ToLower() } else { '' } }

try {
    # ---- manifest ----------------------------------------------------------
    try {
        $manifestText = (Invoke-WebRequest -UseBasicParsing -Uri "$root/manifest.txt").Content
    } catch {
        Say "Could not read $root/manifest.txt" 'Red'
        Say $_.Exception.Message 'Red'
        return
    }

    # Two verbs, and that is the whole model: a file is either published or retired.
    #   file   - brought to the published version.
    #   delete - removed from the install.
    # build and config are version stamps, shown here and recorded for the UI to read.
    $build = '(unversioned)'; $configVer = ''
    $files = @()
    foreach ($line in ($manifestText -split "`r?`n")) {
        $t = $line.Trim()
        if ($t -eq '' -or $t.StartsWith('#')) { continue }
        $p = $t -split '\s+'
        switch ($p[0]) {
            'build'   { $build = $p[1] }
            'config'  { $configVer = $p[1] }
            'file'    { $files += [pscustomobject]@{ Path=$p[1]; Sha=$p[2].ToLower(); Mode='file' } }
            'delete'  { $files += [pscustomobject]@{ Path=$p[1]; Sha='';              Mode='delete' } }
        }
    }
    if ($files.Count -eq 0) { Say "Manifest lists no files - stopping." 'Red'; return }

    $haveBuild = '(none)'
    $initPath  = Join-Path $TargetDir 'init.lua'
    if (Test-Path $initPath) {
        $m = Select-String -Path $initPath -Pattern "BUILD_TAG\s*=\s*'([^']+)'" | Select-Object -First 1
        if ($m) { $haveBuild = $m.Matches[0].Groups[1].Value }
    }
    Say "code installed : $haveBuild"
    Say "code available : $build"
    if ($configVer) { Say "config set     : $configVer" }
    Say ""

    # ---- decide, per file, before touching anything ------------------------
    # Per file rather than on the build tag: a config-only release ships without anyone
    # having to remember to bump the code version, and a file that already matches is not
    # even downloaded.
    $need = @(); $toDelete = @()
    foreach ($f in $files) {
        $dst = Join-Path $TargetDir $f.Path
        if ($f.Mode -eq 'delete') { if (Test-Path $dst) { $toDelete += $f.Path }; continue }
        if ((Sha $dst) -eq $f.Sha) { continue }
        $need += $f
    }

    if ($need.Count -eq 0 -and $toDelete.Count -eq 0) { Say "Everything is current." 'Green'; return }

    # ---- ALL OR NOTHING ----------------------------------------------------
    # Everything is downloaded and hash-checked before a single file in the target folder
    # is touched. A half-applied update is worse than an old one: the failure looks like a
    # logic bug rather than a bad download.
    New-Item -ItemType Directory -Path $stage -Force | Out-Null
    foreach ($f in $need) {
        $dst = Join-Path $stage $f.Path
        New-Item -ItemType Directory -Path (Split-Path $dst -Parent) -Force | Out-Null
        Say "fetching $($f.Path)"
        try {
            Invoke-WebRequest -UseBasicParsing -Uri "$root/$($f.Path)" -OutFile $dst
        } catch {
            Say "FAILED to download $($f.Path) - nothing changed." 'Red'
            Say $_.Exception.Message 'Red'; return
        }
        $got = Sha $dst
        if ($got -ne $f.Sha) {
            Say "CHECKSUM MISMATCH on $($f.Path) - nothing changed." 'Red'
            Say "  expected $($f.Sha)" 'Red'
            Say "  got      $got" 'Red'
            return
        }
    }

    # ---- back up, then swap ------------------------------------------------
    $backup = Join-Path $TargetDir ("backup-" + (Get-Date -Format 'yyyyMMdd-HHmmss'))
    New-Item -ItemType Directory -Path $backup -Force | Out-Null

    foreach ($f in $need) {
        $dst = Join-Path $TargetDir $f.Path
        if (Test-Path $dst) {
            $bk = Join-Path $backup $f.Path
            New-Item -ItemType Directory -Path (Split-Path $bk -Parent) -Force | Out-Null
            Copy-Item $dst $bk -Force
        }
        New-Item -ItemType Directory -Path (Split-Path $dst -Parent) -Force | Out-Null
        Copy-Item (Join-Path $stage $f.Path) $dst -Force
        Say "updated  $($f.Path)" 'Green'
    }
    foreach ($rel in $toDelete) {
        $dst = Join-Path $TargetDir $rel
        $bk  = Join-Path $backup $rel
        New-Item -ItemType Directory -Path (Split-Path $bk -Parent) -Force | Out-Null
        Move-Item $dst $bk -Force
        Say "removed  $rel" 'Yellow'
    }

    # ---- record the versions now on disk -----------------------------------
    # Read back by the Settings tab, so a bug report carries the config version alongside
    # the code version. Written last, after every copy succeeded.
    [IO.File]::WriteAllText((Join-Path $TargetDir 'installed.txt'),
        "# LazCraft - written by update.bat. Do not edit.`r`n# build $build`r`n# config $configVer`r`n",
        [Text.Encoding]::ASCII)

    Say ""
    Say "Now on $build." 'Green'
    if ($configVer) { Say "Config set $configVer." 'Green' }
    Say "Replaced files kept in: $backup"
    Say ""
    Say "In game:  /lua run Lazcraft                    the crafter, with the UI" 'Cyan'
    Say "          /lua run Lazcraft worker <crafter>   a mule, headless" 'Cyan'
}
catch {
    Say "Unexpected error - nothing was changed." 'Red'
    Say $_.Exception.Message 'Red'
}
finally {
    if (Test-Path $stage) { Remove-Item $stage -Recurse -Force -ErrorAction SilentlyContinue }
}
