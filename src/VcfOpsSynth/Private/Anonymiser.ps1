function Get-SynthObjectId {
    <#
    .SYNOPSIS
        Returns a stable, opaque ID for an inventory object, such as vm-3f9a2c1d0b.

    .DESCRIPTION
        The ID is a keyed hash (HMAC-SHA256) of the object's kind and its identity
        in the export, so the same object gets the same ID on every import with the
        same key, and later stages can match it to what they created before. Keying
        the hash stops anyone holding the output from confirming a guessed name by
        hashing it themselves. Anonymised objects use the ID as their name.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string]$Kind,
        [Parameter(Mandatory)][string]$Identity,
        [Parameter(Mandatory)][byte[]]$Key
    )

    $hmac = [System.Security.Cryptography.HMACSHA256]::new($Key)
    try {
        $hash = $hmac.ComputeHash([System.Text.Encoding]::UTF8.GetBytes("$Kind|$($Identity.ToLowerInvariant())"))
    }
    finally {
        $hmac.Dispose()
    }
    '{0}-{1}' -f $Kind, ([System.Convert]::ToHexString($hash, 0, 5).ToLowerInvariant())
}

function Get-SynthAnonymisationKey {
    <#
    .SYNOPSIS
        Returns the key that makes object IDs and pseudonyms stable across imports.

    .DESCRIPTION
        VCFOPS_SYNTH_ANON_KEY wins, for runs that keep no state. Otherwise the key
        lives in anonymise.key in the data folder, created with 32 random bytes the
        first time. Keep that file to keep the same pseudonyms on re-import; delete
        it to issue new ones (objects already seeded will then no longer match).
    #>
    [CmdletBinding()]
    [OutputType([byte[]])]
    param([Parameter(Mandatory)][string]$DataPath)

    if ($env:VCFOPS_SYNTH_ANON_KEY) {
        return [System.Text.Encoding]::UTF8.GetBytes($env:VCFOPS_SYNTH_ANON_KEY)
    }

    $file = Join-Path $DataPath 'anonymise.key'
    if (Test-Path -LiteralPath $file) {
        $text = (Get-Content -LiteralPath $file -Raw).Trim()
        try { return [System.Convert]::FromBase64String($text) }
        catch { throw "'$file' is not a valid key. Delete it to create a new one, which changes every pseudonym." }
    }

    if (-not (Test-Path -LiteralPath $DataPath)) {
        $null = New-Item -ItemType Directory -Path $DataPath -Force
    }
    $bytes = [System.Security.Cryptography.RandomNumberGenerator]::GetBytes(32)
    Set-Content -LiteralPath $file -Value ([System.Convert]::ToBase64String($bytes)) -NoNewline
    Write-Verbose "Created anonymisation key $file."
    $bytes
}
