function Get-SynthConfigDefault {
    <#
    .SYNOPSIS
        Returns the settings used wherever lab.json leaves a value out.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param()

    @{
        operations     = @{
            fqdn                 = ''
            username             = 'admin'
            authSource           = 'LOCAL'
            skipCertificateCheck = $false
            timeoutSeconds       = 60
        }
        adapterKind    = @{
            key  = 'VcfOpsSynth'
            name = 'VCF Ops Synth'
        }
        prefix         = 'Synth-'
        timeZone       = 'Europe/Dublin'
        intervalMinutes = 5
        backfillDays   = 30
        paths          = @{
            data  = '/data'
            state = '/data/state.json'
        }
        liveLoad       = @{
            enabled      = $false
            maxLoadVms   = 6
            maxUpsaPairs = 2
        }
    }
}

function Merge-SynthHashtable {
    <#
    .SYNOPSIS
        Overlays one nested hashtable on another; values in Override win.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][hashtable]$Base,
        [Parameter(Mandatory)][hashtable]$Override
    )

    $result = @{}
    foreach ($key in $Base.Keys) { $result[$key] = $Base[$key] }
    foreach ($key in $Override.Keys) {
        if ($result.ContainsKey($key) -and $result[$key] -is [hashtable] -and $Override[$key] -is [hashtable]) {
            $result[$key] = Merge-SynthHashtable -Base $result[$key] -Override $Override[$key]
        }
        else {
            $result[$key] = $Override[$key]
        }
    }
    $result
}

function Get-SynthSecret {
    <#
    .SYNOPSIS
        Reads the Operations password from the environment or a secret file.

    .DESCRIPTION
        VCFOPS_PASSWORD wins. Otherwise VCFOPS_PASSWORD_FILE names a file to read,
        which is how a Docker secret is mounted (/run/secrets/<name>). Returns $null
        when neither is set, so callers decide whether a password is needed.
    #>
    [CmdletBinding()]
    [OutputType([securestring])]
    param()

    if ($env:VCFOPS_PASSWORD) {
        return ConvertTo-SecureString -String $env:VCFOPS_PASSWORD -AsPlainText -Force
    }
    if ($env:VCFOPS_PASSWORD_FILE) {
        if (-not (Test-Path -LiteralPath $env:VCFOPS_PASSWORD_FILE)) {
            throw "VCFOPS_PASSWORD_FILE points at '$($env:VCFOPS_PASSWORD_FILE)', which does not exist."
        }
        $text = (Get-Content -LiteralPath $env:VCFOPS_PASSWORD_FILE -Raw).TrimEnd("`r", "`n")
        return ConvertTo-SecureString -String $text -AsPlainText -Force
    }
    $null
}

function Test-SynthWholeNumber {
    <# True for an integer value as ConvertFrom-Json produces it (Int32 or Int64). #>
    [CmdletBinding()]
    [OutputType([bool])]
    param([AllowNull()]$Value)
    $Value -is [int] -or $Value -is [long]
}
