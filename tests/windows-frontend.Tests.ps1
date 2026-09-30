param(
    [string]$InstallerPath = (Join-Path $PSScriptRoot '..\scripts\install_windows.ps1'),
    [string]$WorkRoot = (Join-Path ([IO.Path]::GetTempPath()) ('claude-frontend-tests-' + [guid]::NewGuid().ToString('N'))),
    [switch]$ForceFallback
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'frontend-test-support.ps1') $InstallerPath
if (Test-Path $WorkRoot) { throw "WorkRoot must not exist: $WorkRoot" }
New-Item -ItemType Directory $WorkRoot | Out-Null
$script:Passed = 0
$script:Failed = 0
$script:CaseId = 0
# Fixtures inject rule data, not replacement behavior. The production patcher and backups run unchanged.
function Get-FrontendHardcodedReplacements { param($Language); return $script:Rules }
if ($ForceFallback) {
    function Add-Type { throw 'Deliberately unavailable in fallback test' }
}
function Assert-Equal($Actual, $Expected, [string]$Message) {
    if ($Actual -cne $Expected) { throw "$Message (expected=$Expected, actual=$Actual)" }
}
function New-Fixture {
    $script:CaseId++
    $script:CurrentBackupSetPath = $null
    $root = Join-Path $WorkRoot "case-$script:CaseId"
    New-Item -ItemType Directory (Join-Path $root 'ion-dist\assets\v1') -Force | Out-Null
    return $root
}
function Write-Js($Root, $Name, $Text) {
    $path = Join-Path $Root "ion-dist\assets\v1\$Name"
    [IO.File]::WriteAllText($path, $Text, $Utf8NoBom)
    return $path
}
function Test-Case([string]$Name, [scriptblock]$Body) {
    try { & $Body; $script:Passed++; Write-Host "PASS $Name" }
    catch { $script:Failed++; Write-Host "FAIL ${Name}: $($_.Exception.Message)" }
}
Test-Case 'short-rule-only file is translated (Copy, Pin, Books)' {
    $r = New-Fixture
    $p = Write-Js $r 'short.js' 'const labels=["Copy","Pin","Books"];'
    $script:Rules = @(@('Copy','COPIED'), @('Pin','PINNED'), @('Books','BOOKS-TRANSLATED'))
    Patch-HardcodedFrontendStrings $r 'zh-CN'
    Assert-Equal ([IO.File]::ReadAllText($p)) 'const labels=["COPIED","PINNED","BOOKS-TRANSLATED"];' 'short UI labels were skipped'
}
Test-Case 'newline-only direct rule is translated' {
    $r = New-Fixture
    $p = Write-Js $r 'multiline.js' "const s=``first`nsecond``;"
    $script:Rules = ,@("first`nsecond", 'TRANSLATED')
    Patch-HardcodedFrontendStrings $r 'zh-CN'
    Assert-Equal ([IO.File]::ReadAllText($p)) 'const s=`TRANSLATED`;' 'newline rule was skipped'
}
Test-Case 'Unicode-only rule is translated' {
    $r = New-Fixture
    $source = ([string][char]0x4e2d) * 10
    $p = Write-Js $r 'unicode.js' ('const x="' + $source + '";')
    $script:Rules = ,@($source, 'TRANSLATED')
    Patch-HardcodedFrontendStrings $r 'zh-CN'
    Assert-Equal ([IO.File]::ReadAllText($p)) 'const x="TRANSLATED";' 'Unicode rule was skipped'
}
Test-Case 'hardcoded scanner preserves unrelated and structural JS' {
    $r = New-Fixture
    $original = 'const a={icon:"Copy",name:"Copy",role:"Copy",type:"Copy"};const b="unrelated";'
    $p = Write-Js $r 'unrelated.js' $original
    $script:Rules = ,@('Copy', 'COPIED')
    $stamp = [IO.File]::GetLastWriteTimeUtc($p)
    Patch-HardcodedFrontendStrings $r 'zh-CN'
    Assert-Equal ([IO.File]::ReadAllText($p)) $original 'structural JS changed'
    Assert-Equal ([IO.File]::GetLastWriteTimeUtc($p)) $stamp 'unrelated JS rewritten'
    Assert-Equal (Test-Path (Join-Path $r '.zh-cn-backups')) $false 'unnecessary backup'
}
Test-Case 'selector finds an ASCII needle across the 1 MiB boundary' {
    $r = New-Fixture
    $p = Write-Js $r 'boundary.js' (('x' * (1MB - 5)) + 'Intl.DisplayNames')
    $found = @(Get-FrontendJsFilesContaining (Split-Path $p) @('Intl.DisplayNames'))
    Assert-Equal $found.Count 1 'boundary match missing'
    Assert-Equal $found[0].FullName $p 'wrong file selected'
}
Test-Case 'selector finds a Unicode needle split inside UTF-8 bytes' {
    $r = New-Fixture
    $needle = [string][char]0x4e2d + [char]0x6587
    $p = Write-Js $r 'utf8-boundary.js' (('x' * (1MB - 1)) + $needle)
    Assert-Equal @(Get-FrontendJsFilesContaining (Split-Path $p) @($needle)).Count 1 'Unicode boundary match missing'
}
Test-Case 'selector overlap follows needle length beyond 4096' {
    $r = New-Fixture
    $needle = ('A' * 5000) + 'END'
    $p = Write-Js $r 'long-boundary.js' (('x' * (1MB - 4500)) + $needle)
    Assert-Equal @(Get-FrontendJsFilesContaining (Split-Path $p) @($needle)).Count 1 'long boundary match missing'
}
Test-Case 'selector is ordinal, deduplicates files, ignores non-JS and directories' {
    $r = New-Fixture
    $p = Write-Js $r 'match.js' 'Intl.DisplayNames;__claudeZhLabelPatch;'
    Write-Js $r 'case.js' 'intl.displaynames' | Out-Null
    Write-Js $r 'other.txt' 'Intl.DisplayNames' | Out-Null
    New-Item -ItemType Directory (Join-Path (Split-Path $p) 'folder.js') | Out-Null
    $found = @(Get-FrontendJsFilesContaining (Split-Path $p) @('Intl.DisplayNames','__claudeZhLabelPatch'))
    Assert-Equal $found.Count 1 'wrong match count'
    Assert-Equal $found[0].FullName $p 'wrong file selected'
}
Test-Case 'selector empty needles and no matches return no files' {
    $r = New-Fixture
    $p = Write-Js $r 'other.js' 'nothing'
    Assert-Equal @(Get-FrontendJsFilesContaining (Split-Path $p) @()).Count 0 'empty needles matched'
    Assert-Equal @(Get-FrontendJsFilesContaining (Split-Path $p) @('missing')).Count 0 'false match'
}
Test-Case 'selector empty assets fails explicitly' {
    $r = New-Fixture
    $threw = $false
    try { Get-FrontendJsFilesContaining (Join-Path $r 'ion-dist\assets\v1') @('missing') } catch { $threw = $true }
    Assert-Equal $threw $true 'missing bundles accepted'
}
Test-Case 'registration updates every whitelist, preserves originals and is idempotent' {
    $r = New-Fixture
    $original = 'const a=' + $BaseLanguageList + '];const b=' + $BaseLanguageList + ',"zh-TW"];'
    $p = Write-Js $r 'language.js' $original
    $u = Write-Js $r 'unrelated.js' 'const untouched=true;'
    $stamp = [IO.File]::GetLastWriteTimeUtc($u)
    Register-Language $r 'zh-CN'
    $expected = 'const a=' + $BaseLanguageList + ',"zh-CN"];const b=' + $BaseLanguageList + ',"zh-CN"];'
    Assert-Equal ([IO.File]::ReadAllText($p)) $expected 'not all whitelists updated'
    $patchedStamp = [IO.File]::GetLastWriteTimeUtc($p)
    Register-Language $r 'zh-CN'
    Assert-Equal ([IO.File]::GetLastWriteTimeUtc($p)) $patchedStamp 'repeat rewrites file'
    Assert-Equal ([IO.File]::GetLastWriteTimeUtc($u)) $stamp 'unrelated file rewritten'
    $backups = @(Get-ChildItem (Join-Path $r '.zh-cn-backups') -Recurse -File)
    Assert-Equal $backups.Count 1 'unexpected backup count'
    Assert-Equal ([IO.File]::ReadAllText($backups[0].FullName)) $original 'backup not original'
}
Test-Case 'registration refuses changed whitelist format' {
    $r = New-Fixture
    Write-Js $r 'other.js' 'const noWhitelist=true;' | Out-Null
    $threw = $false
    try { Register-Language $r 'zh-CN' } catch { $threw = $true }
    Assert-Equal $threw $true 'missing whitelist accepted'
}
Test-Case 'label shim touches only relevant files and is idempotent' {
    $r = New-Fixture
    $original = 'const names=new Intl.DisplayNames(["en"],{type:"language"});'
    $p = Write-Js $r 'labels.js' $original
    $u = Write-Js $r 'unrelated.js' 'const unrelated=true;'
    $legacy = Write-Js $r 'already.js' '/* __claudeZhLabelPatch */'
    $stamp = [IO.File]::GetLastWriteTimeUtc($u)
    Patch-LanguageDisplayNames $r
    $updated = [IO.File]::ReadAllText($p)
    Assert-Equal ($updated.StartsWith($original)) $true 'original content changed'
    Assert-Equal ($updated.Contains('Object.defineProperty(e,"__claudeZhLabelPatch"')) $true 'shim missing'
    $patchedStamp = [IO.File]::GetLastWriteTimeUtc($p)
    Patch-LanguageDisplayNames $r
    Assert-Equal ([IO.File]::ReadAllText($p)) $updated 'duplicate shim'
    Assert-Equal ([IO.File]::GetLastWriteTimeUtc($p)) $patchedStamp 'repeat rewrites file'
    Assert-Equal ([IO.File]::GetLastWriteTimeUtc($u)) $stamp 'unrelated JS rewritten'
    Assert-Equal ([IO.File]::ReadAllText($legacy)) '/* __claudeZhLabelPatch */' 'legacy marker changed'
    $backups = @(Get-ChildItem (Join-Path $r '.zh-cn-backups') -Recurse -File)
    Assert-Equal $backups.Count 1 'unrelated JS backed up'
    Assert-Equal ([IO.File]::ReadAllText($backups[0].FullName)) $original 'backup not original'
}
Test-Case 'label shim skips safely when no relevant bundle exists' {
    $r = New-Fixture
    $p = Write-Js $r 'unrelated.js' 'const unrelated=true;'
    Patch-LanguageDisplayNames $r
    Assert-Equal ([IO.File]::ReadAllText($p)) 'const unrelated=true;' 'unrelated changed'
    Assert-Equal (Test-Path (Join-Path $r '.zh-cn-backups')) $false 'unnecessary backup'
}
Test-Case 'unregistration removes whitelist entries and skips unrelated files' {
    $r = New-Fixture
    $original = 'const a=' + $BaseLanguageList + ',"zh-CN"];const b=' + $BaseLanguageList + ',"zh-TW"];'
    $p = Write-Js $r 'language.js' $original
    $u = Write-Js $r 'unrelated.js' 'const untouched=true;'
    $stamp = [IO.File]::GetLastWriteTimeUtc($u)
    Unregister-Language $r
    $expected = 'const a=' + $BaseLanguageList + '];const b=' + $BaseLanguageList + '];'
    Assert-Equal ([IO.File]::ReadAllText($p)) $expected 'whitelist entries not removed'
    Assert-Equal ([IO.File]::GetLastWriteTimeUtc($u)) $stamp 'unrelated file rewritten'
}
Test-Case 'unregistration skips safely when no matching bundles exist' {
    $r = New-Fixture
    $p = Write-Js $r 'unrelated.js' 'const unrelated=true;'
    $stamp = [IO.File]::GetLastWriteTimeUtc($p)
    Unregister-Language $r
    Assert-Equal ([IO.File]::ReadAllText($p)) 'const unrelated=true;' 'unrelated changed'
    Assert-Equal ([IO.File]::GetLastWriteTimeUtc($p)) $stamp 'unrelated file rewritten'
}
Write-Host "RESULT passed=$script:Passed failed=$script:Failed PowerShell=$($PSVersionTable.PSVersion) fallback=$ForceFallback fixtures=$WorkRoot"
if ($script:Failed) { exit 1 }
