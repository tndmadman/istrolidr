# Rebuilds a separate runnable Electron copy from an installed, legitimate Istrolid copy.
param(
    [string]$GameDir = $env:ISTROLID_GAME_DIR,
    [switch]$Clean,
    [switch]$BuildOnly
)
$ErrorActionPreference = 'Stop'
$project = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$build = Join-Path $project '.build\IstrolidR'
$overlay = Join-Path $project 'overrides'

function Find-Game([string]$requested) {
    $candidates = New-Object 'System.Collections.Generic.List[string]'
    if ($requested) { $candidates.Add($requested) }
    $candidates.Add((Join-Path $project 'Istrolid'))
    $steamRoots = New-Object 'System.Collections.Generic.List[string]'
    $steamRoots.Add((Join-Path ([Environment]::GetFolderPath('ProgramFilesX86')) 'Steam'))
    foreach ($regPath in @('HKCU:\Software\Valve\Steam', 'HKLM:\SOFTWARE\WOW6432Node\Valve\Steam')) {
        $entry = Get-ItemProperty -Path $regPath -ErrorAction SilentlyContinue
        if ($entry) {
            foreach ($key in @('SteamPath', 'InstallPath')) {
                if ($entry.$key) { $steamRoots.Add([string]$entry.$key) }
            }
        }
    }
    foreach ($drive in @('C:', 'D:', 'E:', 'F:', 'G:')) {
        $rootDrive = $drive + '\'
        if (Test-Path -LiteralPath $rootDrive -PathType Container) {
            $steamRoots.Add((Join-Path $rootDrive 'SteamLibrary'))
        }
    }
    $allLibraries = New-Object 'System.Collections.Generic.List[string]'
    foreach ($steam in $steamRoots) {
        if (-not $steam) { continue }
        $allLibraries.Add($steam)
        $vdf = Join-Path $steam 'steamapps\libraryfolders.vdf'
        if (Test-Path -LiteralPath $vdf -PathType Leaf) {
            $raw = [IO.File]::ReadAllText($vdf)
            foreach ($m in [regex]::Matches($raw, '"path"\s+"([^"]+)"')) {
                $allLibraries.Add($m.Groups[1].Value.Replace('\\', '\'))
            }
        }
    }
    foreach ($library in $allLibraries) {
        $candidates.Add((Join-Path $library 'steamapps\common\Istrolid'))
    }
    foreach ($candidate in $candidates) {
        if (-not $candidate) { continue }
        if ($candidate.EndsWith('.exe', [StringComparison]::OrdinalIgnoreCase)) {
            $candidate = [IO.Path]::GetDirectoryName($candidate)
        }
        $exe = Join-Path $candidate 'istrolid.exe'
        $asar = Join-Path $candidate 'resources\app.asar'
        if ((Test-Path -LiteralPath $exe -PathType Leaf) -and (Test-Path -LiteralPath $asar -PathType Leaf)) {
            return [IO.Path]::GetFullPath($candidate)
        }
    }
    throw 'Istrolid installation not found. Supply its folder: Run-Istrolid.cmd -GameDir "D:\SteamLibrary\steamapps\common\Istrolid"'
}

$source = Find-Game $GameDir
$asarPath = Join-Path $source 'resources\app.asar'
Write-Host "Using Istrolid installation: $source"
if ($Clean -and (Test-Path -LiteralPath $build)) {
    Remove-Item -LiteralPath $build -Recurse -Force
}
[IO.Directory]::CreateDirectory($build) | Out-Null
$buildResources = Join-Path $build 'resources'
[IO.Directory]::CreateDirectory($buildResources) | Out-Null

# Copy the installed Electron runtime, DLLs, locales and support files. Never modify the original.
foreach ($item in Get-ChildItem -LiteralPath $source -Force) {
    if ($item.Name -eq 'resources') { continue }
    $target = Join-Path $build $item.Name
    if ($item.PSIsContainer) {
        if (-not (Test-Path -LiteralPath $target)) {
            Copy-Item -LiteralPath $item.FullName -Destination $target -Recurse -Force
        }
    } elseif ((-not (Test-Path -LiteralPath $target -PathType Leaf)) -or
              ((Get-Item -LiteralPath $target).Length -ne $item.Length) -or
              ((Get-Item -LiteralPath $target).LastWriteTimeUtc -ne $item.LastWriteTimeUtc)) {
        Copy-Item -LiteralPath $item.FullName -Destination $target -Force
    }
}
foreach ($item in Get-ChildItem -LiteralPath (Join-Path $source 'resources') -Force) {
    if ($item.Name -in @('app.asar', 'app', 'app.asar.unpacked')) { continue }
    $target = Join-Path $buildResources $item.Name
    if (-not (Test-Path -LiteralPath $target)) {
        Copy-Item -LiteralPath $item.FullName -Destination $target -Recurse -Force
    }
}

# Rebuild when the installation or tracked overrides change (including file deletions).
$asarInfo = Get-Item -LiteralPath $asarPath
$stampLines = New-Object 'System.Collections.Generic.List[string]'
$stampLines.Add("asar:$($asarInfo.Length):$($asarInfo.LastWriteTimeUtc.Ticks)")
if (Test-Path -LiteralPath $overlay -PathType Container) {
    foreach ($file in Get-ChildItem -LiteralPath $overlay -Recurse -File | Sort-Object FullName) {
        if ($file.Name -eq '.gitkeep') { continue }
        $relative = $file.FullName.Substring($overlay.Length).TrimStart([char[]]@('\', '/'))
        $hash = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash
        $stampLines.Add(('{0}:{1}' -f $relative, $hash))
    }
}
$modules = Join-Path $project 'modules'
if (Test-Path -LiteralPath $modules -PathType Container) {
    foreach ($file in Get-ChildItem -LiteralPath $modules -Recurse -File -Filter '*.js' | Sort-Object FullName) {
        $relative = $file.FullName.Substring($modules.Length).TrimStart([char[]]@('\', '/'))
        $hash = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash
        $stampLines.Add(('module:{0}:{1}' -f $relative, $hash))
    }
}
$moduleTool = Join-Path $PSScriptRoot 'Source-Modules.ps1'
$stampLines.Add(('module-tool:' + (Get-FileHash -LiteralPath $moduleTool -Algorithm SHA256).Hash))
$stamp = ($stampLines -join [Environment]::NewLine)
$stampFile = Join-Path $build '.build-stamp'
$appDir = Join-Path $buildResources 'app'
$oldStamp = if (Test-Path -LiteralPath $stampFile -PathType Leaf) {
    [IO.File]::ReadAllText($stampFile)
} else { '' }
if (($oldStamp -ne $stamp) -or -not (Test-Path -LiteralPath (Join-Path $appDir 'game.html'))) {
    $stage = Join-Path $buildResources 'app.stage'
    if (Test-Path -LiteralPath $stage) { Remove-Item -LiteralPath $stage -Recurse -Force }
    Write-Host 'Extracting original game assets and code...'
    & (Join-Path $PSScriptRoot 'Extract-Asar.ps1') -Archive $asarPath -Destination $stage
    if ($LASTEXITCODE -and $LASTEXITCODE -ne 0) { throw 'ASAR extractor failed.' }
    if (Test-Path -LiteralPath $overlay -PathType Container) {
        foreach ($file in Get-ChildItem -LiteralPath $overlay -Recurse -File) {
            if ($file.Name -eq '.gitkeep') { continue }
            $relative = $file.FullName.Substring($overlay.Length).TrimStart([char[]]@('\', '/'))
            $target = Join-Path $stage $relative
            [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($target)) | Out-Null
            Copy-Item -LiteralPath $file.FullName -Destination $target -Force
        }
    }
    if (Test-Path -LiteralPath $modules -PathType Container) {
        $hasModules = @(Get-ChildItem -LiteralPath $modules -Recurse -File -Filter '*.js').Count -gt 0
        if ($hasModules) {
            $bundle = Join-Path $stage 'js\istrolid.cat.js'
            Write-Host 'Applying individual JavaScript module overrides...'
            & $moduleTool -Bundle $bundle -ModulesDirectory $modules -OutputBundle $bundle
        }
    }
    foreach ($needed in @('package.json', 'main.js', 'preload.js', 'game.html', 'js\istrolid.cat.js', 'css\style.css')) {
        if (-not (Test-Path -LiteralPath (Join-Path $stage $needed) -PathType Leaf)) {
            throw "Missing critical game file after extraction: $needed"
        }
    }
    if (Test-Path -LiteralPath $appDir) { Remove-Item -LiteralPath $appDir -Recurse -Force }
    Move-Item -LiteralPath $stage -Destination $appDir
    [IO.File]::WriteAllText($stampFile, $stamp)
    Write-Host 'Build finished.'
} else {
    Write-Host 'Build is current; no extraction needed.'
}

$launchExe = Join-Path $build 'istrolid.exe'
if (-not (Test-Path -LiteralPath $launchExe -PathType Leaf)) { throw "Missing Electron runtime: $launchExe" }
if (-not $BuildOnly) {
    Write-Host 'Launching IstrolidR...'
    Start-Process -FilePath $launchExe -WorkingDirectory $build
} else {
    Write-Host "Build only. Launcher is at: $launchExe"
}
