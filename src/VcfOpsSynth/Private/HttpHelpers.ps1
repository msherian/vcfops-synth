function Get-SynthHttpStatus {
    <#
    .SYNOPSIS
        Pulls the HTTP status code out of an Invoke-RestMethod error, or 0 when there is none.
    #>
    [CmdletBinding()]
    [OutputType([int])]
    param([Parameter(Mandatory)][System.Management.Automation.ErrorRecord]$ErrorRecord)

    $response = $ErrorRecord.Exception.PSObject.Properties['Response']
    if ($response -and $response.Value -and $response.Value.PSObject.Properties['StatusCode']) {
        return [int]$response.Value.StatusCode
    }
    $statusProperty = $ErrorRecord.Exception.PSObject.Properties['StatusCode']
    if ($statusProperty -and $statusProperty.Value) { return [int]$statusProperty.Value }
    0
}

function Get-SynthRetryDelay {
    <#
    .SYNOPSIS
        Seconds to wait before a retry: Retry-After when the server gives it, else 2, 4, 8, 16 and so on, capped at 60.
    #>
    [CmdletBinding()]
    [OutputType([int])]
    param(
        [Parameter(Mandatory)][System.Management.Automation.ErrorRecord]$ErrorRecord,
        [Parameter(Mandatory)][int]$Attempt
    )

    $response = $ErrorRecord.Exception.PSObject.Properties['Response']
    if ($response -and $response.Value -and $response.Value.PSObject.Properties['Headers']) {
        $retryAfter = $response.Value.Headers.RetryAfter
        if ($retryAfter -and $retryAfter.Delta) {
            return [int][math]::Min(60, [math]::Ceiling($retryAfter.Delta.TotalSeconds))
        }
    }
    [int][math]::Min(60, [math]::Pow(2, $Attempt))
}
