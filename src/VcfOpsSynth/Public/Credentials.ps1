function Read-SynthCredentialFile {
    <#
    .SYNOPSIS
        Reads the VCF Operations host, account and password from a VCF installer credentials file.

    .DESCRIPTION
        The installer's credentials file is JSON with one entry per component:

            { "components": [ { "componentName": "VCF Operations", "FQDN": "ops.example.test",
                                "credentials": [ { "type": "Administrator credentials",
                                                   "user": "admin", "password": "..." } ] } ] }

        The VCF Operations entry gives the host (a URL is cut down to its host name)
        and its Administrator credentials give the account and password. When the
        file lists more than one VCF Operations, -Fqdn picks the one to use.

    .PARAMETER Path
        The credentials file.

    .PARAMETER Fqdn
        The VCF Operations to pick when the file lists several.

    .EXAMPLE
        $cred = Read-SynthCredentialFile -Path ./vcf-installer-creds.json
        Connect-SynthOps -Config (Get-SynthConfig -Fqdn $cred.Fqdn -Username $cred.Username) -Password $cred.Password
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingConvertToSecureStringWithPlainText', '', Justification = 'The password arrives as text in the credentials file; this is where it becomes a SecureString.')]
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][string]$Path,
        [string]$Fqdn
    )

    if (-not (Test-Path -LiteralPath $Path)) { throw "Credentials file '$Path' does not exist." }
    $doc = $null
    try { $doc = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json -AsHashtable }
    catch { throw "Credentials file '$Path' is not valid JSON." }
    if ($doc -isnot [System.Collections.IDictionary] -or -not $doc.Contains('components')) {
        throw "'$Path' is not a VCF installer credentials file: it has no components list."
    }

    $hostOf = {
        param($Value)
        $text = "$Value".Trim()
        if ($text -match '^\w+://') { ([uri]$text).Host } else { $text.TrimEnd('/') }
    }
    $ops = @($doc.components | Where-Object { $_ -is [System.Collections.IDictionary] -and $_['componentName'] -eq 'VCF Operations' })
    if (-not $ops.Count) { throw "'$Path' has no VCF Operations entry." }
    if ($ops.Count -gt 1) {
        $named = @($ops | Where-Object { $Fqdn -and (& $hostOf $_['FQDN']) -ieq $Fqdn })
        if ($named.Count -ne 1) {
            $hosts = ($ops | ForEach-Object { & $hostOf $_['FQDN'] }) -join ', '
            throw "'$Path' lists $($ops.Count) VCF Operations ($hosts); choose one with -Fqdn."
        }
        $ops = $named
    }

    $component = $ops[0]
    $hostName = & $hostOf $component['FQDN']
    $admin = @($component['credentials'] | Where-Object { $_ -is [System.Collections.IDictionary] -and $_['type'] -eq 'Administrator credentials' })
    if (-not $admin.Count -or -not $admin[0]['user'] -or -not $admin[0]['password']) {
        throw "'$Path' has no Administrator credentials for VCF Operations at '$hostName'."
    }
    @{
        Fqdn     = $hostName
        Username = [string]$admin[0]['user']
        Password = ConvertTo-SecureString -String ([string]$admin[0]['password']) -AsPlainText -Force
    }
}
