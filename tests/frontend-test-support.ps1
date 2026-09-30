# Load only the frontend functions/constants; never execute installer entry points.
param([string]$InstallerPath = (Join-Path $PSScriptRoot '..\scripts\install_windows.ps1'))
$ErrorActionPreference = 'Stop'
$tokens = $null
$parseErrors = $null
$installerText = [IO.File]::ReadAllText((Resolve-Path $InstallerPath), [Text.Encoding]::UTF8)
$installerAst = [Management.Automation.Language.Parser]::ParseInput($installerText, [ref]$tokens, [ref]$parseErrors)
if ($parseErrors.Count) { throw ($parseErrors | Out-String) }
$functionNames = @(
    'Require-File', 'Get-BackupRoot', 'New-BackupSet', 'Get-RelativeResourcePath', 'Backup-ModifiedFile',
    'Get-FrontendJsFilesContaining', 'Register-Language', 'Unregister-Language', 'Patch-LanguageDisplayNames',
    'Get-FrontendHardcodedReplacements', 'Test-PlainUiTextReplacement', 'Test-StructuralJsReplacement',
    'Test-StructuralJsLiteralContext', 'Replace-FrontendHardcodedText', 'Patch-HardcodedFrontendStrings'
)
$constantNames = @('Utf8NoBom', 'BaseLanguageList', 'LanguageListPattern', 'script:FrontendPatcherCSharp')
foreach ($statement in $installerAst.EndBlock.Statements) {
    if (($statement -is [Management.Automation.Language.FunctionDefinitionAst]) -and
        ($statement.Name -in $functionNames)) {
        . ([scriptblock]::Create($statement.Extent.Text))
    } elseif (($statement -is [Management.Automation.Language.AssignmentStatementAst]) -and
        ($statement.Left -is [Management.Automation.Language.VariableExpressionAst]) -and
        ($statement.Left.VariablePath.UserPath -in $constantNames)) {
        . ([scriptblock]::Create($statement.Extent.Text))
    }
}
$script:CurrentBackupSetPath = $null
