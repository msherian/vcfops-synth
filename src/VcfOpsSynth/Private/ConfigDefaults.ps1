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
            data      = '/data'
            state     = '/data/state.json'
            inventory = '/data/inventory.json'
        }
        import         = @{
            source      = '/data/rvtools.xlsx'
            tiering     = '/config/tiering.json'
            # Optional LiveOptics VMware workbook; empty means RVTools baselines only.
            performance = $null
            anonymise   = $true
        }
        seed           = @{
            # The vCenter adapter instance the synthetic tree goes under, by name (vc-mgmt-a).
            adapterInstance = ''
            # Rubrics captured from the lab; empty means <paths.data>/rubrics.
            rubrics         = ''
            # Seeded objects keep their inventory names; a prefix is optional. The tag marks them as synthetic.
            prefix             = ''
            tag                = @{ category = 'vcfops-synth'; name = 'synthetic' }
            # Project tag (category Project); empty means the YYYY.#### ... OPP-n folder the RVTools export was imported from.
            project            = ''
            # Name of a Physical Data Center above the datacenters; empty means none.
            physicalDatacenter = ''
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
        Three ways to give it, each as a parameter or an environment variable:
        the password itself (-Password, VCFOPS_PASSWORD), a file holding it
        (-PasswordFile, VCFOPS_PASSWORD_FILE), or the name of a Docker secret,
        read from <SecretsPath>/<name>, /run/secrets by default (-SecretName,
        VCFOPS_SECRET_NAME). Any parameter wins over every variable; within each,
        the password beats the file, which beats the secret. Returns $null when
        none is set, so callers decide whether a password is needed.

    .PARAMETER Password
        The password, as a SecureString or as text.

    .PARAMETER PasswordFile
        A file holding the password.

    .PARAMETER SecretName
        A Docker secret holding the password.

    .PARAMETER SecretsPath
        Where Docker mounts secrets.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingConvertToSecureStringWithPlainText', '', Justification = 'The password arrives as plain text from a parameter, an environment variable or a secret file; this is where it becomes a SecureString.')]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingPlainTextForPassword', 'PasswordFile', Justification = 'A path to the password, not the password.')]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingPlainTextForPassword', 'Password', Justification = 'Takes a SecureString, or text from pwsh -File or an environment variable, and returns a SecureString.')]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', 'SecretsPath', Justification = 'Used inside the fromSecret script block, which the rule does not follow.')]
    [CmdletBinding()]
    [OutputType([securestring])]
    param(
        [object]$Password,
        [string]$PasswordFile,
        [string]$SecretName,
        [string]$SecretsPath = '/run/secrets'
    )

    $readFile = {
        param($File, $From)
        if (-not (Test-Path -LiteralPath $File)) { throw "$From points at '$File', which does not exist." }
        ConvertTo-SecureString -String ((Get-Content -LiteralPath $File -Raw).TrimEnd("`r", "`n")) -AsPlainText -Force
    }
    $fromSecret = {
        param($Name, $From)
        if ($Name -match '[\\/]' -or $Name -match '^\.\.?$') { throw "$From must be a secret name, not a path; got '$Name'." }
        & $readFile (Join-Path $SecretsPath $Name) $From
    }
    if ($Password -is [securestring]) { return $Password }
    if ($Password) { return ConvertTo-SecureString -String ([string]$Password) -AsPlainText -Force }
    if ($PasswordFile) { return & $readFile $PasswordFile '-PasswordFile' }
    if ($SecretName) { return & $fromSecret $SecretName '-SecretName' }
    if ($env:VCFOPS_PASSWORD) { return ConvertTo-SecureString -String $env:VCFOPS_PASSWORD -AsPlainText -Force }
    if ($env:VCFOPS_PASSWORD_FILE) { return & $readFile $env:VCFOPS_PASSWORD_FILE 'VCFOPS_PASSWORD_FILE' }
    if ($env:VCFOPS_SECRET_NAME) { return & $fromSecret $env:VCFOPS_SECRET_NAME 'VCFOPS_SECRET_NAME' }
    $null
}

function Test-SynthWholeNumber {
    <# True for an integer value as ConvertFrom-Json produces it (Int32 or Int64). #>
    [CmdletBinding()]
    [OutputType([bool])]
    param([AllowNull()]$Value)
    $Value -is [int] -or $Value -is [long]
}
