# Self-contained Windows test: synthetic ASAR + Git override, no installed game needed.
$ErrorActionPreference = 'Stop'
$sourceRepo = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$fixture = Join-Path $env:TEMP ('istrolidr-smoke-' + [guid]::NewGuid().ToString('N'))
$project = Join-Path $fixture 'project'
$game = Join-Path $fixture 'Istrolid'
$assets = Join-Path $game 'resources'
[IO.Directory]::CreateDirectory($assets) | Out-Null
[IO.Directory]::CreateDirectory((Join-Path $project 'scripts')) | Out-Null
[IO.Directory]::CreateDirectory((Join-Path $project 'overrides')) | Out-Null
Copy-Item -LiteralPath (Join-Path $sourceRepo 'scripts/Build-And-Run.ps1') -Destination (Join-Path $project 'scripts')
Copy-Item -LiteralPath (Join-Path $sourceRepo 'scripts/Extract-Asar.ps1') -Destination (Join-Path $project 'scripts')
Copy-Item -LiteralPath (Join-Path $sourceRepo 'scripts/Source-Modules.ps1') -Destination (Join-Path $project 'scripts')
$files = @(
    @{ Path = 'main.js'; Bytes = [Text.Encoding]::UTF8.GetBytes('console.log("main")') },
    @{ Path = 'preload.js'; Bytes = [Text.Encoding]::UTF8.GetBytes('console.log("preload")') },
    @{ Path = 'package.json'; Bytes = [Text.Encoding]::UTF8.GetBytes('{"main":"main.js"}') },
    @{ Path = 'game.html'; Bytes = [Text.Encoding]::UTF8.GetBytes('<html>game</html>') },
    @{ Path = 'css/style.css'; Bytes = [Text.Encoding]::UTF8.GetBytes('body {}') },
    @{ Path = 'js/istrolid.cat.js'; Bytes = [Text.Encoding]::UTF8.GetBytes("`n`n//from src/sim.js`nconsole.log('sim');`n//from src/ai.js`nconsole.log('old ai');`n//from atlases/atlas.js`n") }
)
$root = @{ files = @{} }
$offset = 0
foreach ($item in $files) {
    $segments = $item.Path.Split('/')
    $node = $root.files
    for ($i = 0; $i -lt ($segments.Length - 1); $i++) {
        if (-not $node.ContainsKey($segments[$i])) { $node[$segments[$i]] = @{ files = @{} } }
        $node = $node[$segments[$i]].files
    }
    $node[$segments[-1]] = @{ size = $item.Bytes.Length; offset = [string]$offset }
    $offset += $item.Bytes.Length
}
$json = [Text.Encoding]::UTF8.GetBytes(($root | ConvertTo-Json -Depth 20 -Compress))
$pad = (4 - ($json.Length % 4)) % 4
$headerSize = 4 + $json.Length + $pad
$stream = [IO.File]::Create((Join-Path $assets 'app.asar'))
$writer = New-Object IO.BinaryWriter($stream)
try {
    $writer.Write([uint32]4)
    $writer.Write([uint32]($headerSize + 4))
    $writer.Write([uint32]$headerSize)
    $writer.Write([uint32]$json.Length)
    $writer.Write($json)
    $writer.Write((New-Object byte[] $pad))
    foreach ($item in $files) { $writer.Write($item.Bytes) }
} finally { $writer.Dispose() }
[IO.File]::WriteAllText((Join-Path $game 'istrolid.exe'), 'mock exe')
try {
    [IO.File]::WriteAllText((Join-Path $project 'overrides/test-fixture.txt'), 'overlay-applied')
    & (Join-Path $project 'scripts/Build-And-Run.ps1') -GameDir $game -Clean -BuildOnly
    $app = Join-Path $project '.build/IstrolidR/resources/app'
    foreach ($item in $files) {
        $actual = [IO.File]::ReadAllBytes((Join-Path $app $item.Path))
        if ([Convert]::ToBase64String($actual) -ne [Convert]::ToBase64String([byte[]]$item.Bytes)) {
            throw "Data mismatch: $($item.Path)"
        }
    }
    if ([IO.File]::ReadAllText((Join-Path $app 'test-fixture.txt')) -ne 'overlay-applied') {
        throw 'Git override was not applied.'
    }
    Write-Host 'PASS: ASAR extraction, file hashes, overrides, and build staging'
    # Split the locally extracted bundle into its original, independently editable sections.
    $bundle = Join-Path $app 'js/istrolid.cat.js'
    $export = Join-Path $project '.build/sources'
    & (Join-Path $project 'scripts/Source-Modules.ps1') -Bundle $bundle -ExportDirectory $export
    if (-not (Test-Path -LiteralPath (Join-Path $export 'src/ai.js'))) {
        throw 'Missing extracted src/ai.js'
    }
    $modules = Join-Path $project 'modules'
    [IO.Directory]::CreateDirectory((Join-Path $modules 'src')) | Out-Null
    $aiOverride = Join-Path $modules 'src/ai.js'
    [IO.File]::WriteAllText($aiOverride, "//from src/ai.js`nconsole.log('modded ai');`n")
    & (Join-Path $project 'scripts/Build-And-Run.ps1') -GameDir $game -BuildOnly
    $rebuilt = [IO.File]::ReadAllText($bundle)
    if (-not $rebuilt.Contains("console.log('modded ai')") -or
        $rebuilt.Contains("console.log('old ai')") -or
        -not $rebuilt.Contains("console.log('sim')")) {
        throw 'Module replacement failed or damaged neighboring source sections.'
    }
    # Re-run without changing the upstream archive: the override hash must invalidate the build.
    [IO.File]::WriteAllText($aiOverride, "//from src/ai.js`nconsole.log('second change');`n")
    & (Join-Path $project 'scripts/Build-And-Run.ps1') -GameDir $game -BuildOnly
    if (-not ([IO.File]::ReadAllText($bundle)).Contains("console.log('second change')")) {
        throw 'Modified override did not trigger a new build.'
    }
    # Unknown module names should fail loudly, not silently compile a broken bundle.
    [IO.File]::WriteAllText((Join-Path $modules 'src/not-a-module.js'), "//from src/not-a-module.js`n")
    $rejected = $false
    try {
        & (Join-Path $project 'scripts/Source-Modules.ps1') -Bundle $bundle -ModulesDirectory $modules -OutputBundle $bundle
    } catch {
        if ($_.Exception.Message -like '*no matching bundle section*') { $rejected = $true }
        else { throw }
    }
    if (-not $rejected) { throw 'Unexpectedly accepted a non-existent source section.' }
    Write-Host 'PASS: 3 source sections exported, safe module patches, hot rebuild, invalid module rejection'

} finally {
    Remove-Item -LiteralPath $fixture -Recurse -Force -ErrorAction SilentlyContinue
}
