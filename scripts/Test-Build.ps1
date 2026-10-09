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
Copy-Item -LiteralPath (Join-Path $sourceRepo 'scripts/Apply-Offline.ps1') -Destination (Join-Path $project 'scripts')
Copy-Item -LiteralPath (Join-Path $sourceRepo 'scripts/Apply-Private-Client.ps1') -Destination (Join-Path $project 'scripts')
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
    $app = Join-Path $project '.build/Istrolid/resources/app'
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
    $map = [IO.File]::ReadAllText((Join-Path $export '_source-map.json')) | ConvertFrom-Json
    if (@($map).Count -ne 3) { throw 'Source map should list exactly three test sections.' }
    $entry = @($map | Where-Object { $_.path -eq 'src/ai.js' })[0]
    $actualHash = (Get-FileHash -LiteralPath (Join-Path $export 'src/ai.js') -Algorithm SHA256).Hash
    if ($entry.sha256 -ne $actualHash.ToLowerInvariant() -or $entry.bytes -le 0) {
        throw 'Exported module SHA-256 manifest did not match the file.'
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

    # Use a minimal fixture with the same guarded startup anchors as the actual recovered client.
    Remove-Item -LiteralPath (Join-Path $modules 'src/not-a-module.js') -Force
    $offlineBundleFixture = @'
//from src/ai.js
console.log("safe ai");
//from src/ui.js
  ui.reconnectRoot = function() { console.log("online"); };
//from src/istrolid.js
    ua = detect.parse(navigator.userAgent);
    window.rootNet = new RootConnection(rootAddress);
    startInitialSandbox();
//from atlases/atlas.js
console.log("atlas");
'@
    $overrideJS = Join-Path $project 'overrides/js/istrolid.cat.js'
    [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($overrideJS)) | Out-Null
    [IO.File]::WriteAllText($overrideJS, $offlineBundleFixture)
    $offlineMainFixture = @'
(function() {
  app = electron.app;
  track = function(name, ops) { return 1; };
  Menu = electron.Menu;
  process.on("uncaughtException", function() {
    return track("electron_error", {message: "boom"});
  });
  app.on("ready", function() {
    makeMenu();
    mainWindow = new BrowserWindow({
      title: "Istrolid",
    });
  });
})();
'@
    [IO.File]::WriteAllText((Join-Path $project 'overrides/main.js'), $offlineMainFixture)
    & (Join-Path $project 'scripts/Build-And-Run.ps1') -GameDir $game -Offline -BuildOnly
    $patched = [IO.File]::ReadAllText($bundle)
    $mainOffline = [IO.File]::ReadAllText((Join-Path $app 'main.js'))
    foreach ($expected in @('ISTROLIDR_OFFLINE', 'OfflineCommander', 'account.signedIn = true',
                           'battleMode.joinLocal()', 'websocket: {readyState: WebSocket.CLOSED}')) {
        if (-not $patched.Contains($expected)) { throw "Missing offline client guard: $expected" }
    }
    if ($patched.Contains('window.rootNet = new RootConnection(rootAddress);')) {
        throw 'Offline bundle still constructs production root WebSocket.'
    }
    foreach ($expected in @('istrolidr-offline', 'onBeforeRequest', 'cancel: true', 'ISTROLIDR_OFFLINE')) {
        if (-not $mainOffline.Contains($expected)) { throw "Missing offline runtime guard: $expected" }
    }
    if ($mainOffline.Contains('return track("electron_error"')) {
        throw 'Offline runtime still reports exceptions via Node HTTP.'
    }
    if (-not $app.StartsWith((Join-Path $project '.build/Istrolid'))) {
        throw 'Electron preload expects a runtime folder named Istrolid.'
    }

    # Disabling offline MUST return to the baseline bytes and restore online connections.
    & (Join-Path $project 'scripts/Build-And-Run.ps1') -GameDir $game -BuildOnly
    $normal = [IO.File]::ReadAllText($bundle)
    $mainNormal = [IO.File]::ReadAllText((Join-Path $app 'main.js'))
    if ($normal.Contains('ISTROLIDR_OFFLINE') -or
        -not $normal.Contains('window.rootNet = new RootConnection(rootAddress);') -or
        $mainNormal.Contains('ISTROLIDR_OFFLINE')) {
        throw 'Switching from offline back to normal did not restore original startup.'
    }

    # Test the new private server launcher against a synthetic main.js.
    & (Join-Path $project 'scripts/Build-And-Run.ps1') -GameDir $game -PrivateServer -BuildOnly
    $mainPrivate = [IO.File]::ReadAllText((Join-Path $app 'main.js'))
    foreach ($expected in @('ISTROLIDR_PRIVATE', 'istrolidr-private', 'onBeforeRequest', '127\\.0\\.0\\.1')) {
        if (-not $mainPrivate.Contains($expected)) { throw "Missing private-server protection: $expected" }
    }
    & (Join-Path $project 'scripts/Build-And-Run.ps1') -GameDir $game -BuildOnly
    if ([IO.File]::ReadAllText((Join-Path $app 'main.js')).Contains('ISTROLIDR_PRIVATE')) {
        throw 'Disabling PrivateServer did not restore original main.js.'
    }
    Write-Host 'PASS: private server isolation and normal-build restoration'

    # Unknown client version must fail BEFORE any offline file is written.
    $bad = Join-Path $project 'bad-client'
    [IO.Directory]::CreateDirectory((Join-Path $bad 'js')) | Out-Null
    $badJS = Join-Path $bad 'js/istrolid.cat.js'
    $badMain = Join-Path $bad 'main.js'
    [IO.File]::WriteAllText($badJS, 'var unknownVersion = true;')
    [IO.File]::WriteAllText($badMain, $offlineMainFixture)
    $gotVersionError = $false
    try {
        & (Join-Path $project 'scripts/Apply-Offline.ps1') -ApplicationDir $bad
    } catch {
        if ($_.Exception.Message -like '*unsupported game version*') { $gotVersionError = $true }
        else { throw }
    }
    if (-not $gotVersionError) { throw 'Unknown bundle version was not rejected.' }
    if ([IO.File]::ReadAllText($badMain) -ne $offlineMainFixture) {
        throw 'Offline patch partially modified unsupported client.'
    }
    Write-Host 'PASS: guarded offline patch, separate profile, no root connection, telemetry blocks, normal mode restoration, version rejection'

} finally {
    Remove-Item -LiteralPath $fixture -Recurse -Force -ErrorAction SilentlyContinue
}
