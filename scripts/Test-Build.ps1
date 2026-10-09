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
$files = @(
    @{ Path = 'main.js'; Bytes = [Text.Encoding]::UTF8.GetBytes('console.log("main")') },
    @{ Path = 'preload.js'; Bytes = [Text.Encoding]::UTF8.GetBytes('console.log("preload")') },
    @{ Path = 'package.json'; Bytes = [Text.Encoding]::UTF8.GetBytes('{"main":"main.js"}') },
    @{ Path = 'game.html'; Bytes = [Text.Encoding]::UTF8.GetBytes('<html>game</html>') },
    @{ Path = 'css/style.css'; Bytes = [Text.Encoding]::UTF8.GetBytes('body {}') },
    @{ Path = 'js/istrolid.cat.js'; Bytes = [Text.Encoding]::UTF8.GetBytes('console.log("game")') }
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
} finally {
    Remove-Item -LiteralPath $fixture -Recurse -Force -ErrorAction SilentlyContinue
}
