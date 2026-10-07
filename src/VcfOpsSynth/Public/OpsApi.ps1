function Connect-SynthOps {
    <#
    .SYNOPSIS
        Acquires a VCF Operations API token and keeps it for later Suite API calls.

    .DESCRIPTION
        Posts to /suite-api/api/auth/token/acquire, the same call as
        Get-VropsAccessToken in adms-infra-automation's Vcf-ApiHelpers.psm1, but
        keeps the token in memory for this session instead of a temp file, because
        the container is short-lived and should leave nothing behind.

    .PARAMETER Config
        Settings from Get-SynthConfig.

    .PARAMETER Password
        Overrides the password from VCFOPS_PASSWORD or VCFOPS_PASSWORD_FILE.

    .EXAMPLE
        Connect-SynthOps -Config (Get-SynthConfig)
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '', Justification = 'Ops is the product name, VCF Operations, not a plural.')]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$Config,
        [securestring]$Password
    )

    if (-not $Password) { $Password = Get-SynthSecret }
    if (-not $Password) {
        throw 'No Operations password was supplied. Set VCFOPS_PASSWORD, or VCFOPS_PASSWORD_FILE for a Docker secret.'
    }

    $ops = $Config.operations
    $baseUri = "https://$($ops.fqdn)/suite-api"
    $body = [ordered]@{
        username   = $ops.username
        password   = (ConvertFrom-SecureString -SecureString $Password -AsPlainText)
        authSource = $ops.authSource
    } | ConvertTo-Json -Compress

    $request = @{
        Uri                  = "$baseUri/api/auth/token/acquire"
        Method               = 'Post'
        ContentType          = 'application/json'
        Headers              = @{ Accept = 'application/json' }
        Body                 = $body
        TimeoutSec           = $ops.timeoutSeconds
        SkipCertificateCheck = [bool]$ops.skipCertificateCheck
    }
    try {
        $response = Invoke-RestMethod @request
    }
    catch {
        throw "Could not sign in to VCF Operations at $($ops.fqdn) as $($ops.username) ($($ops.authSource)): $($_.Exception.Message)"
    }
    # Read optional fields through PSObject so StrictMode does not throw when the server leaves one out.
    $token = $response.PSObject.Properties['token']
    $validity = $response.PSObject.Properties['validity']
    if (-not $token -or -not $token.Value) {
        throw "VCF Operations at $($ops.fqdn) answered the sign-in without a token."
    }

    $script:OpsSession = [pscustomobject]@{
        BaseUri              = $baseUri
        Token                = $token.Value
        Expires              = if ($validity -and $validity.Value) { [DateTimeOffset]::FromUnixTimeMilliseconds([long]$validity.Value) } else { $null }
        TimeoutSec           = $ops.timeoutSeconds
        SkipCertificateCheck = [bool]$ops.skipCertificateCheck
        Config               = $Config
        Password             = $Password
    }
    $script:OpsSession | Select-Object BaseUri, Expires
}

function Disconnect-SynthOps {
    <#
    .SYNOPSIS
        Releases the current token on the server and forgets it locally.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '', Justification = 'Ops is the product name, VCF Operations, not a plural.')]
    [CmdletBinding(SupportsShouldProcess)]
    param()

    if (-not $script:OpsSession) { return }
    if ($PSCmdlet.ShouldProcess($script:OpsSession.BaseUri, 'Release API token')) {
        try {
            $null = Invoke-SynthOpsRequest -Method Post -Path 'auth/token/release' -NoRetry
        }
        catch {
            Write-Verbose "Token release failed and is ignored: $($_.Exception.Message)"
        }
    }
    $script:OpsSession = $null
}

function Invoke-SynthOpsRequest {
    <#
    .SYNOPSIS
        Calls a Suite API path with the current token, retrying when Operations is busy.

    .DESCRIPTION
        Path is relative to /suite-api/api, for example 'resources' or
        'resources/stats/adapterkinds/VcfOpsSynth'. Bodies are sent as JSON.

        HTTP 429 and 5xx answers are retried up to MaxRetries times with
        exponential backoff (2, 4, 8, 16 seconds), honouring Retry-After when the
        server sends it. A 401 signs in again once, since tokens expire during
        long backfills.

    .PARAMETER Method
        HTTP method.

    .PARAMETER Path
        Path under /suite-api/api, without a leading slash.

    .PARAMETER Query
        Query string values, URL-encoded here.

    .PARAMETER Body
        An object serialised to JSON, or a JSON string sent as is.

    .PARAMETER MaxRetries
        Retries after the first attempt for 429 and 5xx answers. Defaults to 4.

    .PARAMETER NoRetry
        Makes a single attempt; used where a failure does not matter.

    .EXAMPLE
        Invoke-SynthOpsRequest -Method Get -Path 'adapterkinds'
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateSet('Get', 'Post', 'Put', 'Patch', 'Delete')][string]$Method,
        [Parameter(Mandatory)][string]$Path,
        [hashtable]$Query,
        $Body,
        [ValidateRange(0, 10)][int]$MaxRetries = 4,
        [switch]$NoRetry
    )

    if (-not $script:OpsSession) { throw 'Not signed in to VCF Operations; run Connect-SynthOps first.' }
    if ($NoRetry) { $MaxRetries = 0 }

    $uri = "$($script:OpsSession.BaseUri)/api/$($Path.TrimStart('/'))"
    if ($Query -and $Query.Count -gt 0) {
        $pairs = foreach ($key in ($Query.Keys | Sort-Object)) {
            '{0}={1}' -f [uri]::EscapeDataString([string]$key), [uri]::EscapeDataString([string]$Query[$key])
        }
        $uri = "${uri}?$($pairs -join '&')"
    }

    $json = $null
    if ($null -ne $Body) {
        $json = if ($Body -is [string]) { $Body } else { $Body | ConvertTo-Json -Depth 20 -Compress }
    }

    $reauthenticated = $false
    $attempt = 0
    while ($true) {
        $request = @{
            Uri                  = $uri
            Method               = $Method
            Headers              = @{ Accept = 'application/json'; Authorization = "OpsToken $($script:OpsSession.Token)" }
            TimeoutSec           = $script:OpsSession.TimeoutSec
            SkipCertificateCheck = $script:OpsSession.SkipCertificateCheck
        }
        if ($null -ne $json) {
            $request.ContentType = 'application/json'
            $request.Body = $json
        }

        try {
            return Invoke-RestMethod @request
        }
        catch {
            $status = Get-SynthHttpStatus -ErrorRecord $_
            if ($status -eq 401 -and -not $reauthenticated) {
                $reauthenticated = $true
                Write-Verbose 'Token rejected; signing in again.'
                $null = Connect-SynthOps -Config $script:OpsSession.Config -Password $script:OpsSession.Password
                continue
            }
            $retryable = $status -eq 429 -or ($status -ge 500 -and $status -le 599)
            if (-not $retryable -or $attempt -ge $MaxRetries) {
                throw "VCF Operations $Method $Path failed$(if ($status) { " with HTTP $status" }): $($_.Exception.Message)"
            }
            $attempt++
            $delay = Get-SynthRetryDelay -ErrorRecord $_ -Attempt $attempt
            Write-Verbose "HTTP $status from $Method $Path; retry $attempt of $MaxRetries in $delay s."
            Start-Sleep -Seconds $delay
        }
    }
}

function Get-SynthOpsVersion {
    <#
    .SYNOPSIS
        Returns the VCF Operations version, as a quick proof that sign-in and the API work.
    #>
    [CmdletBinding()]
    param()

    Invoke-SynthOpsRequest -Method Get -Path 'versions/current'
}
