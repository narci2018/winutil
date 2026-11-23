$ErrorActionPreference = 'Stop'
$fail = 0
function Check($cond, $msg) {
    if ($cond) { Write-Output "PASS: $msg" } else { Write-Output "FAIL: $msg"; $script:fail++ }
}

# 1. PowerShell parser check on every changed/new source file.
$psFiles = @(
    'functions\private\Initialize-WinUtilOfficeTab.ps1',
    'functions\private\Initialize-WinUtilTabContent.ps1',
    'functions\public\Invoke-WPFTab.ps1',
    'functions\public\Invoke-WPFButton.ps1'
)
foreach ($f in $psFiles) {
    $tokens = $null; $errors = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot $f), [ref]$tokens, [ref]$errors)
    Check ($errors.Count -eq 0) "Parser: $f ($($errors.Count) errors)"
    foreach ($e in $errors) { Write-Output "     $($e.Message) @ line $($e.Extent.StartLineNumber)" }
}

# 2. XAML well-formedness.
$xamlPath = Join-Path $PSScriptRoot 'xaml\inputXML.xaml'
try {
    [xml]$xaml = Get-Content -LiteralPath $xamlPath -Raw -Encoding UTF8
    Check $true 'XAML parses as XML'
} catch {
    Check $false "XAML parses as XML : $($_.Exception.Message)"
}

# 3. Every control name referenced by the Office logic exists in the XAML.
$logic = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'functions\private\Initialize-WinUtilOfficeTab.ps1') -Raw -Encoding UTF8
$names = [regex]::Matches($logic, "sync\['(WPFOffice[A-Za-z]+|WPFActivate[A-Za-z]*|WPFUnactivate)'\]") |
    ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique
foreach ($n in $names) {
    Check ($xaml.SelectSingleNode("//*[@Name='$n']") -ne $null) "XAML has control $n"
}

# 4. NavView item + tab key wiring.
Check ($xaml.OuterXml -match 'Tag="WPFTab9"') 'NavView has WPFTab9 item'
$wpfTab = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'functions\public\Invoke-WPFTab.ps1') -Raw -Encoding UTF8
Check ($wpfTab -match '"Office Deployment"') 'Invoke-WPFTab tabKeyByIndex includes Office Deployment'
$tabContent = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'functions\private\Initialize-WinUtilTabContent.ps1') -Raw -Encoding UTF8
Check ($tabContent -match '"Office Deployment"\s*\{\s*Initialize-WinUtilOfficeTab') 'TabContent routes Office Deployment'
$btn = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'functions\public\Invoke-WPFButton.ps1') -Raw -Encoding UTF8
Check ($btn -match "Invoke-WinUtilOfficeButton") 'Button router calls Invoke-WinUtilOfficeButton'

# 5. Semantics: correct ODT schema, no <Applications>, correct channel binding, MAS source.
# Strip comment lines so documentation mentioning bad patterns does not trip the assertions.
$codeOnly = (($logic -split "`r?`n") | Where-Object { $_ -notmatch '^\s*#' }) -join "`n"
Check ($codeOnly -match 'OfficeClientEdition') 'ODT config uses OfficeClientEdition'
Check ($codeOnly -match 'ExcludeApp') 'ODT config uses ExcludeApp'
Check ($codeOnly -notmatch '<Applications>') 'ODT config has no <Applications> block'
Check ($codeOnly -match 'PerpetualVL2024' -and $codeOnly -match 'PerpetualVL2021') 'Office 2024/2021 use PerpetualVL channels'
Check ($codeOnly -notmatch 'ProPlus2019' -and $codeOnly -notmatch 'ProPlus2016') 'No Office 2019/2016 products'
Check ($codeOnly -match 'officecdn\.microsoft\.com/pr/') 'ODT engine from Microsoft C2R CDN'
Check ($codeOnly -match 'massgravel/Microsoft-Activation-Scripts') 'MAS from authoritative massgravel repo'
Check ($codeOnly -match '/K-Uninstall' -and $codeOnly -match '/Ohook-Uninstall') 'MAS uninstall switches correct'
Check ($codeOnly -notmatch '/Z-Uninstall') 'No non-existent /Z-Uninstall switch'
Check ($codeOnly -match 'SoftwareLicensingProduct') 'Activation status via SoftwareLicensingProduct (localization-safe)'
Check ($codeOnly -notmatch 'slmgr\.vbs' -and $codeOnly -notmatch 'OSPP\.VBS') 'No localized slmgr/ospp regex'

# 6. i18n completeness for every English UI string in XAML WPFTab9 + logic Get-WinUtilText/Status.
$langPath = Join-Path $PSScriptRoot 'config\lang_zh-CN.json'
$lang = Get-Content -LiteralPath $langPath -Raw -Encoding UTF8 | ConvertFrom-Json
$langKeys = @{}
foreach ($p in $lang.PSObject.Properties) { $langKeys[$p.Name] = $true }
$wpfTab9 = $xaml.SelectSingleNode("//*[@Name='WPFTab9']")
$uiStrings = @()
foreach ($node in $wpfTab9.SelectNodes('.//*[@Text]')) { $uiStrings += $node.GetAttribute('Text') }
foreach ($node in $wpfTab9.SelectNodes('.//*[@Content]')) {
    $c = $node.GetAttribute('Content')
    if ($c -and $c -notmatch '^(Word|Excel|PowerPoint|Access|Publisher|Teams|Visio|Project)$') { $uiStrings += $c }
}
$uiStrings = $uiStrings | Where-Object { $_ } | Sort-Object -Unique
foreach ($s in $uiStrings) {
    Check ($langKeys.ContainsKey($s)) "i18n UI string: $s"
}
$codeStrings = [regex]::Matches($logic, "Get-WinUtil(?:Text|StatusText)\s*'([^']+)'") |
    ForEach-Object { $_.Groups[1].Value.Trim() } | Where-Object { $_ -and $_ -notmatch '\$' } | Sort-Object -Unique
# Also pull the explicit status literals passed to Step-WinUtilJob
$statusLiterals = [regex]::Matches($logic, "-Status\s+'([^']+)'") | ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique
$allCode = @($codeStrings) + @($statusLiterals) | Sort-Object -Unique
foreach ($s in $allCode) {
    if ($s.Length -gt 2) { Check ($langKeys.ContainsKey($s)) "i18n code string: $s" }
}

Write-Output "=== TOTAL FAILURES: $fail ==="
if ($fail -gt 0) { exit 1 }
