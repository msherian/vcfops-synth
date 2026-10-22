function Get-SynthLiveOpticsColumnMap {
    <#
    .SYNOPSIS
        Maps the performance fields the importer reads to the LiveOptics VMware workbook headers.

    .DESCRIPTION
        LiveOptics (Dell) collects peaks and averages over its collection window,
        one row per VM on "VM Performance" and one row per host on "ESX
        Performance". Only numbers and the object's identity are read; the
        project name, owner and collector details are not.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param()

    @{
        'VM Performance'  = @{
            vm                 = @{ Headers = @('VM Name'); Required = $true }
            mobId              = @{ Headers = @('MOB ID') }
            ioClass            = @{ Headers = @('VM IO Classification') }
            cpuPeakPct         = @{ Headers = @('Peak vCPU %') }
            cpuAvgPct          = @{ Headers = @('Average vCPU %') }
            memPeakPct         = @{ Headers = @('Peak Memory %') }
            memAvgPct          = @{ Headers = @('Avg Memory %', 'Average Memory %') }
            iopsPeak           = @{ Headers = @('Peak IOPS') }
            iopsAvg            = @{ Headers = @('Average IOPS') }
            readIopsPeak       = @{ Headers = @('Peak Read IOPS') }
            writeIopsPeak      = @{ Headers = @('Peak Write IOPS') }
            readIopsAvg        = @{ Headers = @('Avg Read IOPS') }
            writeIopsAvg       = @{ Headers = @('Avg Write IOPS') }
            readMBpsPeak       = @{ Headers = @('Peak Read MB/s') }
            writeMBpsPeak      = @{ Headers = @('Peak Write MB/s') }
            readMBpsAvg        = @{ Headers = @('Avg Read MB/s') }
            writeMBpsAvg       = @{ Headers = @('Avg Write MB/s') }
            readLatencyPeakMs  = @{ Headers = @('Peak Read Latency') }
            writeLatencyPeakMs = @{ Headers = @('Peak Write Latency') }
            readLatencyAvgMs   = @{ Headers = @('Avg Read Latency') }
            writeLatencyAvgMs  = @{ Headers = @('Avg Write Latency') }
        }
        'ESX Performance' = @{
            host               = @{ Headers = @('Host'); Required = $true }
            cpuPeakPct         = @{ Headers = @('Peak CPU %') }
            cpuAvgPct          = @{ Headers = @('Average CPU %') }
            memPeakPct         = @{ Headers = @('Peak Memory %') }
            memAvgPct          = @{ Headers = @('Average Memory %') }
            iopsPeak           = @{ Headers = @('Peak IOPS') }
            iopsAvg            = @{ Headers = @('Average IOPS') }
            throughputPeakMBps = @{ Headers = @('Peak Throughput MB/s') }
            throughputAvgMBps  = @{ Headers = @('Avg Throughput MB/s') }
            readLatencyPeakMs  = @{ Headers = @('Peak Read Latency') }
            writeLatencyPeakMs = @{ Headers = @('Peak Write Latency') }
            readLatencyAvgMs   = @{ Headers = @('Avg Read Latency') }
            writeLatencyAvgMs  = @{ Headers = @('Avg Write Latency') }
        }
    }
}

function Read-SynthLiveOptics {
    <#
    .SYNOPSIS
        Reads per-VM and per-host performance from a LiveOptics VMware workbook.

    .DESCRIPTION
        Returns the rows keyed for joining to an RVTools export: VMs by their
        vCenter managed object ID (MOB ID, the same value as RVTools' VM ID) and
        by lower-case name, hosts by lower-case name and short name. Joining
        happens in Import-SynthRvtools, before names are anonymised.

    .PARAMETER Path
        The LiveOptics VMware xlsx (LiveOptics_<project>_VMWARE_<date>.xlsx).

    .PARAMETER LatencyCeilingMs
        A latency above this many milliseconds is read as missing and counted in LatencyDropped.

    .OUTPUTS
        @{ CollectedOn; Vms = list; Hosts = list; VmsById; VmsByName; HostsByName; LatencyDropped }
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '', Justification = 'LiveOptics is the product name, not a plural.')]
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][string]$Path,
        [double]$LatencyCeilingMs = 10000
    )

    if (-not (Test-Path -LiteralPath $Path)) { throw "LiveOptics workbook '$Path' was not found." }
    if ([System.IO.Path]::GetExtension($Path) -ine '.xlsx') { throw "'$Path' is not an .xlsx file. Use the LiveOptics VMware workbook." }
    if (-not (Get-Module -Name ImportExcel)) {
        try { Import-Module -Name ImportExcel -ErrorAction Stop -WarningAction SilentlyContinue }
        catch { throw 'Reading xlsx needs the ImportExcel module, which the image includes. Install it with: Install-PSResource ImportExcel' }
    }

    $sheets = @(Get-ExcelSheetInfo -Path $Path | ForEach-Object Name)
    $map = Get-SynthLiveOpticsColumnMap
    $result = @{
        CollectedOn = $null
        Vms         = [System.Collections.Generic.List[hashtable]]::new()
        Hosts       = [System.Collections.Generic.List[hashtable]]::new()
        VmsById     = @{}
        VmsByName   = @{}
        HostsByName = @{}
        LatencyDropped = 0
    }
    foreach ($tab in 'VM Performance', 'ESX Performance') {
        if ($tab -notin $sheets) { throw "'$Path' has no '$tab' sheet. Is this the LiveOptics VMware workbook?" }
    }

    # The Details sheet is a two-column list of labels and values, with no header row.
    if ('Details' -in $sheets) {
        $details = @(Import-Excel -Path $Path -WorksheetName 'Details' -NoHeader -ErrorAction Stop -WarningAction SilentlyContinue)
        $date = $details | Where-Object { [string]$_.P1 -eq 'Date' } | Select-Object -First 1
        if ($date) { $result.CollectedOn = ConvertTo-SynthDateText ([string]$date.P2) }
    }

    $ceiling = $LatencyCeilingMs
    $numbers = {
        param($Row, $Columns, [string[]]$Fields)
        $values = [ordered]@{}
        foreach ($field in $Fields) {
            $value = ConvertTo-SynthNumber (Get-SynthRvCell $Row $Columns $field)
            # LiveOptics exports hold the odd corrupt latency (billions of ms); such a value is treated as missing.
            if ($field -like '*LatencyAvgMs' -or $field -like '*LatencyPeakMs') {
                if ($null -ne $value -and [double]$value -gt $ceiling) { $value = $null; $result.LatencyDropped++ }
            }
            $values[$field] = $value
        }
        $values
    }

    $tab = 'VM Performance'
    $sheet = Read-SynthRvtoolsSheet -Path $Path -Worksheet $tab
    $columns = Resolve-SynthLiveOpticsColumn -Tab $tab -Header $sheet.Headers -Map $map
    $vmFields = @($map[$tab].Keys | Where-Object { $_ -notin 'vm', 'mobId', 'ioClass' } | Sort-Object)
    foreach ($row in $sheet.Rows) {
        $name = Get-SynthRvCell $row $columns 'vm'
        if (-not $name) { continue }
        $record = @{
            Name    = [string]$name
            MobId   = ConvertTo-SynthText (Get-SynthRvCell $row $columns 'mobId')
            IoClass = ConvertTo-SynthText (Get-SynthRvCell $row $columns 'ioClass')
            Values  = & $numbers $row $columns $vmFields
        }
        $result.Vms.Add($record)
        if ($record.MobId) {
            if (-not $result.VmsById.ContainsKey($record.MobId)) { $result.VmsById[$record.MobId] = [System.Collections.Generic.List[hashtable]]::new() }
            $result.VmsById[$record.MobId].Add($record)
        }
        $lower = $record.Name.ToLowerInvariant()
        if (-not $result.VmsByName.ContainsKey($lower)) { $result.VmsByName[$lower] = [System.Collections.Generic.List[hashtable]]::new() }
        $result.VmsByName[$lower].Add($record)
    }

    $tab = 'ESX Performance'
    $sheet = Read-SynthRvtoolsSheet -Path $Path -Worksheet $tab
    $columns = Resolve-SynthLiveOpticsColumn -Tab $tab -Header $sheet.Headers -Map $map
    $hostFields = @($map[$tab].Keys | Where-Object { $_ -ne 'host' } | Sort-Object)
    foreach ($row in $sheet.Rows) {
        $name = Get-SynthRvCell $row $columns 'host'
        if (-not $name) { continue }
        $record = @{ Name = [string]$name; Values = & $numbers $row $columns $hostFields }
        $result.Hosts.Add($record)
        $lower = $record.Name.ToLowerInvariant()
        foreach ($key in $lower, $lower.Split('.')[0]) {
            if (-not $result.HostsByName.ContainsKey($key)) { $result.HostsByName[$key] = $record }
        }
    }
    $result
}

function Resolve-SynthLiveOpticsColumn {
    <# Resolves LiveOptics headers with the same rules as RVTools ones, and stops on a missing required column. #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][string]$Tab,
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$Header,
        [Parameter(Mandatory)][hashtable]$Map
    )

    $present = @{}
    foreach ($name in $Header) { if ($name) { $present[$name.Trim()] = $name } }
    $resolved = @{}
    foreach ($field in $Map[$Tab].Keys) {
        $spec = $Map[$Tab][$field]
        $found = $spec.Headers | Where-Object { $present.ContainsKey($_) } | Select-Object -First 1
        if ($found) { $resolved[$field] = $present[$found] }
        elseif ($spec.ContainsKey('Required') -and $spec.Required) {
            throw "LiveOptics sheet '$Tab' has no $field (column $($spec.Headers -join ' or '))."
        }
    }
    $resolved
}
