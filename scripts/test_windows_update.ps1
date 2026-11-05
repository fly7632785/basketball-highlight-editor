# Helper security tests run on PowerShell 7/macOS too. Full switch/restore tests
# require Windows PowerShell 5.1 and run against synthetic apps in a temp folder.
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$Repo = Split-Path -Parent $PSScriptRoot
$Helper = Join-Path $Repo 'apps/desktop/assets/windows_update.ps1'
$InventoryWriter = Join-Path $PSScriptRoot 'write_windows_release_inventory.ps1'
$tempBase = [IO.Path]::GetTempPath()
if ($env:OS -ne 'Windows_NT' -and (Test-Path -LiteralPath '/private/tmp')) {
    # macOS /var is a symlink; use its physical temp location for link guards.
    $tempBase = '/private/tmp'
}
$Temp = Join-Path $tempBase ('bhe-updater-test-' + [Guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($Temp)
$Utf8 = New-Object Text.UTF8Encoding($false)
$Session = $Temp
$LogDirectory = Join-Path $Temp 'persistent-logs'
$Tests = 0

function Assert([bool]$Condition, [string]$Message) {
    if (!$Condition) { throw $Message }
}
function Expect-Failure([scriptblock]$Action, [string]$Expected) {
    $caught = $false
    try { & $Action } catch {
        $caught = $true
        Assert ($_.Exception.Message -like "*$Expected*") "Unexpected error: $($_.Exception.Message)"
    }
    Assert $caught "Expected failure containing: $Expected"
    $script:Tests++
}
function New-Release([string]$Root, [string]$Version) {
    foreach ($name in @('BHE.exe', 'flutter_windows.dll', 'data/app.so', 'data/icudtl.dat', 'runtime/python/python.exe', 'version.txt')) {
        $path = Join-Path $Root $name
        [void][IO.Directory]::CreateDirectory((Split-Path -Parent $path))
        [IO.File]::WriteAllText($path, $Version, $Utf8)
    }
    [void][IO.Directory]::CreateDirectory((Join-Path $Root 'empty'))
    & $InventoryWriter -Root $Root -Version $Version
}
function New-Package([string]$Root, [string]$Destination) {
    [IO.Compression.ZipFile]::CreateFromDirectory($Root, $Destination)
    return @{
        archive = $Destination
        sha256 = (Get-FileHash -LiteralPath $Destination -Algorithm SHA256).Hash.ToLowerInvariant()
        size = (Get-Item -LiteralPath $Destination).Length
    }
}

try {
    # Import only parsed function definitions; never run the installation body.
    $tokens = $null
    $parseErrors = $null
    $ast = [Management.Automation.Language.Parser]::ParseFile($Helper, [ref]$tokens, [ref]$parseErrors)
    Assert ($parseErrors.Count -eq 0) 'Helper has PowerShell syntax errors'
    foreach ($definition in $ast.EndBlock.Statements) {
        if ($definition -is [Management.Automation.Language.FunctionDefinitionAst]) {
            . ([scriptblock]::Create($definition.Extent.Text))
        }
    }
    $script:Tests++
    $loggingSession = Join-Path $Temp 'logging-session'
    [void][IO.Directory]::CreateDirectory($loggingSession)
    $unicode = [string][char]0x4e2d + [string][char]0x6587
    Write-UpdateLog 'start' 'begin' ($unicode + "`nsecond line")
    $logPath = Join-Path $LogDirectory 'update.log'
    $bytes = [IO.File]::ReadAllBytes($logPath)
    Assert (!($bytes.Length -ge 3 -and $bytes[0] -eq 239 -and $bytes[1] -eq 187 -and $bytes[2] -eq 191)) 'Update log must be UTF-8 without BOM'
    $lines = [IO.File]::ReadAllLines($logPath, $Utf8)
    Assert ($lines.Length -eq 1) 'Multiline details must stay on one log line'
    Assert ($lines[0].Contains($unicode)) 'Unicode diagnostic detail was lost'
    Remove-Item -LiteralPath $loggingSession -Recurse -Force
    Assert (Test-Path -LiteralPath $logPath) 'Persistent log was removed with a session'
    $savedLogDirectory = $LogDirectory
    $LogDirectory = Join-Path $Temp 'blocked-log'
    [IO.File]::WriteAllText($LogDirectory, 'file', $Utf8)
    Write-UpdateLog 'test' 'unwritable'
    $LogDirectory = $savedLogDirectory
    Write-UpdateLog 'rollback' 'restored'
    Assert (([IO.File]::ReadAllText($logPath, $Utf8)).Contains('phase=rollback result=restored')) 'Logging did not recover after a write failure'
    $script:Tests += 4
    Add-Type -AssemblyName System.IO.Compression
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $fixture = Join-Path $Temp 'fixture'
    $root = Join-Path $fixture 'BHE'
    New-Release $root '2.0.0'
    Assert-ReleaseTree $root '2.0.0'
    $script:Tests++
    $personal = Join-Path $root 'my-project'
    [void][IO.Directory]::CreateDirectory($personal)
    [IO.File]::WriteAllText((Join-Path $personal 'project.sqlite'), 'precious data', $Utf8)
    # Files inside an unlisted folder are reported first; the update is blocked either way.
    Expect-Failure { Assert-ReleaseTree $root } 'Extra*my-project'
    Assert ((Get-Content -LiteralPath (Join-Path $personal 'project.sqlite') -Raw) -eq 'precious data') 'Personal data was changed'
    Remove-Item -LiteralPath $personal -Recurse -Force
    $extra = Join-Path $root 'personal.mp4'
    [IO.File]::WriteAllText($extra, 'video', $Utf8)
    Expect-Failure { Assert-ReleaseTree $root } 'Extra file'
    Remove-Item -LiteralPath $extra
    Expect-Failure { Assert-ReleaseTree $root '9.9.9' } 'does not match'
    $request = New-Package $fixture (Join-Path $Temp 'release.zip')
    Expand-VerifiedPackage $request.archive (Join-Path $Temp 'unpacked')
    Assert-ReleaseTree (Join-Path $Temp 'unpacked/BHE') '2.0.0'
    $script:Tests++
    $originalHash = $request.sha256
    $request.sha256 = '0' * 64
    Expect-Failure { Expand-VerifiedPackage $request.archive (Join-Path $Temp 'bad-hash') } 'SHA-256'
    Assert (!(Test-Path -LiteralPath (Join-Path $Temp 'bad-hash'))) 'Unverified archive was extracted'
    $request.sha256 = $originalHash
    $request.size++
    Expect-Failure { Expand-VerifiedPackage $request.archive (Join-Path $Temp 'bad-size') } 'size verification'
    foreach ($name in @('BHE/../escape', 'BHE/C:/escape', 'BHE/CON.txt', 'BHE/a. /escape', 'other/file', 'BHE/a\..\escape')) {
        $zipPath = Join-Path $Temp ([Guid]::NewGuid().ToString('N') + '.zip')
        $zip = [IO.Compression.ZipFile]::Open($zipPath, [IO.Compression.ZipArchiveMode]::Create)
        try { [void]$zip.CreateEntry($name) } finally { $zip.Dispose() }
        $request = @{
            sha256 = (Get-FileHash -LiteralPath $zipPath -Algorithm SHA256).Hash.ToLowerInvariant()
            size = (Get-Item -LiteralPath $zipPath).Length
        }
        Expect-Failure { Expand-VerifiedPackage $zipPath (Join-Path $Temp 'unsafe') } ''
    }
    $zipPath = Join-Path $Temp 'duplicate.zip'
    $zip = [IO.Compression.ZipFile]::Open($zipPath, [IO.Compression.ZipArchiveMode]::Create)
    try {
        [void]$zip.CreateEntry('BHE/a.txt')
        [void]$zip.CreateEntry('BHE/A.txt')
    } finally { $zip.Dispose() }
    $request = @{
        sha256 = (Get-FileHash -LiteralPath $zipPath -Algorithm SHA256).Hash.ToLowerInvariant()
        size = (Get-Item -LiteralPath $zipPath).Length
    }
    Expect-Failure { Expand-VerifiedPackage $zipPath (Join-Path $Temp 'duplicates') } 'Duplicate archive'
    foreach ($name in @('symlink', 'reparse')) {
        $zipPath = Join-Path $Temp ($name + '.zip')
        $zip = [IO.Compression.ZipFile]::Open($zipPath, [IO.Compression.ZipArchiveMode]::Create)
        try {
            $entry = $zip.CreateEntry('BHE/link')
            if ($name -eq 'symlink') { $entry.ExternalAttributes = -1577058304 }
            else { $entry.ExternalAttributes = 0x400 }
        } finally { $zip.Dispose() }
        $request = @{
            sha256 = (Get-FileHash -LiteralPath $zipPath -Algorithm SHA256).Hash.ToLowerInvariant()
            size = (Get-Item -LiteralPath $zipPath).Length
        }
        Expect-Failure { Expand-VerifiedPackage $zipPath (Join-Path $Temp $name) } 'Linked archive'
    }
    Write-SessionFile 'cancel' 'cancel'
    Expect-Failure { Assert-NotCancelled } 'cancelled'
    Remove-Item -LiteralPath (Join-Path $Temp 'cancel')

    # Three successful upgrades keep exactly the immediately previous release.
    $retentionRoot = Join-Path $Temp 'retention/BHE'
    New-Release $retentionRoot '1.0.0'
    for ($upgrade = 1; $upgrade -le 3; $upgrade++) {
        $backup = $retentionRoot + '.previous-' + [Guid]::NewGuid().ToString('N')
        Write-BackupReceipt $retentionRoot $backup
        [IO.Directory]::Move($retentionRoot, $backup)
        New-Release $retentionRoot ("$($upgrade + 1).0.0")
        Remove-OlderBackups $retentionRoot $backup
        $remaining = @(Get-ChildItem -LiteralPath (Split-Path -Parent $retentionRoot) -Directory |
            Where-Object { $_.Name -match '^BHE\.previous-[0-9a-f]{32}$' })
        Assert ($remaining.Count -eq 1) 'Older owned backups accumulated'
        Assert ($remaining[0].FullName -eq $backup) 'The newest rollback backup was deleted'
        Assert ((Get-Content -LiteralPath (Join-Path $backup 'version.txt') -Raw) -eq "$upgrade.0.0") 'Wrong rollback version retained'
        $script:Tests++
    }
    $foreignBackup = $retentionRoot + '.previous-' + [Guid]::NewGuid().ToString('N')
    New-Release $foreignBackup '0.0.1' # Matching name without a receipt is not owned.
    $mixedBackup = $retentionRoot + '.previous-' + [Guid]::NewGuid().ToString('N')
    New-Release $mixedBackup '0.0.2'
    Write-BackupReceipt $retentionRoot $mixedBackup
    [IO.File]::WriteAllText((Join-Path $mixedBackup 'personal.mp4'), 'preserve me', $Utf8)
    $wrongOwner = $retentionRoot + '.previous-' + [Guid]::NewGuid().ToString('N')
    New-Release $wrongOwner '0.0.3'
    Write-BackupReceipt (Join-Path $Temp 'other/BHE') $wrongOwner
    $nearMatch = $retentionRoot + '.previous-not-a-generated-id'
    New-Release $nearMatch '0.0.4'
    Remove-OlderBackups $retentionRoot $backup
    foreach ($preserved in @($foreignBackup, $mixedBackup, $wrongOwner, $nearMatch, $backup)) {
        Assert (Test-Path -LiteralPath $preserved) "An unowned, mixed or current backup was deleted: $preserved"
    }
    Assert ((Get-Content -LiteralPath (Join-Path $mixedBackup 'personal.mp4') -Raw) -eq 'preserve me') 'Cleanup deleted personal data'
    Assert ((Get-Content -LiteralPath (Join-Path $Session 'cleanup.log') -Raw) -like '*Backup cleanup warning*') 'Skipped backup cleanup was not logged'
    $script:Tests++

    if ($env:OS -eq 'Windows_NT') {
        # A small, harmless substitute for BHE. Never touches the real app.
        $fixtureExe = Join-Path $Temp 'fixture.exe'
        Add-Type -TypeDefinition 'public class BheUpdateFixture { public static void Main() { System.Threading.Thread.Sleep(120000); } }' `
            -OutputAssembly $fixtureExe -OutputType WindowsApplication
        Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;
public static class BheUpdateDirectoryLock {
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    public static extern SafeFileHandle CreateFile(string path, uint access,
        uint share, IntPtr security, uint creation, uint flags, IntPtr template);
}
'@
        foreach ($scenario in @('success', 'cancel', 'locked', 'launch-failure')) {
            # Include spaces, Unicode and PowerShell metacharacters in every path.
            $case = Join-Path $Temp ($scenario + ' ' + [char]0x4e2d + '[test]$')
            $installed = Join-Path $case 'BHE'
            New-Release $installed '1.0.0'
            Copy-Item -LiteralPath $fixtureExe -Destination (Join-Path $installed 'BHE.exe') -Force
            $packageRoot = Join-Path $case 'package'
            $newRelease = Join-Path $packageRoot 'BHE'
            New-Release $newRelease '2.0.0'
            if ($scenario -ne 'launch-failure') {
                Copy-Item -LiteralPath $fixtureExe -Destination (Join-Path $newRelease 'BHE.exe') -Force
            }
            $request = New-Package $packageRoot (Join-Path $case 'release.zip')
            $app = Start-Release $installed
            $request.installDirectory = $installed
            $request.appPid = $app.Id
            $request.version = '2.0.0'
            $sessionDirectory = Join-Path $case 'session'
            [void][IO.Directory]::CreateDirectory($sessionDirectory)
            $requestPath = Join-Path $sessionDirectory 'request.json'
            [IO.File]::WriteAllText($requestPath, ($request | ConvertTo-Json), $Utf8)
            # Start-Process in Windows PowerShell 5.1 interprets brackets in
            # WorkingDirectory as wildcards. Match the app's literal launcher.
            $helperInfo = New-Object Diagnostics.ProcessStartInfo
            $helperInfo.FileName = Join-Path $env:SystemRoot 'System32/WindowsPowerShell/v1.0/powershell.exe'
            $helperInfo.WorkingDirectory = $sessionDirectory
            $helperInfo.UseShellExecute = $false
            $helperInfo.Arguments = '-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "' + $Helper +
                '" -RequestPath "' + $requestPath + '" -NoErrorDialog -LogDirectory "' + (Join-Path $case 'persistent-logs') + '"'
            $helperProcess = [Diagnostics.Process]::Start($helperInfo)
            $heldFile = $null
            try {
                $deadline = [DateTime]::UtcNow.AddSeconds(30)
                while (!(Test-Path -LiteralPath (Join-Path $sessionDirectory 'ready'))) {
                    if ($helperProcess.HasExited) {
                        throw (Get-Content -LiteralPath (Join-Path $sessionDirectory 'error.txt') -Raw)
                    }
                    Assert ([DateTime]::UtcNow -lt $deadline) 'Helper readiness timed out'
                    Start-Sleep -Milliseconds 100
                }
                if ($scenario -eq 'cancel') {
                    [IO.File]::WriteAllText((Join-Path $sessionDirectory 'cancel'), 'cancel', $Utf8)
                } else {
                    if ($scenario -eq 'locked') {
                        # Explicitly deny directory deletion/rename; descendant
                        # file locks have different semantics across Windows versions.
                        # FILE_READ_ATTRIBUTES alone does not participate in
                        # Windows sharing checks. Request GENERIC_READ too.
                        $heldFile = [BheUpdateDirectoryLock]::CreateFile($installed, [uint32]2147483648, 3, [IntPtr]::Zero, 3, 0x02000000, [IntPtr]::Zero)
                        Assert (!$heldFile.IsInvalid) 'Could not create the synthetic directory lock'
                    }
                    [IO.File]::WriteAllText((Join-Path $sessionDirectory 'commit'), 'commit', $Utf8)
                    $deadline = [DateTime]::UtcNow.AddSeconds(10)
                    while (!(Test-Path -LiteralPath (Join-Path $sessionDirectory 'accepted'))) {
                        Assert (!$helperProcess.HasExited) 'Helper exited before accepting the update'
                        Assert ([DateTime]::UtcNow -lt $deadline) 'Helper acceptance timed out'
                        Start-Sleep -Milliseconds 100
                    }
                    Stop-Process -Id $app.Id -Force
                }
                Assert ($helperProcess.WaitForExit(30000)) 'Helper did not finish'
                if ($null -ne $heldFile) { $heldFile.Dispose(); $heldFile = $null }
                $actual = Get-Content -LiteralPath (Join-Path $installed 'version.txt') -Raw
                Assert ($actual -eq $(if ($scenario -eq 'success') { '2.0.0' } else { '1.0.0' })) "Wrong installed version: $scenario"
                Assert (($helperProcess.ExitCode -eq 0) -eq ($scenario -eq 'success')) "Unexpected helper exit: $scenario"
                if ($scenario -eq 'success') {
                    $backups = @(Get-ChildItem -LiteralPath $case -Directory | Where-Object { $_.Name -like 'BHE.previous-*' })
                    Assert ($backups.Count -eq 1) 'Previous release was not retained'
                }
                $script:Tests++
            } finally {
                if ($null -ne $heldFile) { $heldFile.Dispose() }
                # Stop only the synthetic executables launched for this case.
                Get-Process | Where-Object { $_.Path -and $_.Path.StartsWith($case, [StringComparison]::OrdinalIgnoreCase) } |
                    Stop-Process -Force -ErrorAction SilentlyContinue
                if (!$helperProcess.HasExited) { Stop-Process -Id $helperProcess.Id -Force }
            }
        }
    } else {
        Write-Host 'Windows process replacement tests skipped on this host.'
    }
    Write-Host "Passed $Tests updater checks."
} finally {
    Remove-Item -LiteralPath $Temp -Recurse -Force -ErrorAction SilentlyContinue
}
