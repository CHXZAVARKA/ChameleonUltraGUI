param(
    [Parameter(Mandatory = $true)]
    [string] $BuildDirectory
)

$ErrorActionPreference = 'Stop'
$destination = (Resolve-Path $BuildDirectory).Path
if (!(Test-Path (Join-Path $destination 'chameleonultragui.exe'))) {
    throw 'The Windows application must be built before its runtime is bundled.'
}

# App-local CRT deployment: https://learn.microsoft.com/cpp/windows/choosing-a-deployment-method
$vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
$visualStudio = & $vswhere -latest -products '*' -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
if ($LASTEXITCODE -ne 0 -or !$visualStudio) {
    throw 'The Visual Studio C++ toolchain could not be located.'
}
$versions = Get-ChildItem (Join-Path $visualStudio 'VC\Redist\MSVC') -Directory |
    Where-Object { $_.Name -match '^\d+\.\d+\.\d+(\.\d+)?$' } |
    Sort-Object { [version] $_.Name } -Descending
$version = $versions | Select-Object -First 1
if (!$version) { throw 'No Visual Studio redistributable version was found.' }
$runtime = Get-ChildItem (Join-Path $version.FullName 'x64') -Directory |
    Where-Object { $_.Name -match '^Microsoft\.VC\d+\.CRT$' } |
    Sort-Object Name -Descending | Select-Object -First 1
if (!$runtime) { throw 'The x64 redistributable CRT directory was not found.' }

$libraries = @(Get-ChildItem $runtime.FullName -Filter '*.dll' -File)
if (!$libraries.Count) { throw 'The redistributable CRT directory is empty.' }
foreach ($library in $libraries) {
    $signature = Get-AuthenticodeSignature $library.FullName
    if ($signature.Status -ne 'Valid' -or $signature.SignerCertificate.Subject -notlike '*Microsoft*') {
        throw "The runtime library is not signed by Microsoft: $($library.Name)"
    }
    Copy-Item $library.FullName -Destination $destination
}
foreach ($name in @('msvcp140.dll', 'vcruntime140.dll', 'vcruntime140_1.dll')) {
    if (!(Test-Path (Join-Path $destination $name))) {
        throw "The application package is missing $name"
    }
}
Write-Host "Bundled $($libraries.Count) signed x64 CRT libraries from Visual Studio $($version.Name)."
