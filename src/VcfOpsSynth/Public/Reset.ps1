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

function Invoke-SynthSsh {
    <#
    .SYNOPSIS
        Runs one command on a host over SSH with key authentication only, and returns its exit code and output.

    .DESCRIPTION
        BatchMode stops ssh asking for a password, so a missing key fails at once
        instead of hanging. A host seen for the first time is added to known_hosts.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][string]$Target,
        [Parameter(Mandatory)][string]$Command,
        [string]$IdentityFile
    )
    $sshArgs = @('-o', 'BatchMode=yes', '-o', 'StrictHostKeyChecking=accept-new', '-o', 'ConnectTimeout=15')
    if ($IdentityFile) { $sshArgs += @('-i', $IdentityFile) }
    $output = & ssh @sshArgs $Target $Command 2>&1
    [pscustomobject]@{ ExitCode = $LASTEXITCODE; Output = (@($output | ForEach-Object { "$_" }) -join "`n").Trim() }
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
        Dashboards are deleted for all users. Signs in with a key only, never a
        password.

    .PARAMETER Prefix
        The content prefix (lab.json prefix). It must not be empty.

    .PARAMETER SshTarget
        user@host of the appliance, for example root@ops-a.example.local.

    .PARAMETER IdentityFile
        The private key; without it ssh uses its defaults.

    .PARAMETER OpsCli
        The remote command that runs ops-cli, before its arguments.
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$Prefix,
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$SshTarget,
        [string]$IdentityFile,
        [string]$OpsCli = '. /etc/profile >/dev/null 2>&1; cd /usr/lib/vmware-vcops/tools/opscli && $VMWARE_PYTHON_BIN ./ops-cli.py'
    )

    $names = Get-SynthContentName -Prefix $Prefix
    $quote = { param($s) "'" + $s.Replace("'", "'\''") + "'" }
    $items = @(
        foreach ($n in $names.View) { @{ Kind = 'view'; Name = $n; Args = "view delete $(& $quote $n)" } }
        foreach ($n in $names.Report) { @{ Kind = 'report'; Name = $n; Args = "report delete $(& $quote $n)" } }
        foreach ($n in $names.Dashboard) { @{ Kind = 'dashboard'; Name = $n; Args = "dashboard delete all $(& $quote $n)" } }
    )
    foreach ($item in $items) {
        $result = [pscustomobject]@{ Kind = $item.Kind; Name = $item.Name; Action = ''; Error = $null }
        if (-not $item.Name.StartsWith($Prefix, [StringComparison]::Ordinal) -or $item.Name.StartsWith('-') -or $item.Name.Contains(',')) {
            $result.Action = 'refused'; $result.Error = 'The name must start with the prefix and hold no comma.'; $result; continue
        }
        if (-not $PSCmdlet.ShouldProcess($item.Name, "Delete $($item.Kind) with ops-cli on $SshTarget")) { $result.Action = 'would delete'; $result; continue }
        $run = Invoke-SynthSsh -Target $SshTarget -IdentityFile $IdentityFile -Command "$OpsCli $($item.Args)"
        # An item already gone counts as done, so a second reset runs clean.
        if ($run.Output -match '(?i)not (found|exist)|does ?n.t exist|no such') { $result.Action = 'not there' }
        elseif ($run.ExitCode -eq 0 -and $run.Output -notmatch '(?i)\b(error|fail(ed|ure)?|exception)\b') { $result.Action = 'deleted' }
        else { $result.Action = 'failed'; $result.Error = "exit $($run.ExitCode): $($run.Output)" }
        $result
    }
}
