function Get-SynthResourceProperty {
    <#
    .SYNOPSIS
        The latest value of one property for many resources, keyed by resource ID.

    .DESCRIPTION
        Asks for 100 resources per call (GET resources/properties with one
        resourceId per resource). A resource without the property is left out.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$Id,
        [Parameter(Mandatory)][string]$Key
    )
    $values = @{}
    for ($i = 0; $i -lt $Id.Count; $i += 100) {
        $batch = $Id[$i..([Math]::Min($i + 99, $Id.Count - 1))]
        $query = ($batch | ForEach-Object { 'resourceId=' + [uri]::EscapeDataString($_) }) -join '&'
        $r = Invoke-SynthOpsRequest -Method Get -Path "resources/properties?$query"
        foreach ($entry in @(Get-SynthResponseField $r 'resourcePropertiesList' | Where-Object { $null -ne $_ })) {
            foreach ($p in @(Get-SynthResponseField $entry 'property' | Where-Object { $null -ne $_ })) {
                if ((Get-SynthResponseField $p 'name') -eq $Key) { $values[[string](Get-SynthResponseField $entry 'resourceId')] = [string](Get-SynthResponseField $p 'value') }
            }
        }
    }
    $values
}

function Get-SynthSeededObject {
    <#
    .SYNOPSIS
        The planned objects that exist in Operations, each with whether it carries the synthetic tag.

    .DESCRIPTION
        Objects are found as seed finds them, by kind and unique identifier
        (never by name), then their summary|tag property is read. Only an
        object whose tag holds the synthetic marker is one the toolset made;
        anything else with a matching identifier is reported as untagged and
        left alone. Children come before parents (VMs first, the Physical
        Datacenter last), the order they can be removed in.

    .PARAMETER Plan
        A plan from New-SynthSeedPlan.

    .PARAMETER AdapterInstanceId
        The vCenter adapter instance the VMWARE objects sit under.

    .PARAMETER Tag
        The synthetic marker as summary|tag shows it, Category-Name (lab.json seed.tag).
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$Plan,
        [Parameter(Mandatory)][string]$AdapterInstanceId,
        [string]$Tag = 'vcfops-synth-synthetic'
    )
    $kinds = @(Get-SynthSeedKind)
    [array]::Reverse($kinds)
    $found = foreach ($kind in $kinds) {
        $ofKind = @($Plan.objects | Where-Object { $_.kind -eq $kind })
        if (-not $ofKind.Count) { continue }
        $adapterKind = if ($ofKind[0].Contains('adapterKind') -and $ofKind[0].adapterKind) { $ofKind[0].adapterKind } else { 'VMWARE' }
        $lookup = @{ Kind = $kind; AdapterKind = $adapterKind }
        if ($adapterKind -eq 'VMWARE') { $lookup.AdapterInstanceId = $AdapterInstanceId }
        $unique = @($ofKind[0].identifiers | Where-Object { $_.unique })
        if ($unique.Count) { $lookup.IdentifierName = $unique[0].name }
        $existing = Get-SynthExistingResource @lookup
        foreach ($object in $ofKind) {
            $match = $existing[(Get-SynthSeedUniqueKey -Object $object)]
            if ($match) { [pscustomobject]@{ Kind = $kind; Key = $object.key; Id = [string]$match.id; Name = $match.name; Tagged = $false } }
        }
    }
    $found = @($found)
    if (-not $found.Count) { return }
    $tags = Get-SynthResourceProperty -Id @($found | ForEach-Object Id) -Key 'summary|tag'
    $marker = [regex]::new('(^|[\[,]\s*)' + [regex]::Escape($Tag) + '\s*($|[\],])')
    foreach ($o in $found) {
        $o.Tagged = $tags.ContainsKey($o.Id) -and $marker.IsMatch($tags[$o.Id])
        $o
    }
}

function Remove-SynthSeededObject {
    <#
    .SYNOPSIS
        Deletes the objects seed created, children first; an object without the synthetic tag is never deleted.

    .PARAMETER Object
        From Get-SynthSeededObject, in its order.
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
    [OutputType([pscustomobject])]
    param([Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Object)

    foreach ($o in $Object) {
        $result = [pscustomobject]@{ Kind = $o.Kind; Key = $o.Key; Id = $o.Id; Action = ''; Error = $null }
        if (-not $o.Tagged) { $result.Action = 'untagged'; $result; continue }
        if (-not $PSCmdlet.ShouldProcess("$($o.Kind) $($o.Id)", 'Delete')) { $result.Action = 'would delete'; $result; continue }
        try {
            $null = Invoke-SynthOpsRequest -Method Delete -Path "resources/$($o.Id)"
            $result.Action = 'deleted'
        }
        catch { $result.Action = 'failed'; $result.Error = $_.Exception.Message }
        $result
    }
}

function Remove-SynthContent {
    <#
    .SYNOPSIS
        Deletes the toolset's policies, alerts, symptoms, recommendations, super metrics and custom groups, by the content prefix.

    .DESCRIPTION
        Policies go first, since they switch alerts on and are assigned to the
        groups; the tier policies go before <prefix>Base, which they inherit.
        Alerts go next, since they refer to symptoms and recommendations.
        Only items whose names (a recommendation's text) start with the prefix
        are touched. Views, reports and dashboards cannot be deleted through
        the API; Remove-SynthApplianceContent deletes them with ops-cli.

    .PARAMETER Prefix
        The content prefix (lab.json prefix). It must not be empty.
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
    [OutputType([pscustomobject])]
    param([Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$Prefix)

    $lists = @(
        @{ Kind = 'policy'; Path = 'policies'; Property = 'policySummaries'; Name = { $_.name } }
        @{ Kind = 'alert'; Path = 'alertdefinitions'; Property = 'alertDefinitions'; Name = { $_.name } }
        @{ Kind = 'symptom'; Path = 'symptomdefinitions'; Property = 'symptomDefinitions'; Name = { $_.name } }
        @{ Kind = 'recommendation'; Path = 'recommendations'; Property = 'recommendations'; Name = { $_.description } }
        @{ Kind = 'super metric'; Path = 'supermetrics'; Property = 'superMetrics'; Name = { $_.name } }
        @{ Kind = 'custom group'; Path = 'resources/groups'; Property = 'groups'; Name = { $_.resourceKey.name } }
    )
    foreach ($list in $lists) {
        # The base policy last, after the policies that inherit it.
        $items = @(Get-SynthPagedList -Path $list.Path -Property $list.Property | Sort-Object { [string](ForEach-Object -InputObject $_ -Process $list.Name) -eq "${Prefix}Base" })
        foreach ($item in $items) {
            $name = [string](ForEach-Object -InputObject $item -Process $list.Name)
            if (-not $name.StartsWith($Prefix, [StringComparison]::Ordinal)) { continue }
            $id = [string]$item.id
            $result = [pscustomobject]@{ Kind = $list.Kind; Name = $name; Id = $id; Action = ''; Error = $null }
            if (-not $PSCmdlet.ShouldProcess($name, "Delete $($list.Kind)")) { $result.Action = 'would delete'; $result; continue }
            try {
                $null = Invoke-SynthOpsRequest -Method Delete -Path "$($list.Path)/$id"
                $result.Action = 'deleted'
            }
            catch { $result.Action = 'failed'; $result.Error = $_.Exception.Message }
            $result
        }
    }
}

function Clear-SynthState {
    <#
    .SYNOPSIS
        Forgets the backfill progress, the feed's last push and the running scenarios, after a reset.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return }
    $all = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json -AsHashtable
    if (-not $all) { return }
    foreach ($section in 'backfill', 'feed', 'scenarios') { $all.Remove($section) }
    if ($PSCmdlet.ShouldProcess($Path, 'Clear backfill, feed and scenario state')) {
        $temp = "$Path.tmp"
        $all | ConvertTo-Json -Depth 8 -Compress | Set-Content -LiteralPath $temp -Encoding utf8
        Move-Item -LiteralPath $temp -Destination $Path -Force
    }
}

function Get-SynthContentName {
    <#
    .SYNOPSIS
        The names of the views, reports and dashboards the content command publishes.

    .DESCRIPTION
        Built from the same definitions content uses, so reset can delete them by
        exact name: neither the API nor ops-cli can list them.

    .PARAMETER Prefix
        The content prefix (lab.json prefix).
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$Prefix)

    $content = Get-SynthViewContent -Prefix $Prefix
    [pscustomobject]@{
        View      = @($content.Views | ForEach-Object { [string]$_.Name })
        Report    = @($content.Reports | ForEach-Object { [string]$_.Name })
        Dashboard = @(Get-SynthDashboardContent -Prefix $Prefix | ForEach-Object { [string]$_.Name })
    }
}

function Save-SynthContentDeletePayload {
    <#
    .SYNOPSIS
        Writes the names of the toolset's views, reports and dashboards to a JSON file for bin/ops-content-delete.py.

    .DESCRIPTION
        For when reset cannot reach the appliance over SSH: copy the file and the
        script to the appliance and run the script there; it deletes each name
        with ops-cli. The names come from Get-SynthContentName.

    .PARAMETER Prefix
        The content prefix (lab.json prefix). It must not be empty.

    .PARAMETER Path
        The JSON file to write.

    .PARAMETER Owner
        The user content imported the dashboards as; they are deleted for that user. Without it, for all users.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$Prefix,
        [Parameter(Mandatory)][string]$Path,
        [string]$Owner
    )
    $names = Get-SynthContentName -Prefix $Prefix
    $payload = [ordered]@{ prefix = $Prefix; owner = $Owner; view = @($names.View); report = @($names.Report); dashboard = @($names.Dashboard) }
    if ($PSCmdlet.ShouldProcess($Path, 'Write content delete payload')) {
        $payload | ConvertTo-Json -Depth 3 | Set-Content -LiteralPath $Path -Encoding utf8NoBOM
    }
    $Path
}

function Invoke-SynthSsh {
    <#
    .SYNOPSIS
        Runs one command on a host over SSH, and returns its exit code and output.

    .DESCRIPTION
        Without -Interactive, BatchMode stops ssh asking for a password, so a
        missing key fails at once instead of hanging. With -Interactive, ssh may
        ask for a password on the terminal itself; the password never passes
        through PowerShell. A host seen for the first time is added to known_hosts.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][string]$Target,
        [Parameter(Mandatory)][string]$Command,
        [string]$IdentityFile,
        [switch]$Interactive
    )
    $sshArgs = @('-o', 'StrictHostKeyChecking=accept-new', '-o', 'ConnectTimeout=15')
    if (-not $Interactive) { $sshArgs += @('-o', 'BatchMode=yes') }
    if ($IdentityFile) { $sshArgs += @('-i', $IdentityFile) }
    $output = & ssh @sshArgs $Target $Command 2>&1
    [pscustomobject]@{ ExitCode = $LASTEXITCODE; Output = (@($output | ForEach-Object { "$_" }) -join "`n").Trim() }
}

function Test-SynthTerminal {
    <#
    .SYNOPSIS
        True when ssh can ask for a password: a console on Windows, a /dev/tty that opens elsewhere (docker run -t).
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param()
    if ($IsWindows) { return -not [Console]::IsInputRedirected }
    try { [IO.File]::Open('/dev/tty', 'Open', 'ReadWrite').Dispose(); $true } catch { $false }
}

function Resolve-SynthSshKey {
    <#
    .SYNOPSIS
        The private key for -ApplianceSsh: the one given, else the container's key mount when it holds a file.

    .PARAMETER SshKey
        -SshKey or VCFOPS_SYNTH_SSH_KEY.

    .PARAMETER Default
        The key mount (docker run -v ~/.ssh/id_ed25519:/keys/id_ssh:ro).
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([string]$SshKey, [string]$Default = '/keys/id_ssh')
    if ($SshKey) { return $SshKey }
    if (Test-Path -LiteralPath $Default -PathType Leaf) { return $Default }
    $null
}

function Remove-SynthApplianceContent {
    <#
    .SYNOPSIS
        Deletes the toolset's views, reports and dashboards on the VCF Operations appliance with ops-cli, over SSH.

    .DESCRIPTION
        The API cannot delete views, dashboards or report definitions, but ops-cli
        on the appliance can, by exact name. Each name comes from the toolset's own
        definitions (Get-SynthContentName) and must start with the prefix. A name
        that is empty, starts with '-' (ops-cli's -all deletes every item, the
        built-in ones too) or holds a comma (ops-cli's name separator) is refused.

        All deletes run in one SSH session: bin/ops-content-delete.py and the
        names are sent with the command and run on the appliance, which applies
        the same guards and deletes dashboards for -Owner (for all users without
        it). Sign-in tries the
        key first; if the appliance refuses it, ssh asks for the password on the
        terminal, once. The password never passes through PowerShell.

    .PARAMETER Prefix
        The content prefix (lab.json prefix). It must not be empty.

    .PARAMETER SshTarget
        user@host of the appliance, for example root@ops-a.example.local.

    .PARAMETER IdentityFile
        The private key; without it ssh uses its defaults.

    .PARAMETER Owner
        The user content imported the dashboards as; they are deleted for that user. Without it, for all users.

    .PARAMETER Script
        bin/ops-content-delete.py, which runs on the appliance.
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$Prefix,
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$SshTarget,
        [string]$IdentityFile,
        [string]$Owner,
        [string]$Script = (Join-Path $PSScriptRoot '../../../bin/ops-content-delete.py')
    )

    $names = Get-SynthContentName -Prefix $Prefix
    $send = [ordered]@{ prefix = $Prefix; owner = $Owner; view = @(); report = @(); dashboard = @() }
    $sent = [System.Collections.Generic.List[object]]::new()
    # Reports and dashboards before the views they use: ops-cli will not delete a view a report still uses.
    foreach ($kind in 'Report', 'Dashboard', 'View') {
        foreach ($name in $names.$kind) {
            $result = [pscustomobject]@{ Kind = $kind.ToLowerInvariant(); Name = $name; Action = ''; Error = $null }
            if (-not $name.StartsWith($Prefix, [StringComparison]::Ordinal) -or $name.StartsWith('-') -or $name.Contains(',')) {
                $result.Action = 'refused'; $result.Error = 'The name must start with the prefix and hold no comma.'; $result; continue
            }
            if (-not $PSCmdlet.ShouldProcess($name, "Delete $($result.Kind) with ops-cli on $SshTarget")) { $result.Action = 'would delete'; $result; continue }
            $send[$result.Kind] += $name
            $sent.Add($result)
        }
    }
    if (-not $sent.Count) { return }

    $b64 = { param([string]$text) [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($text)) }
    $code = & $b64 ((Get-Content -LiteralPath $Script -Raw) -replace "`r`n", "`n")
    $payload = & $b64 ($send | ConvertTo-Json -Depth 3 -Compress)
    $command = ". /etc/profile >/dev/null 2>&1; t=`$(mktemp -d) && echo $code | base64 -d > `$t/d.py && echo $payload | base64 -d > `$t/p.json && `${VMWARE_PYTHON_BIN:-python3} `$t/d.py `$t/p.json --apply --jsonl; rc=`$?; rm -rf `$t; exit `$rc"

    $run = Invoke-SynthSsh -Target $SshTarget -IdentityFile $IdentityFile -Command $command
    # No usable key: let ssh ask for the password on the terminal, if there is one.
    if ($run.ExitCode -eq 255 -and $run.Output -match 'Permission denied') {
        if (-not (Test-SynthTerminal)) {
            $run = [pscustomobject]@{ ExitCode = 255; Output = "$SshTarget did not accept the SSH key, and there is no terminal to ask for the password. Run the container with -it, or with -dit and then docker attach <name>." }
        }
        else {
            Write-Host "SSH key not accepted by $SshTarget; ssh asks for the appliance password. If the container is detached: docker attach <name> (detach again with Ctrl-P Ctrl-Q)."
            $run = Invoke-SynthSsh -Target $SshTarget -IdentityFile $IdentityFile -Command $command -Interactive
        }
    }
    $byName = @{}
    foreach ($line in ($run.Output -split "`n")) {
        if (-not $line.StartsWith('{')) { continue }
        try { $item = $line | ConvertFrom-Json } catch { continue }
        $byName["$($item.kind)|$($item.name)"] = $item
    }
    foreach ($result in $sent) {
        $item = $byName["$($result.Kind)|$($result.Name)"]
        if ($item) { $result.Action = $item.action; $result.Error = $item.error }
        else { $result.Action = 'failed'; $result.Error = "exit $($run.ExitCode): $($run.Output)" }
        $result
    }
}
