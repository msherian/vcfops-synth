function Get-SynthRvtoolsColumnMap {
    <#
    .SYNOPSIS
        Maps the fields the importer reads to the RVTools column headers that carry them.

    .DESCRIPTION
        Column names change between RVTools releases (3.x writes "MB" where 4.x
        writes "MiB", for example), so each field lists every header known to carry
        it, newest first. The first header present in a tab wins. A field marked
        Required must be found, or the tab is rejected with the names it accepts.

        Columns the importer does not list are still readable by tiering rules as
        attribute:<header>, which is how vCenter custom attributes are matched.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param()

    # Identity columns shared by every per-VM tab, used to join rows to the vInfo row.
    $vmKey = @{
        vm     = @{ Headers = @('VM'); Required = $true }
        vmId   = @{ Headers = @('VM ID') }
        vmUuid = @{ Headers = @('VM UUID') }
        server = @{ Headers = @('VI SDK Server') }
    }

    $map = @{
        vInfo      = @{
            powerState     = @{ Headers = @('Powerstate') }
            template       = @{ Headers = @('Template') }
            srmPlaceholder = @{ Headers = @('SRM Placeholder') }
            cpus           = @{ Headers = @('CPUs') }
            memoryMiB      = @{ Headers = @('Memory') }
            provisionedMiB = @{ Headers = @('Provisioned MiB', 'Provisioned MB') }
            inUseMiB       = @{ Headers = @('In Use MiB', 'In Use MB') }
            resourcePool   = @{ Headers = @('Resource pool') }
            folder         = @{ Headers = @('Folder') }
            annotation     = @{ Headers = @('Annotation') }
            datacenter     = @{ Headers = @('Datacenter') }
            cluster        = @{ Headers = @('Cluster') }
            host           = @{ Headers = @('Host') }
            path           = @{ Headers = @('Path') }
            osConfig       = @{ Headers = @('OS according to the configuration file') }
            osTools        = @{ Headers = @('OS according to the VMware Tools') }
            hwVersion      = @{ Headers = @('HW version') }
            creationDate   = @{ Headers = @('Creation date') }
        }
        vCPU       = @{
            sockets        = @{ Headers = @('Sockets') }
            coresPerSocket = @{ Headers = @('Cores p/s') }
            maxMhz         = @{ Headers = @('Max') }
            overallMhz     = @{ Headers = @('Overall') }
            reservationMhz = @{ Headers = @('Reservation') }
            limitMhz       = @{ Headers = @('Limit') }
        }
        vMemory    = @{
            sizeMiB        = @{ Headers = @('Size MiB', 'Size MB') }
            consumedMiB    = @{ Headers = @('Consumed') }
            activeMiB      = @{ Headers = @('Active') }
            balloonedMiB   = @{ Headers = @('Ballooned') }
            swappedMiB     = @{ Headers = @('Swapped') }
            reservationMiB = @{ Headers = @('Reservation') }
            limitMiB       = @{ Headers = @('Limit') }
        }
        vPartition = @{
            disk        = @{ Headers = @('Disk') }
            capacityMiB = @{ Headers = @('Capacity MiB', 'Capacity MB') }
            consumedMiB = @{ Headers = @('Consumed MiB', 'Consumed MB') }
        }
        vSnapshot  = @{
            name    = @{ Headers = @('Name') }
            created = @{ Headers = @('Date / time') }
            sizeMiB = @{ Headers = @('Size MiB (total)', 'Size MB (total)', 'Size MiB (vmsn)', 'Size MB (vmsn)') }
        }
        vTools     = @{
            toolsStatus  = @{ Headers = @('Tools') }
            toolsVersion = @{ Headers = @('Tools Version') }
            vmVersion    = @{ Headers = @('VM Version') }
            upgradeable  = @{ Headers = @('Upgradeable') }
        }
        vHost      = @{
            host        = @{ Headers = @('Host'); Required = $true }
            datacenter  = @{ Headers = @('Datacenter') }
            cluster     = @{ Headers = @('Cluster') }
            cpuModel    = @{ Headers = @('CPU Model') }
            speedMhz    = @{ Headers = @('Speed') }
            sockets     = @{ Headers = @('# CPU') }
            cores       = @{ Headers = @('# Cores') }
            cpuUsagePct = @{ Headers = @('CPU usage %') }
            memoryMiB   = @{ Headers = @('# Memory') }
            memUsagePct = @{ Headers = @('Memory usage %') }
            esxVersion  = @{ Headers = @('ESX Version') }
            vendor      = @{ Headers = @('Vendor') }
            model       = @{ Headers = @('Model') }
            maintenance = @{ Headers = @('in Maintenance Mode') }
            server      = @{ Headers = @('VI SDK Server') }
        }
        vCluster   = @{
            name       = @{ Headers = @('Name', 'Cluster'); Required = $true }
            datacenter = @{ Headers = @('Datacenter') }
            haEnabled  = @{ Headers = @('HA enabled') }
            drsEnabled = @{ Headers = @('DRS enabled') }
            server     = @{ Headers = @('VI SDK Server') }
        }
        vDatastore = @{
            name           = @{ Headers = @('Name'); Required = $true }
            type           = @{ Headers = @('Type') }
            capacityMiB    = @{ Headers = @('Capacity MiB', 'Capacity MB') }
            provisionedMiB = @{ Headers = @('Provisioned MiB', 'Provisioned MB') }
            inUseMiB       = @{ Headers = @('In Use MiB', 'In Use MB') }
            freeMiB        = @{ Headers = @('Free MiB', 'Free MB') }
            hosts          = @{ Headers = @('Hosts') }
            server         = @{ Headers = @('VI SDK Server') }
        }
        vMetaData  = @{
            rvtoolsVersion = @{ Headers = @('RVTools version', 'RVTools Version') }
            created        = @{ Headers = @('xlsx creation datetime', 'Creation date') }
        }
    }

    foreach ($tab in 'vInfo', 'vCPU', 'vMemory', 'vPartition', 'vSnapshot', 'vTools') {
        foreach ($field in $vmKey.Keys) { $map[$tab][$field] = $vmKey[$field] }
    }
    $map
}

function Resolve-SynthRvtoolsColumn {
    <#
    .SYNOPSIS
        Works out which header carries each field in one tab, and reports required fields that are missing.

    .OUTPUTS
        A hashtable of field name to the header found, with a Missing key listing
        the required fields not found, each with the headers that would satisfy it.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][string]$Tab,
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$Header
    )

    $fields = (Get-SynthRvtoolsColumnMap)[$Tab]
    if (-not $fields) { throw "No column map for RVTools tab '$Tab'." }

    # Headers compare case-insensitively and ignore stray spaces, as Excel users edit them.
    $present = @{}
    foreach ($name in $Header) { if ($name) { $present[$name.Trim()] = $name } }

    $resolved = @{ Missing = [System.Collections.Generic.List[string]]::new() }
    foreach ($field in $fields.Keys) {
        $spec = $fields[$field]
        $found = $spec.Headers | Where-Object { $present.ContainsKey($_) } | Select-Object -First 1
        if ($found) {
            $resolved[$field] = $present[$found]
        }
        elseif ($spec.ContainsKey('Required') -and $spec.Required) {
            $resolved.Missing.Add("$field (column $($spec.Headers -join ' or '))")
        }
    }
    $resolved
}
