# Splits or patches the preserved //from source sections inside Istrolid's JS bundle.
# Works with Windows PowerShell 5.1; never executes JavaScript.
param(
    [Parameter(Mandatory = $true)][string]$Bundle,
    [string]$ExportDirectory,
    [string]$ModulesDirectory,
    [string]$OutputBundle
)
$ErrorActionPreference = 'Stop'
if (-not $ExportDirectory -and -not $ModulesDirectory) {
    throw 'Specify -ExportDirectory, -ModulesDirectory, or both.'
}
if ($ModulesDirectory -and -not $OutputBundle) {
    throw '-ModulesDirectory requires -OutputBundle.'
}
$Bundle = [IO.Path]::GetFullPath($Bundle)
$utf8 = New-Object System.Text.UTF8Encoding($false, $true)
$text = [IO.File]::ReadAllText($Bundle, $utf8)
$pattern = '(?m)^//from (?<name>[^\r\n]+)(?:\r?\n|$)'
$markers = [regex]::Matches($text, $pattern)
if ($markers.Count -lt 2) { throw "No recognizable source boundaries in $Bundle" }

$sections = New-Object System.Collections.ArrayList
$names = @{}
for ($i = 0; $i -lt $markers.Count; $i++) {
    $m = $markers[$i]
    $name = $m.Groups['name'].Value.Trim()
    if ($name -notmatch '^(src|lib|atlases)/[A-Za-z0-9_./-]+\.js$' -or
        ($name -split '/') -contains '..' -or $names.ContainsKey($name)) {
        throw "Invalid or duplicated source marker: $name"
    }
    $names[$name] = $true
    $start = $m.Index
    $end = if ($i + 1 -lt $markers.Count) { $markers[$i + 1].Index } else { $text.Length }
    [void]$sections.Add([pscustomobject]@{
        Name = $name
        Content = $text.Substring($start, $end - $start)
        StartLine = ([regex]::Matches($text.Substring(0, $start), '\n')).Count + 1
    })
}

if ($ExportDirectory) {
    $exportRoot = [IO.Path]::GetFullPath($ExportDirectory)
    [IO.Directory]::CreateDirectory($exportRoot) | Out-Null
    foreach ($section in $sections) {
        $dest = Join-Path $exportRoot ($section.Name.Replace('/', [IO.Path]::DirectorySeparatorChar))
        [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($dest)) | Out-Null
        [IO.File]::WriteAllText($dest, $section.Content, $utf8)
    }
    $manifest = @($sections | ForEach-Object {
        $data = $utf8.GetBytes($_.Content)
        $sha = [Security.Cryptography.SHA256]::Create()
        try {
            $digest = [BitConverter]::ToString($sha.ComputeHash($data)).Replace('-', '').ToLowerInvariant()
        } finally {
            $sha.Dispose()
        }
        [pscustomobject]@{
            path = $_.Name
            source_line = $_.StartLine
            bytes = $data.Length
            sha256 = $digest
        }
    }) | ConvertTo-Json -Depth 3
    [IO.File]::WriteAllText((Join-Path $exportRoot '_source-map.json'), $manifest, $utf8)
    Write-Host ("Exported {0} original source sections to {1}" -f $sections.Count, $exportRoot)
}

if ($ModulesDirectory) {
    $modulesRoot = [IO.Path]::GetFullPath($ModulesDirectory)
    $changes = @{}
    if (Test-Path -LiteralPath $modulesRoot -PathType Container) {
        foreach ($file in Get-ChildItem -LiteralPath $modulesRoot -Recurse -File -Filter '*.js') {
            $name = $file.FullName.Substring($modulesRoot.Length).TrimStart([char[]]@('\', '/')).Replace('\', '/')
            if (-not $names.ContainsKey($name)) {
                throw "Module override has no matching bundle section: $name"
            }
            $replacement = [IO.File]::ReadAllText($file.FullName, $utf8)
            $first = [regex]::Match($replacement, '\A//from (?<name>[^\r\n]+)(?:\r?\n|$)')
            if (-not $first.Success -or $first.Groups['name'].Value.Trim() -ne $name) {
                throw "Module $name must retain its original first //from marker."
            }
            if ([regex]::Matches($replacement, $pattern).Count -ne 1) {
                throw "Module $name contains additional //from markers. Only one section is permitted."
            }
            $changes[$name] = $replacement
        }
    }
    $sb = New-Object System.Text.StringBuilder
    if ($markers[0].Index -gt 0) {
        [void]$sb.Append($text.Substring(0, $markers[0].Index))
    }
    foreach ($section in $sections) {
        if ($changes.ContainsKey($section.Name)) {
            [void]$sb.Append($changes[$section.Name])
        } else {
            [void]$sb.Append($section.Content)
        }
    }
    $result = $sb.ToString()
    $output = [IO.Path]::GetFullPath($OutputBundle)
    [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($output)) | Out-Null
    # A no-op pack must preserve the input file exactly, even if encoding differs.
    if ($changes.Count -eq 0) {
        if ($output -ne $Bundle) { [IO.File]::Copy($Bundle, $output, $true) }
    } else {
        [IO.File]::WriteAllText($output, $result, $utf8)
    }
    Write-Host ("Rebuilt JavaScript bundle with {0} module override(s)." -f $changes.Count)
}
