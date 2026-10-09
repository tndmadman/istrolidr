# Windows PowerShell 5.1-compatible ASAR extractor. No npm, Python or external tools needed.
param(
    [Parameter(Mandatory = $true)][string]$Archive,
    [Parameter(Mandatory = $true)][string]$Destination
)
$ErrorActionPreference = 'Stop'
$Archive = [IO.Path]::GetFullPath($Archive)
$Destination = [IO.Path]::GetFullPath($Destination)
[IO.Directory]::CreateDirectory($Destination) | Out-Null
$rootPrefix = $Destination.TrimEnd([char[]]@('\', '/')) + [IO.Path]::DirectorySeparatorChar
$stream = [IO.File]::Open($Archive, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
$reader = New-Object IO.BinaryReader($stream)
$script:fileCount = 0
$buffer = New-Object byte[] (1024 * 1024)
try {
    # Electron ASAR starts with two Chromium Pickle headers followed by UTF-8 JSON.
    $prefixSize = $reader.ReadUInt32()
    $headerWithLength = $reader.ReadUInt32()
    $headerLength = $reader.ReadUInt32()
    $jsonLength = $reader.ReadUInt32()
    if ($prefixSize -ne 4 -or $headerWithLength -ne ($headerLength + 4) -or $jsonLength -gt 16777216) {
        throw 'Invalid or unsupported ASAR header.'
    }
    $jsonBytes = $reader.ReadBytes([int]$jsonLength)
    if ($jsonBytes.Length -ne $jsonLength) { throw 'Truncated ASAR header.' }
    $manifest = [Text.Encoding]::UTF8.GetString($jsonBytes) | ConvertFrom-Json
    if (-not $manifest.files) { throw 'ASAR contains no file table.' }
    $dataStart = 12L + [long]$headerLength

    function Export-Table([object]$table, [string]$subdir) {
        foreach ($property in $table.PSObject.Properties) {
            $entry = $property.Value
            $relative = if ($subdir) { Join-Path $subdir $property.Name } else { $property.Name }
            $target = [IO.Path]::GetFullPath((Join-Path $Destination $relative))
            if (-not $target.StartsWith($rootPrefix, [StringComparison]::OrdinalIgnoreCase)) {
                throw "Unsafe archive path: $relative"
            }
            if ($entry.PSObject.Properties['files']) {
                [IO.Directory]::CreateDirectory($target) | Out-Null
                Export-Table $entry.files $relative
                continue
            }
            if ($entry.PSObject.Properties['link']) { throw "Unsupported ASAR link: $relative" }
            [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($target)) | Out-Null
            if ($entry.PSObject.Properties['unpacked'] -and $entry.unpacked) {
                $unpackedPath = Join-Path ($Archive + '.unpacked') $relative
                if (-not (Test-Path -LiteralPath $unpackedPath -PathType Leaf)) {
                    throw "Missing ASAR unpacked dependency: $unpackedPath"
                }
                [IO.File]::Copy($unpackedPath, $target, $true)
            } else {
                $remaining = [long]$entry.size
                $stream.Position = $dataStart + [long]::Parse([string]$entry.offset, [Globalization.CultureInfo]::InvariantCulture)
                $out = [IO.File]::Open($target, [IO.FileMode]::Create, [IO.FileAccess]::Write, [IO.FileShare]::None)
                try {
                    while ($remaining -gt 0) {
                        $amount = [int][Math]::Min($remaining, $buffer.Length)
                        $read = $stream.Read($buffer, 0, $amount)
                        if ($read -eq 0) { throw "Truncated ASAR while reading $relative" }
                        $out.Write($buffer, 0, $read)
                        $remaining -= $read
                    }
                } finally { $out.Dispose() }
            }
            $script:fileCount++
        }
    }
    Export-Table $manifest.files ''
    Write-Host "Extracted $script:fileCount files from $Archive"
} finally {
    $reader.Dispose()
    $stream.Dispose()
}
