param(
    [ValidateSet('retail', 'forever', 'classic', 'anniversary', 'era', 'all')]
    [string] $Target = 'all'
)

$ErrorActionPreference = 'Stop'
$workspaceRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$distDir = Join-Path $workspaceRoot 'dist'
$targets = if ($Target -eq 'all') {
    @('retail', 'forever', 'classic', 'anniversary', 'era')
} else { @($Target) }
$interfaces = @{ forever = 16001; classic = 50504; anniversary = 20506; era = 11509 }

foreach ($flavor in $targets) {
    $manifest = if ($flavor -eq 'retail') { 'FluxLogistics_Standard.toc' } else { 'FluxLogistics.toc' }
    $sourceToc = Join-Path $workspaceRoot $manifest
    if (-not (Test-Path -LiteralPath $sourceToc)) { throw "FluxLogistics source TOC is missing for $flavor." }

    $targetRoot = [IO.Path]::GetFullPath((Join-Path $distDir $flavor))
    $packageDir = [IO.Path]::GetFullPath((Join-Path $targetRoot 'FluxLogistics'))
    $allowedPrefix = [IO.Path]::GetFullPath($distDir).TrimEnd('\') + '\'
    if (-not $packageDir.StartsWith($allowedPrefix, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Unsafe package destination: $packageDir"
    }
    if (Test-Path -LiteralPath $packageDir) {
        Remove-Item -LiteralPath $packageDir -Recurse -Force
    }
    $moduleDir = Join-Path $packageDir 'FluxCraft'
    New-Item -ItemType Directory -Path $moduleDir -Force | Out-Null
    $tocPath = Join-Path $packageDir 'FluxLogistics.toc'
    $toc = Get-Content -LiteralPath $sourceToc -Raw
    if ($flavor -ne 'retail') {
        $toc = $toc -replace '(?m)^## Interface: .+$', "## Interface: $($interfaces[$flavor])"
    }
    [IO.File]::WriteAllText($tocPath, $toc)

    foreach ($line in (Get-Content -LiteralPath $tocPath)) {
        $trimmed = $line.Trim()
        if ($trimmed -eq '' -or $trimmed.StartsWith('#')) { continue }
        $sourceFile = Join-Path $workspaceRoot $trimmed
        if (-not (Test-Path -LiteralPath $sourceFile -PathType Leaf)) {
            throw "Missing in $flavor package: $trimmed"
        }
        Copy-Item -LiteralPath $sourceFile -Destination (Join-Path $packageDir $trimmed)
    }
    if ($flavor -ne 'retail') {
        $targetPath = Join-Path $moduleDir 'Target.lua'
        [IO.File]::AppendAllText($targetPath, "`nif FC.target ~= '$flavor' then FC.disabled = true end`n")
    }

    $zipPath = Join-Path $targetRoot "FluxLogistics-$flavor.zip"
    Compress-Archive -LiteralPath $packageDir -DestinationPath $zipPath -Force
    Write-Output $zipPath
}
