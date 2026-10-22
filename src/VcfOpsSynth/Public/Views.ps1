function Get-SynthContentId {
    <#
    .SYNOPSIS
        A stable GUID for a piece of bundled content, from its kind and name, so every build of a bundle carries the same ids.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string]$Kind,
        [Parameter(Mandatory)][string]$Name
    )

    $md5 = [System.Security.Cryptography.MD5]::Create()
    try { $bytes = $md5.ComputeHash([System.Text.Encoding]::UTF8.GetBytes("vcfops-synth:${Kind}:$Name")) }
    finally { $md5.Dispose() }
    ([guid]::new($bytes)).ToString()
}

function Get-SynthViewContent {
    <#
    .SYNOPSIS
        The list views and reports the toolset publishes through a content bundle.

    .DESCRIPTION
        Views: the VM tier list (tier, application, size and the week's CPU,
        ready, memory and disk latency), oversized and undersized VMs (on the
        summary|oversized and summary|undersized flags Operations sets), VM
        configuration hygiene (VMware Tools, hardware version, snapshots) and
        cluster tier pressure (usage, the worst VM CPU ready and disk latency
        super metrics, capacity and time remaining).

        Reports: the weekly tier compliance report (tier list and cluster
        pressure) and the rightsizing report (oversized and undersized lists),
        each with a cover page, as PDF and CSV.

        Super metric columns are added only for super metrics whose ids are known,
        since a view refers to a super metric by id.

    .PARAMETER Prefix
        The content prefix (lab.json prefix).

    .PARAMETER SuperMetricId
        Super metric name to id, from Publish-SynthAlertContent.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [string]$Prefix = 'Synth-',
        [hashtable]$SuperMetricId = @{}
    )

    $vm = @{ AdapterKind = 'VMWARE'; ResourceKind = 'VirtualMachine' }
    $cluster = @{ AdapterKind = 'VMWARE'; ResourceKind = 'ClusterComputeResource' }
    # A column: attribute key, heading, transform over the view's time range, unit, property or metric, text or number.
    $col = { param($key, $name, $transform = 'CURRENT', $unit = $null, [bool]$property = $false, [bool]$text = $false) @{ Key = $key; Name = $name; Transform = $transform; Unit = $unit; Property = $property; String = $text } }
    $prop = { param($key, $name, $unit = $null) & $col $key $name 'CURRENT' $unit $true $false }
    $text = { param($key, $name) & $col $key $name 'CURRENT' $null $true $true }
    $flag = { param($key) @{ Key = $key; Condition = 'EQUALS'; Value = 1; Type = 'metrics' } }
    $smIds = $SuperMetricId
    $super = { param($name, $heading, $transform) if ($smIds.ContainsKey("$Prefix$name")) { & $col "Super Metric|sm_$($smIds["$Prefix$name"])" $heading $transform } }

    $views = @(
        $vm + @{ Name = "${Prefix}VM tier list"; Days = 7; Filter = @()
            Description = 'Each VM with its service tier and application, its size, and its CPU, ready time, memory and disk latency over the last week.'
            Columns = @(
                (& $text 'vcfops-synth|tier' 'Tier')
                (& $text 'vcfops-synth|application' 'Application')
                (& $text 'summary|parentCluster' 'Cluster')
                (& $prop 'config|hardware|numCpu' 'vCPUs')
                (& $prop 'config|hardware|memoryKB' 'Memory (GB)' 'gb')
                (& $col 'cpu|usage_average' 'CPU usage (%, avg)' 'AVG')
                (& $col 'cpu|readyPct' 'CPU ready (%, max)' 'MAX')
                (& $col 'mem|usage_average' 'Memory usage (%, avg)' 'AVG')
                (& $col 'virtualDisk:Aggregate of all instances|totalReadLatency_average' 'Disk read latency (ms, max)' 'MAX')
                (& $super 'VM CPU demand over allocation' 'CPU demand over allocation (%, avg)' 'AVG')
            ) }
        $vm + @{ Name = "${Prefix}Oversized VMs"; Days = 30; Filter = @(& $flag 'summary|oversized')
            Description = 'VMs Operations marks as oversized: they use much less CPU or memory than they are given. Reclaim the difference.'
            Columns = @(
                (& $text 'vcfops-synth|tier' 'Tier')
                (& $text 'summary|parentCluster' 'Cluster')
                (& $prop 'config|hardware|numCpu' 'vCPUs')
                (& $prop 'config|hardware|memoryKB' 'Memory (GB)' 'gb')
                (& $col 'cpu|usage_average' 'CPU usage (%, avg)' 'AVG')
                (& $col 'mem|usage_average' 'Memory usage (%, avg)' 'AVG')
                (& $super 'VM CPU demand over allocation' 'CPU demand over allocation (%, avg)' 'AVG')
            ) }
        $vm + @{ Name = "${Prefix}Undersized VMs"; Days = 30; Filter = @(& $flag 'summary|undersized')
            Description = 'VMs Operations marks as undersized: they need more CPU or memory than they are given.'
            Columns = @(
                (& $text 'vcfops-synth|tier' 'Tier')
                (& $text 'summary|parentCluster' 'Cluster')
                (& $prop 'config|hardware|numCpu' 'vCPUs')
                (& $prop 'config|hardware|memoryKB' 'Memory (GB)' 'gb')
                (& $col 'cpu|usage_average' 'CPU usage (%, max)' 'MAX')
                (& $col 'cpu|readyPct' 'CPU ready (%, max)' 'MAX')
                (& $col 'mem|usage_average' 'Memory usage (%, max)' 'MAX')
            ) }
        $vm + @{ Name = "${Prefix}VM configuration hygiene"; Days = 1; Filter = @()
            Description = 'VMware Tools state, virtual hardware version, guest OS and snapshot space for each VM, to find drift from the build standard.'
            Columns = @(
                (& $text 'vcfops-synth|tier' 'Tier')
                (& $text 'summary|guest|toolsRunningStatus' 'VMware Tools running')
                (& $text 'summary|guest|toolsVersionStatus2' 'VMware Tools version')
                (& $text 'config|version' 'Hardware version')
                (& $text 'summary|guest|fullName' 'Guest OS')
                (& $col 'diskspace|snapshot' 'Snapshot space (GB)' 'CURRENT' 'gb')
            ) }
        $cluster + @{ Name = "${Prefix}Cluster tier pressure"; Days = 7; Filter = @()
            Description = 'Each cluster''s CPU and memory use over the last week, the worst CPU ready time and disk latency of its VMs, and its capacity and time remaining.'
            Columns = @(
                (& $col 'cpu|usage_average' 'CPU usage (%, avg)' 'AVG')
                (& $col 'mem|usage_average' 'Memory usage (%, avg)' 'AVG')
                (& $super 'Cluster worst VM CPU ready' 'Worst VM CPU ready (%, max)' 'MAX')
                (& $super 'Cluster worst VM disk latency' 'Worst VM disk latency (ms, max)' 'MAX')
                (& $col 'OnlineCapacityAnalytics|capacityRemainingPercentage' 'Capacity remaining (%)')
                (& $col 'OnlineCapacityAnalytics|timeRemaining' 'Time remaining (days)')
            ) }
    )
    foreach ($v in $views) { $v.Columns = @($v.Columns | Where-Object { $_ }) }

    $reports = @(
        @{ Name = "${Prefix}Weekly tier compliance"; Description = 'Each VM against its service tier, and the clusters under the most pressure, over the last week.'
            Views = @("${Prefix}VM tier list", "${Prefix}Cluster tier pressure") }
        @{ Name = "${Prefix}Rightsizing"; Description = 'Oversized VMs to reclaim from, and undersized VMs to grow.'
            Views = @("${Prefix}Oversized VMs", "${Prefix}Undersized VMs") }
    )

    @{ Views = $views; Reports = $reports }
}

function ConvertTo-SynthViewXml {
    <#
    .SYNOPSIS
        One list view as a ViewDef element, in the shape of a VCF Operations 9.1 content export.

    .OUTPUTS
        A hashtable with Id, Xml (the ViewDef element) and Properties (its localisation lines).
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Definition)

    $e = { param($s) [System.Security.SecurityElement]::Escape([string]$s) }
    $id = Get-SynthContentId -Kind 'view' -Name $Definition.Name
    $lower = { param($b) ([string][bool]$b).ToLowerInvariant() }

    $subject = ''
    $filter = ''
    if (@($Definition.Filter).Count) {
        $conditions = @(foreach ($c in $Definition.Filter) {
                $f = [ordered]@{ condition = $c.Condition; transform = 'CURRENT'; metricKey = $c.Key; metricValue = [ordered]@{ isStringMetric = ($c.Value -is [string]); value = $c.Value } }
                if ($c.Type -eq 'metrics') { $f.businessHours = $false }
                $f.filterType = $c.Type
                $f
            })
        # An array of OR groups, each an array of conditions that must all hold.
        $filter = ' filter="{0}"' -f (& $e (ConvertTo-Json -InputObject @(, $conditions) -Depth 6 -Compress))
    }
    foreach ($type in 'descendant', 'self') {
        $subject += '<SubjectType adapterKind="{0}"{1} resourceKind="{2}" type="{3}" />' -f (& $e $Definition.AdapterKind), $filter, (& $e $Definition.ResourceKind), $type
    }

    $n = 0
    $items = foreach ($c in $Definition.Columns) {
        $n++
        $unit = if ($c.Unit) { '<Property name="preferredUnitId" value="{0}" />' -f (& $e $c.Unit) } else { '' }
        ('<Item><Value><Property name="objectType" value="RESOURCE" /><Property name="attributeKey" value="{0}" /><Property name="id" value="synth-col-{1}" />{2}' +
            '<Property name="isStringAttribute" value="{3}" /><Property name="adapterKind" value="{4}" /><Property name="resourceKind" value="{5}" />' +
            '<Property name="rollUpType" value="NONE" /><Property name="rollUpCount" value="0" /><Property name="transformations"><List><Item value="{6}" /></List></Property>' +
            '<Property name="isProperty" value="{7}" /><Property name="displayName" value="{8}" /></Value></Item>') -f
        (& $e $c.Key), $n, $unit, (& $lower $c.String), (& $e $Definition.AdapterKind), (& $e $Definition.ResourceKind), (& $e $c.Transform), (& $lower $c.Property), (& $e $c.Name)
    }

    $xml = ('<ViewDef id="{0}"><Title localizationKey="title">{1}</Title><Description localizationKey="desc">{2}</Description>{3}' +
        '<Usage>dashboard</Usage><Usage>report</Usage><Usage>details</Usage><Usage>content</Usage><Controls>' +
        '<Control id="time-interval-selector_id_500" type="time-interval-selector" visible="false"><Property name="advancedTimeMode" value="false" /><Property name="unit" value="DAYS" /><Property name="count" value="{4}" /></Control>' +
        '<Control id="attributes-selector_id_501" type="attributes-selector" visible="false"><Property name="attributeInfos"><List>{5}</List></Property></Control>' +
        '<Control id="pagination-control_id_502" type="pagination-control" visible="true"><Property name="start" value="0" /><Property name="size" value="50" /></Control>' +
        '</Controls><DataProviders><DataProvider dataType="list-view" id="list-view_id_499" /></DataProviders><Presentation type="list" /></ViewDef>') -f
    $id, (& $e $Definition.Name), (& $e $Definition.Description), $subject, [int]$Definition.Days, ($items -join '')

    @{ Id = $id; Xml = $xml; Properties = @("view.$id.title=$($Definition.Name)", "view.$id.desc=$($Definition.Description)") }
}

function ConvertTo-SynthReportXml {
    <#
    .SYNOPSIS
        One report as a ReportDef element: a cover page, then each of its views, as PDF and CSV.

    .PARAMETER Definition
        A report from Get-SynthViewContent.

    .PARAMETER View
        The view definitions, so the report can run on the kinds its views list.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$Definition,
        [Parameter(Mandatory)][System.Collections.IDictionary[]]$View
    )

    $e = { param($s) [System.Security.SecurityElement]::Escape([string]$s) }
    $id = Get-SynthContentId -Kind 'report' -Name $Definition.Name
    $sections = '<Section><ContentType>CoverPage</ContentType><ContentKey>COVER_PAGE</ContentKey></Section>'
    $kinds = [ordered]@{}
    foreach ($name in $Definition.Views) {
        $v = $View | Where-Object { $_.Name -eq $name } | Select-Object -First 1
        if (-not $v) { throw "Report '$($Definition.Name)' lists view '$name', which is not defined." }
        $kinds["$($v.AdapterKind)/$($v.ResourceKind)"] = $v
        $sections += '<Section><ContentType>View</ContentType><ContentKey>{0}</ContentKey><ContentOrientation>Landscape</ContentOrientation></Section>' -f (Get-SynthContentId -Kind 'view' -Name $name)
    }
    $subject = foreach ($v in $kinds.Values) {
        foreach ($type in 'descendant', 'self') { '<SubjectType adapterKind="{0}" resourceKind="{1}" type="{2}" />' -f (& $e $v.AdapterKind), (& $e $v.ResourceKind), $type }
    }

    $xml = ('<ReportDef id="{0}"><isTenant>false</isTenant><Title localizationKey="title">{1}</Title><Description localizationKey="desc">{2}</Description>{3}' +
        '<Sections>{4}</Sections><Settings><ShowPageFooter>true</ShowPageFooter><OutputFormat>pdf</OutputFormat><OutputFormat>csv</OutputFormat></Settings></ReportDef>') -f
    $id, (& $e $Definition.Name), (& $e $Definition.Description), ($subject -join ''), $sections

    @{ Id = $id; Xml = $xml; Properties = @("report.$id.title=$($Definition.Name)", "report.$id.desc=$($Definition.Description)") }
}

function New-SynthContentBundle {
    <#
    .SYNOPSIS
        Writes a content import bundle (a zip) holding the given views, reports and dashboards.

    .DESCRIPTION
        The layout follows a VCF Operations 9.1.1 content export: configuration.json
        with the counts, usermappings.json naming the owner, the <id>L.v1 marker file
        holding the owner's id, views.zip and reports.zip (each a content.xml and
        resources/content.properties), and dashboards/<owner>, a zip with no
        extension holding dashboard/dashboard.json and its resources file.

    .PARAMETER Path
        The bundle file to write; replaced if it exists.

    .PARAMETER OwnerId
        The id of the Operations user who will own the dashboards.

    .PARAMETER UserName
        That user's name, for usermappings.json.

    .PARAMETER View
        Converted views, from ConvertTo-SynthViewXml.

    .PARAMETER Report
        Converted reports, from ConvertTo-SynthReportXml.

    .PARAMETER Dashboard
        Dashboard objects, each one entry of dashboard.json's dashboards array.

    .OUTPUTS
        The bundle path and its counts.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$OwnerId,
        [string]$UserName = 'admin',
        [hashtable[]]$View = @(),
        [hashtable[]]$Report = @(),
        [object[]]$Dashboard = @()
    )

    Add-Type -AssemblyName System.IO.Compression
    $utf8 = [System.Text.UTF8Encoding]::new($false)
    # Builds a zip in memory from entry name to text or bytes; forward slashes in names, as in an export.
    $zip = {
        param([System.Collections.IDictionary]$entries)
        $ms = [System.IO.MemoryStream]::new()
        $archive = [System.IO.Compression.ZipArchive]::new($ms, [System.IO.Compression.ZipArchiveMode]::Create, $true)
        try {
            foreach ($name in $entries.Keys) {
                $data = $entries[$name]
                $bytes = if ($data -is [byte[]]) { $data } else { $utf8.GetBytes([string]$data) }
                $stream = $archive.CreateEntry($name).Open()
                try { $stream.Write($bytes, 0, $bytes.Length) } finally { $stream.Dispose() }
            }
        }
        finally { $archive.Dispose() }
        , $ms.ToArray()
    }
    $content = {
        param($section, $items)
        $xml = "<?xml version=`"1.0`" encoding=`"UTF-8`" standalone=`"yes`"?>`n<Content>`n    <$section>`n        " + ($items.Xml -join "`n        ") + "`n    </$section>`n</Content>"
        & $zip ([ordered]@{ 'content.xml' = $xml; 'resources/content.properties' = (@($items.Properties) -join "`n") + "`n" })
    }

    $result = [pscustomobject]@{ Path = $Path; Views = $View.Count; Reports = $Report.Count; Dashboards = $Dashboard.Count }
    if (-not $PSCmdlet.ShouldProcess($Path, 'Write content bundle')) { return $result }

    $configuration = [ordered]@{ type = 'CUSTOM' }
    $entries = [ordered]@{}
    if ($View.Count) { $configuration.views = $View.Count; $entries['views.zip'] = & $content 'Views' $View }
    if ($Report.Count) { $configuration.reports = $Report.Count; $entries['reports.zip'] = & $content 'Reports' $Report }
    if ($Dashboard.Count) {
        $configuration.dashboards = $Dashboard.Count
        $configuration.dashboardsByOwner = @([ordered]@{ owner = $OwnerId; count = $Dashboard.Count })
        $json = [ordered]@{ entries = @(); dashboards = @($Dashboard); uuid = (Get-SynthContentId -Kind 'dashboards' -Name $OwnerId) } | ConvertTo-Json -Depth 100
        $entries["dashboards/$OwnerId"] = & $zip ([ordered]@{ 'dashboard/dashboard.json' = $json; 'dashboard/resources/resources.properties' = "#Dashboard Localization`n" })
    }
    $root = [ordered]@{
        'configuration.json'      = ($configuration | ConvertTo-Json -Depth 5)
        'usermappings.json'       = ([ordered]@{ sources = @(); users = @([ordered]@{ userName = $UserName; userId = $OwnerId }) } | ConvertTo-Json -Depth 5)
        '6844548499441080431L.v1' = $OwnerId
    }
    foreach ($k in $entries.Keys) { $root[$k] = $entries[$k] }

    $dir = Split-Path -Parent $Path
    if ($dir -and -not (Test-Path -LiteralPath $dir)) { $null = New-Item -ItemType Directory -Path $dir -Force }
    [System.IO.File]::WriteAllBytes($Path, (& $zip $root))
    $result
}

function Get-SynthOpsUserId {
    <#
    .SYNOPSIS
        The id of an Operations user, by name; dashboards in a bundle are owned by it.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$UserName)

    foreach ($u in @(Get-SynthPagedList -Path 'auth/users' -Property 'users')) {
        if ([string](Get-SynthResponseField $u 'username') -ieq $UserName) { return [string](Get-SynthResponseField $u 'id') }
    }
    throw "No Operations user named '$UserName' was found, so the dashboards have no owner."
}

function Import-SynthContentBundle {
    <#
    .SYNOPSIS
        Imports a content bundle and waits for Operations to finish, returning its summary per content type.

    .DESCRIPTION
        POST content/operations/import is asynchronous: it answers 202, and the
        state is read from GET content/operations/import until it is FINISHED
        (or FAILED). With -Force, content with the same name is overwritten,
        which is how a re-run updates views and dashboards that cannot be
        deleted through the API.

    .PARAMETER Path
        The bundle, from New-SynthContentBundle.

    .PARAMETER Force
        Overwrite existing content of the same name.

    .PARAMETER FieldName
        The multipart field the zip is sent in.

    .PARAMETER TimeoutSec
        How long to wait for the import to finish.

    .PARAMETER PollSec
        Seconds between status reads.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][string]$Path,
        [switch]$Force,
        [string]$FieldName = 'contentFile',
        [int]$TimeoutSec = 600,
        [int]$PollSec = 5
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw "Content bundle '$Path' was not found." }
    if (-not $PSCmdlet.ShouldProcess($Path, 'Import content bundle')) { return }

    $null = Invoke-SynthOpsRequest -Method Post -Path 'content/operations/import' -Query @{ force = ([string][bool]$Force).ToLowerInvariant() } -Form @{ $FieldName = (Get-Item -LiteralPath $Path) } -MaxRetries 0
    $deadline = [datetime]::UtcNow.AddSeconds($TimeoutSec)
    while ($true) {
        # Waiting first keeps the previous import's FINISHED state from being read as this one's.
        Start-Sleep -Seconds $PollSec
        $status = Invoke-SynthOpsRequest -Method Get -Path 'content/operations/import'
        $state = [string](Get-SynthResponseField $status 'state')
        if ($state -in 'FINISHED', 'FAILED') { break }
        if ([datetime]::UtcNow -ge $deadline) { throw "The content import was still '$state' after $TimeoutSec s." }
    }
    [pscustomobject]@{
        State     = $state
        Summaries = @(Get-SynthResponseField $status 'operationSummaries' | Where-Object { $null -ne $_ })
        Errors    = @(Get-SynthResponseField $status 'errorMessages' | Where-Object { $_ })
    }
}
