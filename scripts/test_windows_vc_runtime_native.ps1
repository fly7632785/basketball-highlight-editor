param(
    [Parameter(Mandatory)][string]$CompilerPath,
    [Parameter(Mandatory)][string]$FixtureExe
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'install_windows_vc_runtime.ps1')

$expectedVersion = [version]'14.52.37029.0'
$required = @('vcruntime140.dll', 'msvcp140.dll')
$temp = Join-Path ([IO.Path]::GetTempPath()) ('bhe-vc-native-' + [guid]::NewGuid())
$workspace = Join-Path $temp 'redist'
$app = Join-Path $temp 'BHE'
$python = Join-Path $app 'runtime/python'
$appExe = Join-Path $app 'BHE.exe'
try {
    [void](New-Item -ItemType Directory -Force -Path $workspace, $python)
    Copy-Item -LiteralPath $FixtureExe -Destination (Join-Path $python 'python.exe')
    Write-Host "MSVC compiler: $CompilerPath; PE fixture: $FixtureExe"
    $redist = Get-PinnedWindowsVcRuntime $workspace
    try {
        # Keep the fixture's real imports; change only its PE linker minor version.
        $requiredVersion = [version]::new($expectedVersion.Major, $expectedVersion.Minor + 1, 0, 0)
        $newerPe = [IO.File]::ReadAllBytes($FixtureExe)
        $peOffset = [BitConverter]::ToInt32($newerPe, 0x3c)
        $newerPe[$peOffset + 27] = $requiredVersion.Minor
        [IO.File]::WriteAllBytes($appExe, $newerPe)

        $rejected = $false
        try {
            Copy-WindowsVcRuntime -CompilerPath $CompilerPath -AppDir $app -PythonDir $python -RedistFiles $redist
        } catch {
            if ($_.Exception.Message -notlike "*older than required (* < $requiredVersion from the linker version of *BHE.exe)*") { throw }
            $rejected = $true
            Write-Host $_.Exception.Message
        }
        if (-not $rejected) { throw 'Packaging accepted a runtime older than the PE linker version.' }
        foreach ($dir in @($app, $python)) {
            foreach ($name in $required) {
                if (Test-Path -LiteralPath (Join-Path $dir $name)) { throw "Rejected runtime was copied to $dir." }
            }
        }

        Copy-Item -LiteralPath $FixtureExe -Destination $appExe -Force
        Copy-WindowsVcRuntime -CompilerPath $CompilerPath -AppDir $app -PythonDir $python -RedistFiles $redist
        foreach ($name in $required) {
            $sourceHash = (Get-FileHash -LiteralPath $redist[$name] -Algorithm SHA256).Hash
            foreach ($dir in @($app, $python)) {
                $path = Join-Path $dir $name
                if ((Get-VcRuntimeFileVersion $path) -ne $expectedVersion -or
                    (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash -ne $sourceHash) {
                    throw "Expected $name $expectedVersion from the pinned CAB at $path."
                }
            }
        }
        Write-Host "Native Windows packaging verified both runtime locations at $expectedVersion."
    } catch {
        Write-Host 'Microsoft redistributable layout tree:'
        Get-ChildItem -LiteralPath (Join-Path $workspace 'layout') -Recurse -Force |
            ForEach-Object { Write-Host $_.FullName }
        throw
    }
} finally {
    if (Test-Path -LiteralPath $temp) { Remove-Item -LiteralPath $temp -Recurse -Force }
}
