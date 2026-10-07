Set-StrictMode -Version Latest

# Private helpers first, so public functions can rely on them at load time.
foreach ($folder in 'Private', 'Public') {
    $path = Join-Path $PSScriptRoot $folder
    if (Test-Path $path) {
        Get-ChildItem -Path $path -Filter '*.ps1' | Sort-Object Name | ForEach-Object { . $_.FullName }
    }
}

# The current Operations session, set by Connect-SynthOps.
$script:OpsSession = $null
