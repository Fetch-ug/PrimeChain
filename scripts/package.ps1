<#
.SYNOPSIS
    Builds a push-ready zip of the PrimeChain tree, including hidden directories.

.DESCRIPTION
    Windows archivers (and Explorer's "Send to > Compressed folder") silently drop
    dot-directories, which is how .github/workflows ends up missing from a repo.
    This script enumerates files itself and writes explicit zip entries, then
    re-opens the archive and asserts the workflows are inside.

    It also writes MANIFEST.sha256 into the archive so the contents can be verified
    after transfer.

.EXAMPLE
    pwsh -File scripts\package.ps1 -Output C:\temp\primechain-phase1.zip
#>
[CmdletBinding()]
param(
    [string]$Output = "primechain-phase1.zip"
)

$ErrorActionPreference = "Stop"

Add-Type -AssemblyName System.IO.Compression | Out-Null
Add-Type -AssemblyName System.IO.Compression.FileSystem | Out-Null

$root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
if (-not [System.IO.Path]::IsPathRooted($Output)) {
    $Output = Join-Path $root $Output
}

$excludeDirs = @(
    '.git', '.dsh', 'lib', 'out', 'cache', 'broadcast', 'node_modules',
    '_stack', '__pycache__', '.venv', 'venv', 'dist', 'build', 'crytic-export'
)
$excludeFiles = @('_delete_probe.txt', '.github/workflows/_probe.yml')

function Get-RelativePath([string]$full, [string]$base) {
    return $full.Substring($base.Length + 1).Replace('\', '/')
}

$allFiles = Get-ChildItem -Path $root -Recurse -File -Force | Where-Object {
    $rel = Get-RelativePath $_.FullName $root
    if ($excludeFiles -contains $rel) { return $false }
    $parts = $rel.Split('/')
    if ($parts.Length -gt 1) {
        $dirs = $parts[0..($parts.Length - 2)]
        foreach ($d in $dirs) { if ($excludeDirs -contains $d) { return $false } }
    }
    return $true
} | Sort-Object FullName

if (-not $allFiles) { throw "No files found under $root" }

$manifestLines = New-Object System.Collections.Generic.List[string]
foreach ($f in $allFiles) {
    $rel = Get-RelativePath $f.FullName $root
    $hash = (Get-FileHash -Path $f.FullName -Algorithm SHA256).Hash.ToLower()
    $manifestLines.Add("$hash  $rel")
}
$manifest = ($manifestLines -join "`n") + "`n"

if (Test-Path $Output) { Remove-Item -Path $Output -Force }

$zip = [System.IO.Compression.ZipFile]::Open($Output, [System.IO.Compression.ZipArchiveMode]::Create)
try {
    foreach ($f in $allFiles) {
        $rel = Get-RelativePath $f.FullName $root
        [System.IO.Compression.ZipFileExtensions]::CreateEntryFromFile(
            $zip, $f.FullName, $rel, [System.IO.Compression.CompressionLevel]::Optimal
        ) | Out-Null
    }

    $entry = $zip.CreateEntry('MANIFEST.sha256')
    $stream = $entry.Open()
    $writer = New-Object System.IO.StreamWriter($stream)
    try { $writer.Write($manifest) } finally { $writer.Dispose(); $stream.Dispose() }
}
finally {
    $zip.Dispose()
}

# --- verify by re-opening the archive ---
$check = [System.IO.Compression.ZipFile]::OpenRead($Output)
try {
    $names = @($check.Entries | ForEach-Object { $_.FullName })
}
finally {
    $check.Dispose()
}

$required = @(
    '.github/workflows/contracts.yml',
    '.github/workflows/format.yml',
    '.github/workflows/secrets.yml',
    '.gitignore',
    'contracts/src/Prime.sol',
    'contracts/test/Prime.t.sol',
    'contracts/foundry.toml',
    'infra/devnet/smoke.py',
    'ARCHITECTURE.md',
    'THREAT_MODEL.md',
    'DECISIONS.md',
    'PROGRESS.md',
    'MANIFEST.sha256'
)

$missing = @($required | Where-Object { $names -notcontains $_ })
if ($missing.Count -gt 0) {
    throw ("Archive is missing required entries: " + ($missing -join ', '))
}
if (($names | Where-Object { $_ -like '.github/workflows/*.yml' }).Count -lt 3) {
    throw "Archive does not contain all three workflow files"
}

$sizeKb = [math]::Round((Get-Item $Output).Length / 1KB, 1)
Write-Output "zip      : $Output"
Write-Output "entries  : $($names.Count) (incl. MANIFEST.sha256)"
Write-Output "size     : $sizeKb KB"
Write-Output "dot-dirs : .github/workflows included ($((($names | Where-Object { $_ -like '.github/workflows/*' }).Count)) files)"
Write-Output "verified : all required paths present"
