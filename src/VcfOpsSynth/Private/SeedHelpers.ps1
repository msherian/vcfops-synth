function Get-SynthMoidPrefix {
    <# The vCenter managed object ID prefix for a kind, so synthetic IDs read like vCenter's (host-synth-1a2b3c). #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$Kind)

    switch ($Kind) {
        'Datacenter' { 'datacenter' }
        'ClusterComputeResource' { 'domain-c' }
        'HostSystem' { 'host' }
        'Datastore' { 'datastore' }
        'VmwareDistributedVirtualSwitch' { 'dvs' }
        'DistributedVirtualPortgroup' { 'dvportgroup' }
        'VMFolder' { 'group-v' }
        'VirtualMachine' { 'vm' }
        default { throw "No managed object ID prefix for kind '$Kind'." }
    }
}

function Get-SynthSeedIdentifier {
    <#
    .SYNOPSIS
        Returns the resource identifiers a kind needs under a vCenter adapter instance.

    .DESCRIPTION
        VMEntityObjectID and VMEntityVCID make an object unique; VMEntityName is
        mandatory for every kind but VMFolder. Hosts, datastores and VMs need the
        extra identifiers the spikes found (runbook, spikes 0.5 and 0.6).
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][string]$Kind,
        [Parameter(Mandatory)][System.Collections.IDictionary]$Record,
        [Parameter(Mandatory)][string]$VcId
    )

    # The toolset's own kinds need one identifier; a Physical Data Center has none and is unique by name.
    if ($Kind -in (Get-SynthSeedKind -Custom)) { return @{ name = 'SynthId'; value = $Record.key; unique = $true } }
    if ($Kind -eq 'PhysicalDatacenter') { return }
    @{ name = 'VMEntityObjectID'; value = $Record.moid; unique = $true }
    @{ name = 'VMEntityVCID'; value = $VcId; unique = $true }
    if ($Kind -ne 'VMFolder') { @{ name = 'VMEntityName'; value = $Record.name; unique = $false } }
    switch ($Kind) {
        'HostSystem' { @{ name = 'isPingEnabled'; value = ''; unique = $false } }
        'Datastore' {
            # Spelt this way by the vCenter adapter.
            @{ name = 'DataStrorePath'; value = "ds:///vmfs/volumes/$($Record.moid)/"; unique = $false }
        }
        'VirtualMachine' {
            @{ name = 'VMEntityInstanceUUID'; value = (ConvertTo-SynthGuid -Text "instance:$($Record.moid)"); unique = $false }
            @{ name = 'isPingEnabled'; value = ''; unique = $false }
            @{ name = 'VMServiceMonitoringEnabled'; value = ''; unique = $false }
        }
    }
}

function Expand-SynthRubricEntry {
    <#
    .SYNOPSIS
        Rewrites a rubric's per-instance keys for an object's own instances.

    .DESCRIPTION
        A family is the keys named <Prefix>:<instance>|<rest> whose instance
        matches Match, for example virtualDisk:scsi0:1|read_average. The union of
        rests across the reference object's instances is the template; each of
        the object's instances gets every rest, valued from the instance's Set
        when it has one and from the reference otherwise. Keys outside every
        family pass through unchanged, as do "Aggregate of all instances" keys.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Entry,
        [AllowEmptyCollection()][object[]]$Family = @()
    )

    Join-SynthRubricEntry -Split (Split-SynthRubricEntry -Entry $Entry -Family $Family) -Family $Family
}

function Split-SynthRubricEntry {
    <#
    .SYNOPSIS
        Separates a rubric's keys into plain ones and one template per family; see Expand-SynthRubricEntry.

    .DESCRIPTION
        Only each family's Prefix and Match are read, so the split of one kind's
        rubric serves every object of that kind.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Entry,
        [AllowEmptyCollection()][object[]]$Family = @()
    )

    $plain = [System.Collections.Generic.List[object]]::new()
    $templates = @(foreach ($f in $Family) { [ordered]@{} })
    foreach ($e in $Entry) {
        $claimed = $false
        if ($Family.Count -and $e.key -match '^(?<prefix>[^:|]+):(?<inst>[^|]+)\|(?<rest>.+)$' -and $Matches.inst -ne 'Aggregate of all instances') {
            $prefix = $Matches.prefix; $inst = $Matches.inst; $rest = $Matches.rest
            for ($i = 0; $i -lt $Family.Count; $i++) {
                if ($Family[$i].Prefix -eq $prefix -and $inst -match $Family[$i].Match) {
                    if (-not $templates[$i].Contains($rest)) { $templates[$i][$rest] = $e.value }
                    $claimed = $true
                    break
                }
            }
        }
        if (-not $claimed) { $plain.Add(@{ key = $e.key; value = $e.value }) }
    }
    @{ Plain = $plain; Templates = $templates }
}

function Join-SynthRubricEntry {
    <# Puts a split rubric back together for one object's own instances; see Expand-SynthRubricEntry. #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][hashtable]$Split,
        [AllowEmptyCollection()][object[]]$Family = @()
    )

    foreach ($e in $Split.Plain) { @{ key = $e.key; value = $e.value } }
    for ($i = 0; $i -lt $Family.Count; $i++) {
        $template = $Split.Templates[$i]
        foreach ($instance in @($Family[$i].Instances)) {
            if (-not $instance) { continue }
            foreach ($rest in $template.Keys) {
                $value = if ($instance.Set -and $instance.Set.ContainsKey($rest)) { $instance.Set[$rest] } else { $template[$rest] }
                @{ key = "$($Family[$i].Prefix):$($instance.Name)|$rest"; value = $value }
            }
        }
    }
}

function Get-SynthVmProperty {
    <# Identity, placement and sizing properties of a synthetic VM, from its inventory record. #>
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$Vm,
        [Parameter(Mandatory)][System.Collections.IDictionary]$Record,
        [Parameter(Mandatory)][scriptblock]$NameOf
    )

    $on = $Vm.powerState -eq 'poweredOn'
    $guest = [string]$Vm.guestOs
    $set = [ordered]@{
        'summary|guest|hostName'        = $Record.name
        'summary|MOID'                  = $Record.moid
        'summary|parentHost'            = & $NameOf $Vm.host
        'summary|parentCluster'         = & $NameOf $Vm.cluster
        'summary|parentDatacenter'      = & $NameOf $Vm.datacenter
        'summary|parentFolder'          = & $NameOf $Vm.folderId
        'summary|folder'                = & $NameOf $Vm.folderId
        'summary|datastore'             = (@($Vm.datastores | ForEach-Object { & $NameOf $_ }) -join ', ')
        'summary|runtime|powerState'    = switch ($Vm.powerState) { 'poweredOn' { 'Powered On' } 'suspended' { 'Suspended' } default { 'Powered Off' } }
        'summary|guest|ipAddress'       = '-'
        'summary|guest|toolsRunningStatus' = if ($on) { 'Guest Tools Running' } else { 'Guest Tools Not Running' }
        'summary|UUID'                  = ConvertTo-SynthGuid -Text "uuid:$($Record.moid)"
        'summary|smbiosUUID'            = ConvertTo-SynthGuid -Text "bios:$($Record.moid)"
        'summary|config|numEthernetCards' = @($Vm.nics).Count
        'config|numVMDKs'               = @($Vm.storage.disks).Count
        'config|numVMDKsOnly'           = @($Vm.storage.disks).Count
    }
    if ($guest) {
        $set['config|guestFullName'] = $guest
        $set['summary|guest|fullName'] = $guest
        $set['summary|guest|guestFamily'] = if ($guest -match 'Windows') { 'windowsGuest' }
        elseif ($guest -match 'Linux|Ubuntu|Red Hat|CentOS|SUSE|Debian|Photon|Oracle|Rocky|Alma') { 'linuxGuest' }
        else { 'otherGuest' }
    }
    if ($Vm.hardwareVersion) { $set['config|version'] = "vmx-$($Vm.hardwareVersion)" }
    if ($Vm.toolsVersion) { $set['summary|guest|toolsVersion'] = [string]$Vm.toolsVersion }
    $cpu = $Vm.cpu
    if ($cpu.vcpus) { $set['config|hardware|numCpu'] = $cpu.vcpus }
    if ($cpu.sockets) { $set['config|hardware|numSockets'] = $cpu.sockets }
    if ($cpu.coresPerSocket) { $set['config|hardware|numCoresPerSocket'] = $cpu.coresPerSocket }
    if ($null -ne $cpu.reservationMhz) { $set['cpu|reservation'] = $cpu.reservationMhz; $set['config|cpuAllocation|reservation'] = $cpu.reservationMhz }
    $cpuLimit = if ($null -ne $cpu.limitMhz) { $cpu.limitMhz } else { -1 }
    $set['cpu|limit'] = $cpuLimit; $set['config|cpuAllocation|limit'] = $cpuLimit
    $memory = $Vm.memory
    if ($memory.sizeMiB) { $set['config|hardware|memoryKB'] = $memory.sizeMiB * 1024; $set['runtime|memoryCap'] = $memory.sizeMiB * 1024 }
    if ($null -ne $memory.reservationMiB) { $set['config|memoryAllocation|reservation'] = $memory.reservationMiB }
    $memLimit = if ($null -ne $memory.limitMiB) { $memory.limitMiB } else { -1 }
    $set['config|memoryAllocation|limit'] = $memLimit; $set['mem|host_limit'] = $memLimit
    if ($Vm.storage.provisionedMiB) { $set['config|hardware|diskSpace'] = [math]::Round($Vm.storage.provisionedMiB / 1024, 1) }
    $set
}

function Get-SynthVmFamily {
    <# The per-instance key families of a synthetic VM: virtual disks, guest file systems and network adapters. #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$Vm,
        [Parameter(Mandatory)][System.Collections.IDictionary]$Record,
        [Parameter(Mandatory)][scriptblock]$NameOf
    )

    # SCSI slots in the order vSphere hands them out: 15 per controller, unit 7 is the controller itself.
    $slots = @(foreach ($bus in 0..3) { foreach ($unit in 0..15) { if ($unit -ne 7) { "scsi${bus}:$unit" } } })
    $disks = @($Vm.storage.disks)
    $diskInstances = @(for ($i = 0; $i -lt [math]::Min($disks.Count, $slots.Count); $i++) {
            $d = $disks[$i]
            @{ Name = $slots[$i]; Set = @{
                    label             = if ($d.label) { $d.label } else { "Hard disk $($i + 1)" }
                    configuredGB      = if ($d.capacityMiB) { [math]::Round($d.capacityMiB / 1024, 1) } else { 0 }
                    provisioning_type = if ($d.thin) { 'Thin Provision' } else { 'Thick Provision Lazy Zeroed' }
                    datastore         = & $NameOf $d.datastore
                    diskUUID          = ConvertTo-SynthGuid -Text "disk:$($Record.moid):$i"
                    isRDM             = 'false'
                    encryptionStatus  = 'False'
                }
            }
        })

    $windows = [string]$Vm.guestOs -match 'Windows'
    $partitions = @($Vm.storage.partitions)
    $fsInstances = @(for ($i = 0; $i -lt $partitions.Count; $i++) {
            $p = $partitions[$i]
            $path = if ($windows) { "$([char](67 + [math]::Min($i, 23))):\" } elseif ($i -eq 0) { '/' } else { "/data$i" }
            $capacityGB = if ($p.capacityMiB) { [math]::Round($p.capacityMiB / 1024, 2) } else { 0 }
            $usageGB = if ($p.consumedMiB) { [math]::Round($p.consumedMiB / 1024, 2) } else { 0 }
            @{ Name = $path; Set = @{
                    capacity   = $capacityGB
                    usage      = $usageGB
                    percentage = if ($capacityGB -gt 0) { [math]::Round($usageGB / $capacityGB * 100, 2) } else { 0 }
                }
            }
        })

    $nics = @($Vm.nics)
    $nicInstances = @(for ($i = 0; $i -lt $nics.Count; $i++) {
            $n = $nics[$i]
            @{ Name = [string](4000 + $i); Set = @{
                    portGroup    = & $NameOf $n.network
                    mac_address  = ConvertTo-SynthMac -Text "$($Record.moid):$i"
                    ip_address   = '-'
                    ipv6_address = '-'
                    connected    = if ($n.connected -eq $false) { 'false' } else { 'true' }
                }
            }
        })

    @(
        @{ Prefix = 'virtualDisk'; Match = '^scsi\d+:\d+$'; Instances = $diskInstances }
        @{ Prefix = 'guestfilesystem'; Match = '.'; Instances = $fsInstances }
        @{ Prefix = 'net'; Match = '^\d{4,}$'; Instances = $nicInstances }
    )
}

function Get-SynthDatastoreDatacenter {
    <# A datastore's datacenter, taken from the first of its hosts that has one. #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$Datastore,
        [Parameter(Mandatory)][hashtable]$Hosts
    )
    foreach ($hostId in @($Datastore.hosts)) {
        if ($Hosts.ContainsKey($hostId) -and $Hosts[$hostId].item.datacenter) { return $Hosts[$hostId].item.datacenter }
    }
    $null
}

function Get-SynthRubricValue {
    <# One property's value from a rubric, or $null. #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$Rubric,
        [Parameter(Mandatory)][string]$Name
    )
    $match = @($Rubric.properties | Where-Object { $_.name -eq $Name })
    if ($match.Count) { $match[0].value } else { $null }
}

function ConvertTo-SynthScrubbedValue {
    <#
    .SYNOPSIS
        Blanks addresses and network neighbours copied from a reference object.

    .DESCRIPTION
        Only keys that hold addresses are touched (IP, MAC, DNS, NTP, LLDP
        neighbour), so version numbers such as 9.1.0.0 are left alone. Addresses
        become documentation values and neighbour names become '-'.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Key,
        [AllowNull()]$Value
    )

    if ($Value -isnot [string] -or -not $Value) { return $Value }
    if ($Key -match '\|discoveryProtocol\|') { return '-' }
    if ($Key -notmatch '(?i)ip_?address|ipv6|mgmt_address|mac_address|dns|ntp|gateway') { return $Value }
    $text = [regex]::Replace($Value, '\b(?:\d{1,3}\.){3}\d{1,3}\b', '192.0.2.1')
    # A MAC also reads as IPv6, so both go in one pass with the MAC tried first at each position.
    [regex]::Replace($text, '\b(?<mac>(?:[0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2})\b|\bfe80::[0-9A-Fa-f:]+|\b(?:[0-9A-Fa-f]{1,4}:{1,2}){2,7}[0-9A-Fa-f]{1,4}\b', {
            param($m) if ($m.Groups['mac'].Success) { '00:00:00:00:00:00' } else { '2001:db8::1' }
        })
}

function ConvertTo-SynthGuid {
    <# A GUID derived from text, so the same object always gets the same UUID. #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$Text)
    $hash = [System.Security.Cryptography.SHA256]::HashData([System.Text.Encoding]::UTF8.GetBytes($Text))
    [guid]::new([byte[]]$hash[0..15]).ToString()
}

function ConvertTo-SynthMac {
    <# A MAC address in VMware's 00:50:56 range, derived from text. #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$Text)
    $hash = [System.Security.Cryptography.SHA256]::HashData([System.Text.Encoding]::UTF8.GetBytes($Text))
    '00:50:56:{0:x2}:{1:x2}:{2:x2}' -f ($hash[0] -band 0x3f), $hash[1], $hash[2]
}

function ConvertTo-SynthSampleList {
    <#
    .SYNOPSIS
        Turns key and value pairs into stat-content or property-content entries.

    .DESCRIPTION
        Numbers, and text that reads as a number, go as data; other text goes as
        values, which is how text metrics such as health|reports|hostd|state are
        stored. Entries without a value are left out.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Entry,
        [Parameter(Mandatory)][long]$Timestamp
    )

    foreach ($e in $Entry) {
        if ($null -eq $e.value) { continue }
        $number = 0.0
        $isNumber = $e.value -is [double] -or $e.value -is [int] -or $e.value -is [long] -or $e.value -is [decimal] -or $e.value -is [single]
        if (-not $isNumber -and $e.value -is [string]) {
            $isNumber = [double]::TryParse($e.value, [System.Globalization.NumberStyles]::Float, [cultureinfo]::InvariantCulture, [ref]$number)
        }
        if ($isNumber) {
            $data = if ($e.value -is [string]) { $number } else { [double]$e.value }
            @{ statKey = $e.key; timestamps = @($Timestamp); data = @($data) }
        }
        else {
            $text = if ($e.value -is [bool]) { ([string]$e.value).ToLowerInvariant() } else { [string]$e.value }
            @{ statKey = $e.key; timestamps = @($Timestamp); values = @($text) }
        }
    }
}

function ConvertTo-SynthResourceBody {
    <# The body that creates one planned object under a vCenter adapter instance. #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Object)

    @{
        description = 'vcfops-synth seed'
        resourceKey = @{
            name                = $Object.name
            adapterKindKey      = if ($Object.Contains('adapterKind') -and $Object.adapterKind) { $Object.adapterKind } else { 'VMWARE' }
            resourceKindKey     = $Object.kind
            resourceIdentifiers = @(foreach ($id in $Object.identifiers) {
                    @{ identifierType = @{ name = $id.name; dataType = 'STRING'; isPartOfUniqueness = [bool]$id.unique }; value = [string]$id.value }
                })
        }
    }
}

function Get-SynthSeedUniqueKey {
    <# What makes a planned object the same as one in Operations: its unique identifier's value, or its name when it has none. #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Object)
    $unique = @($Object.identifiers | Where-Object { $_.unique })
    if ($unique.Count) { "$($unique[0].name)=$($unique[0].value)" } else { "name=$($Object.name)" }
}

function Get-SynthExistingResource {
    <#
    .SYNOPSIS
        Returns the objects of a kind already in Operations, keyed as Get-SynthSeedUniqueKey keys a planned object.

    .DESCRIPTION
        Matching is on the unique identifier (VMEntityObjectID or SynthId), not
        the name, so a real object that shares a name with a synthetic one is
        never mistaken for it. Each value holds the resource ID and its name.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][string]$Kind,
        [string]$AdapterKind = 'VMWARE',
        [string]$AdapterInstanceId,
        [string]$IdentifierName
    )

    $found = @{}
    $page = 0
    while ($true) {
        $query = @{ adapterKind = $AdapterKind; resourceKind = $Kind; page = $page; pageSize = 1000 }
        if ($AdapterInstanceId) { $query.adapterInstanceId = $AdapterInstanceId }
        $response = Invoke-SynthOpsRequest -Method Get -Path 'resources' -Query $query
        $list = @($response.resourceList | Where-Object { $_ })
        foreach ($resource in $list) {
            $key = if ($IdentifierName) {
                $id = @($resource.resourceKey.resourceIdentifiers | Where-Object { $_.identifierType.name -eq $IdentifierName })
                if ($id.Count -and $id[0].value) { "$IdentifierName=$($id[0].value)" }
            }
            else { "name=$($resource.resourceKey.name)" }
            if ($key) { $found[$key] = @{ id = $resource.identifier; name = $resource.resourceKey.name } }
        }
        $total = if ($response.PSObject.Properties['pageInfo'] -and $response.pageInfo) { [int]$response.pageInfo.totalCount } else { $list.Count }
        $page++
        if ($list.Count -eq 0 -or $page * 1000 -ge $total) { break }
    }
    $found
}
