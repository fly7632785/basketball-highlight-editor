# Runtime Python bytecode caches (__pycache__) must never block an update:
# extra caches are cleaned, missing inventory cache entries are tolerated,
# and every other extra file still fails the update as before.
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$Repo = Split-Path -Parent $PSScriptRoot
$Helper = Join-Path $Repo 'apps/desktop/assets/windows_update.ps1'
$Temp = Join-Path ([IO.Path]::GetTempPath()) ('bhe-pycache-test-' + [Guid]::NewGuid().ToString('N'))
$Root = Join-Path $Temp 'BHE'
$Utf8 = New-Object Text.UTF8Encoding($false)
$LogDirectory = Join-Path $Temp 'logs'
[void][IO.Directory]::CreateDirectory($Root)
try {
    foreach ($name in @('BHE.exe', 'flutter_windows.dll', 'data/app.so', 'data/icudtl.dat', 'runtime/python/python.exe')) {
        $path = Join-Path $Root $name
        [void][IO.Directory]::CreateDirectory((Split-Path -Parent $path))
        [IO.File]::WriteAllText($path, '', $Utf8)
    }
    # A shipped engine bytecode cache: present in the inventory on purpose.
    $shipped = Join-Path $Root 'runtime/engine/python/basketball_engine/__pycache__/engine.cpython-311.pyc'
    [void][IO.Directory]::CreateDirectory((Split-Path -Parent $shipped))
    [IO.File]::WriteAllText($shipped, 'shipped', $Utf8)
    & "$PSScriptRoot/write_windows_release_inventory.ps1" -Root $Root -Version '2.0.0'

    # Machine-generated caches written after installation.
    $generated = @(
        'runtime/python/Lib/encodings/__pycache__/gbk.cpython-311.pyc',
        'runtime/python/Lib/site-packages/pkg/__pycache__/mod.cpython-311.pyc',
        'runtime/engine/python/basketball_engine/__pycache__/extra.cpython-311.pyc'
    )
    foreach ($relative in $generated) {
        $path = Join-Path $Root $relative
        [void][IO.Directory]::CreateDirectory((Split-Path -Parent $path))
        [IO.File]::WriteAllText($path, 'generated', $Utf8)
    }
    # Ordinary extras must keep failing the update.
    [IO.File]::WriteAllText((Join-Path $Root 'notes.txt'), 'personal', $Utf8)
    [void][IO.Directory]::CreateDirectory((Join-Path $Root 'my_data'))

    $tokens = $null
    $parseErrors = $null
    $ast = [Management.Automation.Language.Parser]::ParseFile($Helper, [ref]$tokens, [ref]$parseErrors)
    if ($parseErrors.Count) { throw 'Helper has syntax errors.' }
    foreach ($definition in $ast.EndBlock.Statements) {
        if ($definition -is [Management.Automation.Language.FunctionDefinitionAst]) {
            . ([scriptblock]::Create($definition.Extent.Text))
        }
    }

    $blocked = $null
    try {
        Assert-ReleaseTree $Root '2.0.0'
    } catch {
        $blocked = $_.Exception.Message
    }
    if ($null -eq $blocked -or $blocked -notmatch 'notes\.txt|my_data') {
        throw "Non-cache extra must still block the update, got: $blocked"
    }

    Remove-Item -LiteralPath (Join-Path $Root 'notes.txt') -Force
    Remove-Item -LiteralPath (Join-Path $Root 'my_data') -Recurse -Force

    # A non-bytecode file inside a cache directory is personal data, not cache.
    $personalCacheFile = Join-Path $Root 'runtime/python/Lib/site-packages/pkg/__pycache__/notes.txt'
    [IO.File]::WriteAllText($personalCacheFile, 'keep me', $Utf8)
    $blocked = $null
    try {
        Assert-ReleaseTree $Root '2.0.0'
    } catch {
        $blocked = $_.Exception.Message
    }
    if ($null -eq $blocked -or $blocked -notmatch 'Extra file found') {
        throw "A non-.pyc cache file must block the update, got: $blocked"
    }
    if (!(Test-Path -LiteralPath $personalCacheFile) -or
        [IO.File]::ReadAllText($personalCacheFile, $Utf8) -ne 'keep me') {
        throw 'A personal file inside __pycache__ was changed.'
    }
    Remove-Item -LiteralPath $personalCacheFile -Force

    # An unrelated empty directory beside a cache has no cache ownership.
    $extraEmpty = Join-Path $Root 'runtime/python/Lib/encodings/extra-empty'
    [void][IO.Directory]::CreateDirectory($extraEmpty)
    $blocked = $null
    try {
        Assert-ReleaseTree $Root '2.0.0'
    } catch {
        $blocked = $_.Exception.Message
    }
    if ($null -eq $blocked -or $blocked -notmatch 'Extra folder found') {
        throw "An unrelated empty folder must block the update, got: $blocked"
    }
    if (!(Test-Path -LiteralPath $extraEmpty) -or !(Test-Path -LiteralPath (Join-Path $Root $generated[0]))) {
        throw 'A blocked preflight changed the empty folder or cache files.'
    }
    Remove-Item -LiteralPath $extraEmpty -Force

    # The following tests isolate both cleanup paths so each .pyc reaches
    # Assert-NoReparseAncestors as FileInfo under StrictMode.
    foreach ($relative in $generated) {
        Remove-Item -LiteralPath (Join-Path $Root $relative) -Force
    }
    Remove-Item -LiteralPath (Join-Path $Root 'runtime/python/Lib/encodings') -Recurse -Force
    Remove-Item -LiteralPath (Join-Path $Root 'runtime/python/Lib/site-packages/pkg') -Recurse -Force

    # A .pyc in a newly created, unlisted cache directory must be cleaned.
    $newCacheFile = Join-Path $Root 'runtime/python/Lib/site-packages/new_pkg/__pycache__/generated.cpython-311.pyc'
    [void][IO.Directory]::CreateDirectory((Split-Path -Parent $newCacheFile))
    [IO.File]::WriteAllText($newCacheFile, 'generated', $Utf8)
    Assert-ReleaseTree $Root '2.0.0'
    if (Test-Path -LiteralPath $newCacheFile) {
        throw 'A .pyc in a new cache directory was not cleaned.'
    }

    # A new .pyc beside an inventoried cache file must be cleaned without
    # removing the shipped file or the listed cache directory.
    $listedCacheFile = Join-Path (Split-Path -Parent $shipped) 'extra.cpython-311.pyc'
    [IO.File]::WriteAllText($listedCacheFile, 'generated', $Utf8)
    Assert-ReleaseTree $Root '2.0.0'
    if ((Test-Path -LiteralPath $listedCacheFile) -or !(Test-Path -LiteralPath $shipped)) {
        throw 'A .pyc in an inventoried cache directory was not safely cleaned.'
    }

    # Missing inventory cache entries are tolerated in both directions.
    Remove-Item -LiteralPath $shipped -Force
    Assert-ReleaseTree $Root '2.0.0'
    Remove-Item -LiteralPath (Join-Path $Root 'runtime/engine/python/basketball_engine/__pycache__') -Recurse -Force
    Assert-ReleaseTree $Root '2.0.0'

    # Junction creation is Windows-specific; run this guard in Windows CI.
    if ($env:OS -eq 'Windows_NT') {
        $linkRoot = Join-Path $Root 'runtime/python/Lib/encodings/__pycache__'
        [void][IO.Directory]::CreateDirectory($linkRoot)
        $cmd = New-Object Diagnostics.ProcessStartInfo
        $cmd.FileName = 'cmd.exe'
        $cmd.Arguments = '/c mklink /J "' + (Join-Path $linkRoot 'escape') + '" "' + (Join-Path $Temp 'outside') + '"'
        $cmd.UseShellExecute = $false
        $cmd.CreateNoWindow = $true
        $proc = [Diagnostics.Process]::Start($cmd)
        $proc.WaitForExit()
        $linkThrew = $false
        try {
            Assert-ReleaseTree $Root '2.0.0'
        } catch {
            $linkThrew = $_.Exception.Message -match 'Linked file or folder'
        }
        if (!$linkThrew) { throw 'A link hidden inside a cache folder must block the update.' }
    } else {
        Write-Host 'LINK_REPARSE_TEST=skipped_non_windows'
    }

    Write-Host 'PYCACHE_TOLERANCE_RESULT=ok'
    if ($env:GITHUB_STEP_SUMMARY) {
        Add-Content -LiteralPath $env:GITHUB_STEP_SUMMARY -Value 'windows update pycache tolerance: ok' -Encoding UTF8
    }
} finally {
    Remove-Item -LiteralPath $Temp -Recurse -Force -ErrorAction SilentlyContinue
}
