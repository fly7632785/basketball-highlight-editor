# Windows PowerShell 5.1. Runs from the update cache, never from the app folder.
param(
    [Parameter(Mandatory = $true)][string]$RequestPath,
    [switch]$NoErrorDialog,
    [string]$LogDirectory = ''
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$Session = Split-Path -Parent ([IO.Path]::GetFullPath($RequestPath))
$Stage = $null
$Backup = $null
$Install = $null
$MovedOld = $false
$InstalledNew = $false
$Committed = $false
$Lock = $null
$NewProcess = $null
$BackupReceipt = $null
$Utf8 = New-Object System.Text.UTF8Encoding($false)
$UpdateResult = 'failed'

function Write-UpdateLog([string]$Phase, [string]$Result, [string]$Message = '') {
    try {
        $directory = $LogDirectory
        if (!$directory) {
            $base = $env:LOCALAPPDATA
            if (!$base) { $base = $env:HOME }
            if (!$base) { $base = $env:USERPROFILE }
            if (!$base) { $base = [IO.Path]::GetTempPath() }
            $directory = Join-Path (Join-Path $base 'BHE') 'logs'
        }
        [void][IO.Directory]::CreateDirectory($directory)
        $line = '[' + [DateTime]::UtcNow.ToString('o') + '] update phase=' + $Phase + ' result=' + $Result
        if ($Message) { $line += ' detail=' + ($Message | ConvertTo-Json -Compress) }
        [IO.File]::AppendAllText((Join-Path $directory 'update.log'), "$line`r`n", $Utf8)
    } catch { }
}

function Write-SessionFile([string]$Name, [string]$Value) {
    [IO.File]::WriteAllText((Join-Path $Session $Name), $Value, $Utf8)
}

function Write-Phase([string]$Phase) {
    Write-UpdateLog $Phase 'entered'
    $state = @{ phase = $Phase; install = $Install; backup = $Backup; stage = $Stage }
    try { Write-SessionFile 'status.json' ($state | ConvertTo-Json -Compress) }
    catch {
        # Persist recovery paths before mutation. After mutation, logging must
        # never prevent restoration or reopening the application.
        if ($Phase -in @('preparing', 'ready', 'replacing')) { throw }
    }
}

function Start-Release([string]$Root) {
    # ProcessStartInfo treats paths literally (including brackets and Unicode).
    $info = New-Object Diagnostics.ProcessStartInfo
    $info.FileName = Join-Path $Root 'BHE.exe'
    $info.WorkingDirectory = $Root
    $info.UseShellExecute = $false
    return [Diagnostics.Process]::Start($info)
}

function Write-CleanupLog([string]$Message) {
    try {
        [IO.File]::AppendAllText((Join-Path $Session 'cleanup.log'), "$Message`r`n", $Utf8)
    } catch { }
    Write-UpdateLog 'cleanup' 'info' $Message
}

function Write-BackupReceipt([string]$Root, [string]$BackupPath) {
    $receipt = @{ schema = 1; install = $Root; backup = $BackupPath } | ConvertTo-Json -Compress
    $stream = [IO.File]::Open(($BackupPath + '.bhe-update.json'), [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
    try {
        $bytes = $Utf8.GetBytes($receipt)
        $stream.Write($bytes, 0, $bytes.Length)
    } finally { $stream.Dispose() }
}

function Remove-OlderBackups([string]$Root, [string]$KeepBackup) {
    try {
        $parent = Split-Path -Parent $Root
        $pattern = '^' + [Regex]::Escape((Split-Path -Leaf $Root)) + '\.previous-[0-9a-f]{32}$'
        foreach ($candidate in (Get-ChildItem -LiteralPath $parent -Directory -Force)) {
            if ($candidate.Name -notmatch $pattern -or
                $candidate.FullName.Equals($KeepBackup, [StringComparison]::OrdinalIgnoreCase)) { continue }
            $receiptPath = $candidate.FullName + '.bhe-update.json'
            try {
                # A matching name alone does not establish updater ownership.
                if (!(Test-Path -LiteralPath $receiptPath -PathType Leaf)) { continue }
                $receiptFile = Get-Item -LiteralPath $receiptPath -Force
                if ($receiptFile.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Linked ownership receipt.' }
                $receipt = Get-Content -LiteralPath $receiptPath -Raw -Encoding UTF8 | ConvertFrom-Json
                if ($receipt.schema -ne 1 -or $receipt.install -isnot [string] -or $receipt.backup -isnot [string] -or
                    !$receipt.install.Equals($Root, [StringComparison]::OrdinalIgnoreCase) -or
                    !$receipt.backup.Equals($candidate.FullName, [StringComparison]::OrdinalIgnoreCase)) {
                    throw 'Backup ownership does not match this installation.'
                }
                Assert-NoReparseAncestors $candidate.FullName
                Assert-NoOtherInstance $candidate.FullName
                # Preserve backups that a user has since put personal files in.
                Assert-ReleaseTree $candidate.FullName
                Remove-Item -LiteralPath $candidate.FullName -Recurse -Force -ErrorAction Stop
                Remove-Item -LiteralPath $receiptPath -Force -ErrorAction Stop
                Write-CleanupLog "Removed older backup: $($candidate.FullName)"
            } catch {
                Write-CleanupLog "Backup cleanup warning for $($candidate.FullName): $($_.Exception.Message)"
            }
        }
    } catch { Write-CleanupLog "Backup cleanup skipped: $($_.Exception.Message)" }
}

function Assert-NotCancelled {
    if (Test-Path -LiteralPath (Join-Path $Session 'cancel')) {
        throw 'Update cancelled. The installed application has not been replaced.'
    }
}

function Assert-SafeRelativePath([string]$Path) {
    if ([string]::IsNullOrEmpty($Path) -or [IO.Path]::IsPathRooted($Path)) {
        throw "Invalid package path: $Path"
    }
    foreach ($part in ($Path -split '/')) {
        if (!$part -or $part -eq '.' -or $part -eq '..' -or
            $part -match '[\\:<>"|?*\x00-\x1f]' -or $part -match '[. ]$' -or
            $part -match '^(?i:CON|PRN|AUX|NUL|COM[0-9]|LPT[0-9])(?:\.|$)') {
            throw "Unsafe package path: $Path"
        }
    }
}

function Assert-NoReparseAncestors([string]$Path) {
    $item = Get-Item -LiteralPath $Path -Force
    while ($null -ne $item) {
        if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) {
            throw 'Automatic updates do not support linked installation directories.'
        }
        $item = $item.Parent
    }
}

function Assert-NoOtherInstance([string]$Root, [int]$ExceptPid = 0) {
    $executable = Join-Path $Root 'BHE.exe'
    foreach ($process in [Diagnostics.Process]::GetProcessesByName('BHE')) {
        try {
            if ($process.Id -eq $ExceptPid -or $process.HasExited) { continue }
            $path = $process.MainModule.FileName
            if ($path.Equals($executable, [StringComparison]::OrdinalIgnoreCase)) {
                throw 'Another BHE instance is using this installation. Close it before updating.'
            }
        } finally { $process.Dispose() }
    }
}

function Assert-ReleaseTree([string]$Root, [string]$Version = '') {
    $inventoryPath = Join-Path $Root 'bhe-release.json'
    if (!(Test-Path -LiteralPath $inventoryPath -PathType Leaf)) {
        throw 'Release inventory missing. Please install this version manually first.'
    }
    $inventory = Get-Content -LiteralPath $inventoryPath -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($inventory.schema -ne 1 -or ($Version -and $inventory.version -ne $Version)) {
        throw 'The release inventory does not match the requested version.'
    }
    $files = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    [void]$files.Add('bhe-release.json')
    foreach ($path in $inventory.files) {
        Assert-SafeRelativePath $path
        if (!$files.Add($path)) { throw "Duplicate release file: $path" }
    }
    $directories = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    foreach ($path in $inventory.directories) {
        Assert-SafeRelativePath $path
        if (!$directories.Add($path)) { throw "Duplicate release directory: $path" }
    }
    foreach ($required in @('BHE.exe', 'flutter_windows.dll', 'data/app.so', 'data/icudtl.dat', 'runtime/python/python.exe')) {
        if (!$files.Contains($required)) { throw "Invalid release: $required is missing." }
    }
    $pending = New-Object 'System.Collections.Generic.Stack[string]'
    $pending.Push($Root)
    # Python regenerates __pycache__ bytecode caches inside the bundled
    # runtime whenever any interpreter runs without PYTHONDONTWRITEBYTECODE
    # (manual debugging, pip installs). Machine-derived cache content is
    # cleaned instead of failing the update; every other extra file or
    # folder still blocks the update as foreign content.
    $cacheFiles = New-Object 'System.Collections.Generic.List[string]'
    $extraFolders = New-Object 'System.Collections.Generic.List[string]'
    $foreignFolders = New-Object 'System.Collections.Generic.List[string]'
    $foreignFiles = New-Object 'System.Collections.Generic.List[string]'
    while ($pending.Count -gt 0) {
        $directory = $pending.Pop()
        # One literal .NET enumeration per directory avoids tens of thousands
        # of Test-Path calls on packaged Python/Torch installations.
        $info = New-Object IO.DirectoryInfo($directory)
        $parentRelative = ''
        if (!$directory.Equals($Root, [StringComparison]::OrdinalIgnoreCase)) {
            $parentRelative = $directory.Substring($Root.Length + 1).Replace('\', '/')
        }
        $insideCache = $parentRelative -match '(^|/)__pycache__$'
        $insideCacheSubtree = $parentRelative -match '(^|/)__pycache__(/|$)'
        foreach ($item in $info.EnumerateFileSystemInfos()) {
            $relative = $item.FullName.Substring($Root.Length + 1).Replace('\', '/')
            if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) {
                throw "Linked file or folder found: $relative. Please update manually."
            }
            if ($item.Attributes -band [IO.FileAttributes]::Directory) {
                $inventoried = $directories.Remove($relative)
                if ($insideCacheSubtree) {
                    # A cache may contain bytecode files only; nested folders
                    # are never treated as cache content, even when inventoried.
                    $foreignFolders.Add($relative)
                    continue
                }
                $pending.Push($item.FullName)
                if (!$inventoried) { $extraFolders.Add($relative) }
            } elseif ($insideCacheSubtree) {
                if ($insideCache -and $item.Name -match '\.pyc$') {
                    if (!$files.Remove($relative)) { $cacheFiles.Add($relative) }
                } else {
                    # This also rejects non-bytecode files listed in a release
                    # inventory: __pycache__ is reserved for .pyc files.
                    $foreignFiles.Add($relative)
                }
            } elseif (!$files.Remove($relative)) {
                $foreignFiles.Add($relative)
            }
        }
    }
    if ($foreignFiles.Count -gt 0) {
        throw "Extra file found: $($foreignFiles[0]). Move personal files outside BHE before updating."
    }
    if ($foreignFolders.Count -gt 0) {
        throw "Extra folder found: $($foreignFolders[0]). Move personal files outside BHE before updating."
    }
    # An unlisted folder is tolerated only when it is an ancestor of a
    # generated .pyc that will be removed. Unrelated empty folders still block.
    $cacheAncestors = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    foreach ($relative in $cacheFiles) {
        $ancestor = $relative
        while ($ancestor -match '/') {
            $ancestor = $ancestor -replace '/[^/]+$', ''
            if ($extraFolders.Contains($ancestor)) { [void]$cacheAncestors.Add($ancestor) }
        }
    }
    foreach ($folder in $extraFolders) {
        if (!$cacheAncestors.Contains($folder)) {
            throw "Extra folder found: $folder. Move personal files outside BHE before updating."
        }
    }
    if ($cacheFiles.Count -gt 0 -or $extraFolders.Count -gt 0) {
        foreach ($relative in $cacheFiles) {
            $path = Join-Path $Root $relative
            # Recheck the file and every ancestor immediately before deletion.
            Assert-NoReparseAncestors $path
            Remove-Item -LiteralPath $path -Force -ErrorAction Stop
        }
        # Prune only directories made empty by bytecode deletion. Never recurse
        # into an unknown directory or infer deletion authority from its name.
        foreach ($relative in ($extraFolders | Sort-Object { $_.Length } -Descending)) {
            $path = Join-Path $Root $relative
            if (!(Test-Path -LiteralPath $path -PathType Container)) { continue }
            Assert-NoReparseAncestors $path
            if ([IO.Directory]::GetFileSystemEntries($path).Count -gt 0) {
                throw "Extra folder found: $relative. Move personal files outside BHE before updating."
            }
            Remove-Item -LiteralPath $path -Force -ErrorAction Stop
        }
        Write-UpdateLog 'preflight' 'cleaned' "Removed $($cacheFiles.Count) cache files and pruned $($extraFolders.Count) empty cache-only folders."
    }
    # Inventory drift is tolerated only for individual bytecode files and
    # empty cache directories; unrelated files and folders remain protected.
    foreach ($missing in $files) {
        if ($missing -match '(^|/)__pycache__/[^/]+\.pyc$') { continue }
        throw "Release file missing: $missing"
    }
    foreach ($missing in $directories) {
        if ($missing -match '(^|/)__pycache__$') { continue }
        throw "Release directory missing: $missing"
    }
}

function Expand-VerifiedPackage([string]$Archive, [string]$Destination) {
    Write-UpdateLog 'verify' 'begin'
    # .NET Framework does not load ZipArchive/ZipArchiveMode just because
    # System.IO.Compression.FileSystem was loaded in this fresh process.
    Add-Type -AssemblyName System.IO.Compression
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    # Keep the archive open without write sharing from hashing through extraction.
    $stream = [IO.File]::Open($Archive, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
    try {
        if ($stream.Length -ne $request.size) { throw 'Package size verification failed.' }
        $sha = [Security.Cryptography.SHA256]::Create()
        try { $actual = [BitConverter]::ToString($sha.ComputeHash($stream)).Replace('-', '').ToLowerInvariant() }
        finally { $sha.Dispose() }
        if ($actual -ne $request.sha256) { throw 'Package SHA-256 verification failed. Download it again.' }
        Write-UpdateLog 'verify' 'ok'
        $stream.Position = 0
        $zip = New-Object IO.Compression.ZipArchive($stream, [IO.Compression.ZipArchiveMode]::Read, $true)
        try {
            $seen = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
            foreach ($entry in $zip.Entries) {
                Assert-NotCancelled
                $name = $entry.FullName.Replace('\', '/')
                $relative = $name.TrimEnd('/')
                Assert-SafeRelativePath $relative
                if ($relative -ne 'BHE' -and !$relative.StartsWith('BHE/', [StringComparison]::Ordinal)) {
                    throw 'The archive must contain a single top-level BHE folder.'
                }
                if (!$seen.Add($relative)) { throw "Duplicate archive entry: $name" }
                $unixType = ($entry.ExternalAttributes -shr 16) -band 0xf000
                if ($unixType -eq 0xa000 -or ($entry.ExternalAttributes -band 0x400)) {
                    throw 'Linked archive entries are not supported.'
                }
                $target = Join-Path $Destination $relative
                if ($name.EndsWith('/')) {
                    [void][IO.Directory]::CreateDirectory($target)
                } else {
                    [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($target))
                    [IO.Compression.ZipFileExtensions]::ExtractToFile($entry, $target, $false)
                }
            }
        } finally { $zip.Dispose() }
    } finally { $stream.Dispose() }
}

Write-UpdateLog 'start' 'begin'
try {
    Write-SessionFile 'started' 'started'
    $request = Get-Content -LiteralPath $RequestPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $Install = [IO.Path]::GetFullPath($request.installDirectory).TrimEnd('\', '/')
    if (![IO.Path]::IsPathRooted($Install) -or !(Test-Path -LiteralPath (Join-Path $Install 'BHE.exe'))) {
        throw 'The installation directory is invalid.'
    }
    Assert-NoReparseAncestors $Install
    $parent = Split-Path -Parent $Install
    if ($Session.Equals($Install, [StringComparison]::OrdinalIgnoreCase) -or
        $Session.StartsWith($Install + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) {
        throw 'The updater must run outside the installation directory.'
    }
    # An exclusive sibling lock serializes updates of this installation.
    $lockPath = Join-Path $parent ((Split-Path -Leaf $Install) + '.update.lock')
    $Lock = [IO.File]::Open($lockPath, [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
    $id = [Guid]::NewGuid().ToString('N')
    $Stage = Join-Path $parent ('.bhe-update-' + $id)
    $Backup = Join-Path $parent ((Split-Path -Leaf $Install) + '.previous-' + $id)
    Write-Phase 'preparing'
    Assert-ReleaseTree $Install
    [void][IO.Directory]::CreateDirectory($Stage)
    Expand-VerifiedPackage $request.archive $Stage
    $newRoot = Join-Path $Stage 'BHE'
    Assert-ReleaseTree $newRoot $request.version
    # Capture this process object now, avoiding a later reused PID.
    $app = Get-Process -Id $request.appPid -ErrorAction Stop
    if (![IO.Path]::GetFullPath($app.Path).Equals((Join-Path $Install 'BHE.exe'), [StringComparison]::OrdinalIgnoreCase)) {
        throw 'The running application does not match the installation directory.'
    }
    Assert-NoOtherInstance $Install $request.appPid
    Assert-NotCancelled
    Write-Phase 'ready'
    Write-SessionFile 'ready' 'ready'
    $deadline = [DateTime]::UtcNow.AddMinutes(3)
    while (!(Test-Path -LiteralPath (Join-Path $Session 'commit'))) {
        Assert-NotCancelled
        if ($app.HasExited -or [DateTime]::UtcNow -gt $deadline) { throw 'Update was not confirmed. Nothing has been replaced.' }
        Start-Sleep -Milliseconds 200
    }
    Assert-NotCancelled
    Write-SessionFile 'accepted' 'accepted'
    $deadline = [DateTime]::UtcNow.AddSeconds(60)
    while (!$app.HasExited) {
        Assert-NotCancelled
        if ([DateTime]::UtcNow -gt $deadline) { throw 'BHE did not exit. Nothing has been replaced.' }
        Start-Sleep -Milliseconds 200
    }
    $Committed = $true
    Assert-NotCancelled
    # Recheck after shutdown: imports/other instances may have created files.
    Assert-NoOtherInstance $Install
    Assert-ReleaseTree $Install
    Write-Phase 'replacing'
    Write-BackupReceipt $Install $Backup
    $BackupReceipt = $Backup + '.bhe-update.json'
    Write-UpdateLog 'backup' 'begin'
    [IO.Directory]::Move($Install, $Backup)
    $MovedOld = $true
    Write-UpdateLog 'backup' 'ok'
    Write-UpdateLog 'replace' 'begin'
    [IO.Directory]::Move($newRoot, $Install)
    $InstalledNew = $true
    Write-UpdateLog 'replace' 'ok'
    Write-Phase 'starting'
    $NewProcess = Start-Release $Install
    Start-Sleep -Seconds 3
    if ($NewProcess.HasExited) { throw 'The updated BHE exited immediately after launch.' }
    # Keep this update's rollback copy, prune only owned, older releases.
    # A live process is not a full health check.
    Write-Phase 'installed'
    Remove-OlderBackups $Install $Backup
    $UpdateResult = 'ok'
} catch {
    $message = $_.Exception.Message
    if ($MovedOld -and ($null -eq $NewProcess -or $NewProcess.HasExited)) {
        Write-UpdateLog 'rollback' 'begin'
        try {
            if ($InstalledNew) {
                $failed = Join-Path $parent ('.bhe-failed-' + $id)
                [IO.Directory]::Move($Install, $failed)
            }
            [IO.Directory]::Move($Backup, $Install)
            Write-Phase 'restored'
            Write-UpdateLog 'rollback' 'restored'
            Start-Release $Install | Out-Null
        } catch {
            $message += "`r`nAutomatic restore failed: $($_.Exception.Message)`r`nPrevious release: $Backup"
            Write-Phase 'restore-required'
            Write-UpdateLog 'rollback' 'failed' $message
        }
    } elseif ($MovedOld) {
        $message += "`r`nThe new BHE is running. Previous release retained at: $Backup"
    } elseif ($Committed) {
        # A lock/permission error may prevent even the first rename.
        try {
            Start-Release $Install | Out-Null
        } catch {
            $message += "`r`nCould not reopen the previous release: $($_.Exception.Message)"
        }
    }
    Write-UpdateLog 'error' 'failed' $message
    try { Write-SessionFile 'error.txt' $message } catch { }
    if ($Committed -and !$NoErrorDialog) {
        # The old UI has closed; show a visible failure and the recovery paths.
        try {
            Add-Type -AssemblyName System.Windows.Forms
            [void][Windows.Forms.MessageBox]::Show("$message`r`n`r`nUpdate log: $Session", 'BHE update failed')
        } catch { }
    }
    exit 1
} finally {
    Write-UpdateLog 'end' $UpdateResult
    if ($null -ne $Lock) { $Lock.Dispose() }
    if ($BackupReceipt -and !(Test-Path -LiteralPath $Backup)) {
        Remove-Item -LiteralPath $BackupReceipt -Force -ErrorAction SilentlyContinue
    }
    # Only delete the uniquely created staging folder; retain this update's backup.
    if ($Stage -and (Test-Path -LiteralPath $Stage)) {
        Remove-Item -LiteralPath $Stage -Recurse -Force -ErrorAction SilentlyContinue
    }
}
