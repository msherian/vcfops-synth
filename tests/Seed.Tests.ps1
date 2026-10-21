# Pester 5 tests for the seed plan and the seed itself. Inventory and rubrics are invented; Invoke-SynthOpsRequest is mocked.
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Test helpers that only build objects.')]
param()

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '../src/VcfOpsSynth/VcfOpsSynth.psd1') -Force

    # A rubric as Get-SynthRubric loads it: one reference object's latest stats and properties.
    function New-TestRubric {
        param([string]$Kind, [hashtable]$Latest = @{}, [hashtable]$Property = @{})
        @{
            resourceKind = $Kind
            sourceName   = "ref-$Kind"
            latest       = @(foreach ($k in $Latest.Keys) { @{ key = $k; value = $Latest[$k] } })
            properties   = @(@{ name = 'config|name'; value = "ref-$Kind" }; @{ name = 'summary|parentVcenter'; value = 'vc-ref.example.test' }
                foreach ($k in $Property.Keys) { @{ name = $k; value = $Property[$k] } })
        }
    }

    function New-TestRubricSet {
        @{
            Datacenter                     = New-TestRubric 'Datacenter' @{ 'summary|number_vm' = 3 }
            ClusterComputeResource         = New-TestRubric 'ClusterComputeResource' @{ 'cpu|usage_average' = 12.5; 'cpu|capacity_provisioned' = 7; 'summary|total_number_hosts' = 7 } @{
                'summary|parentDatacenter' = 'ref-dc'; 'configuration|dasConfig|enabled' = 'Disabled'; 'configuration|drsConfig|enabled' = 'true'; 'configuration|dasConfig|admissionControlEnabled' = 'false'; 'configuration|dasConfig|hostFailoverLevel' = '2'
            }
            HostSystem                     = New-TestRubric 'HostSystem' @{
                'cpu|usage_average' = 20; 'cpu|usagemhz_average' = 7; 'mem|consumed_average' = 7; 'summary|total_number_vms' = 7; 'health|reports|hostd|state' = 'green'
                'net:vmnic0|received_average' = 5; 'net:vmnic1|received_average' = 6; 'net:Aggregate of all instances|received_average' = 11
                'storageAdapter:vmhba0|commandsAveraged_average' = 1
            } @{
                'summary|parentCluster' = 'ref-cluster'; 'summary|parentDatacenter' = 'ref-dc'
                'net:vmnic0|speed' = 25000; 'net:vmnic0|nicDriver' = 'refdrv'
                'net:vmk0|ip_address' = '10.20.30.40'; 'net:vmk0|mac_address' = 'aa:bb:cc:dd:ee:ff'; 'net:vmk0|port_group_key' = 'dvportgroup-ref'
                'net:vmk0|discoveryProtocol|cdp|systemName' = 'ref-switch-01'
                'config|network|dnsserver' = '10.0.0.53, fd00:1:2::53'
                'summary|version' = '9.1.0-25557999'; 'config|hyperThread|active' = 'false'; 'hardware|biosVersion' = 'ref-bios'; 'runtime|connectionState' = 'disconnected'; 'summary|version_4d' = '9.1.0.0.25557999'; 'config|product|apiVersion' = '9.1.0.0'; 'sys|build' = '25557999'
            }
            Datastore                      = New-TestRubric 'Datastore' @{ 'capacity|used_space' = 100 } @{ 'summary|type' = 'nfs'; 'summary|parentDatacenter' = 'ref-dc' }
            VmwareDistributedVirtualSwitch = New-TestRubric 'VmwareDistributedVirtualSwitch' @{ 'host:ref-esx|port_count' = 4 } @{ 'summary|version' = '7.0.0' }
            DistributedVirtualPortgroup    = New-TestRubric 'DistributedVirtualPortgroup' @{ 'port|used' = 2 } @{ 'config|policies|security|vlan_id' = '7'; 'config|policies|security|allow_promiscuous' = 'true' }
            VMFolder                       = New-TestRubric 'VMFolder' @{ 'summary|number_vm' = 1 } @{ 'summary|parentDatacenter' = 'ref-dc' }
            VirtualMachine                 = New-TestRubric 'VirtualMachine' @{
                'cpu|usage_average' = 33.3; 'mem|usage_average' = 50; 'guest|tools_status' = 'toolsOk'
                'virtualDisk:scsi0:0|read_average' = 1; 'virtualDisk:scsi0:3|read_average' = 2; 'virtualDisk:scsi0:3|write_average' = 3
                'virtualDisk:Aggregate of all instances|read_average' = 3
                'guestfilesystem:/ref|percentage' = 50
                'net:4000|usage_average' = 9
            } @{
                'virtualDisk:scsi0:0|label' = 'Hard disk 9'; 'virtualDisk:scsi0:0|configuredGB' = 999
                'guestfilesystem:/ref|capacity' = 10
                'net:4000|mac_address' = '00:50:56:aa:bb:cc'; 'net:4000|ip_address' = '10.9.8.7'; 'net:4000|portGroup' = 'ref-pg'
                'summary|guest|ipAddress' = '10.9.8.7'; 'summary|parentHost' = 'ref-esx'; 'summary|parentHostVersion' = '9.1.0'; 'summary|parentHostVersion4d' = '9.1.0.0'; 'config|createDate' = '2020-01-01T00:00:00'; 'summary|config|isTemplate' = 'true'
                'config|annotation' = 'Owned by ref-VirtualMachine on ref-esx'
            }
        }
    }

    # Every field the importer writes, so records can name only what a test cares about (the module runs under strict mode).
    $script:schema = @{
        datacenters = 'id,name'; clusters = 'id,name,datacenter,haEnabled,drsEnabled,config'
        hosts       = 'id,name,datacenter,cluster,cpuModel,cpuMhz,sockets,cores,memoryMiB,esxVersion,vendor,model,maintenance,config,baseline,nics,hbas,vmkernels'
        datastores  = 'id,name,type,capacityMiB,provisionedMiB,inUseMiB,hosts,config,baseline'; switches = 'id,name,kind,datacenter,version,mtu,ports,hosts,config'
        networks    = 'id,name,kind,switch,datacenter,vlan,hosts,config'; folders = 'id,name,datacenter,parent'; resourcePools = 'id,name,cluster,parent,cpu,memory'
        vms         = 'id,name,powerState,datacenter,cluster,host,datastores,folderId,resourcePoolId,config,cpuReadyPct,tier,application,profile,guestOs,hardwareVersion,toolsStatus,toolsVersion,cpu,memory,storage,nics,snapshots,baseline'
        cpu         = 'vcpus,sockets,coresPerSocket,capacityMhz,usageMhz,reservationMhz,limitMhz'; memory = 'sizeMiB,activeMiB,consumedMiB,balloonedMiB,swappedMiB,reservationMiB,limitMiB'
        storage     = 'provisionedMiB,inUseMiB,partitions,disks'; disks = 'label,capacityMiB,thin,mode,controller,unit,datastore'; partitions = 'disk,capacityMiB,consumedMiB'
        vmNics      = 'label,adapter,network,connected'; hostNics = 'device,driver,speedMbps,duplex,switch'; hbas = 'device,type,status,model,driver'; vmkernels = 'device,network,mtu'
    }
    function Complete-TestRecord {
        param($Record, [string]$Schema)
        foreach ($field in $script:schema[$Schema] -split ',') { if (-not $Record.Contains($field)) { $Record[$field] = $null } }
    }
    function Complete-TestInventory {
        param($Inventory)
        foreach ($collection in @($Inventory.Keys)) { foreach ($item in $Inventory[$collection]) { Complete-TestRecord $item $collection } }
        foreach ($h in $Inventory.hosts) {
            foreach ($n in @($h.nics)) { Complete-TestRecord $n 'hostNics' }
            foreach ($n in @($h.hbas)) { Complete-TestRecord $n 'hbas' }
            foreach ($n in @($h.vmkernels)) { Complete-TestRecord $n 'vmkernels' }
        }
        foreach ($vm in $Inventory.vms) {
            Complete-TestRecord $vm.cpu 'cpu'; Complete-TestRecord $vm.memory 'memory'; Complete-TestRecord $vm.storage 'storage'
            foreach ($d in @($vm.storage.disks)) { Complete-TestRecord $d 'disks' }
            foreach ($p in @($vm.storage.partitions)) { Complete-TestRecord $p 'partitions' }
            foreach ($n in @($vm.nics)) { Complete-TestRecord $n 'vmNics' }
        }
        $Inventory
    }

    # One datacenter's worth of inventory, plus references to hosts and datastores outside the plan.
    function New-TestInventory {
        $inventory = Complete-TestInventory @{
            datacenters   = @(@{ id = 'dc-aaaa000001'; name = 'dc-aaaa000001' })
            clusters      = @(@{ id = 'cluster-bbbb000001'; name = 'cluster-bbbb000001'; datacenter = 'dc-aaaa000001'; haEnabled = $true; drsEnabled = $false; config = [ordered]@{ admissionControl = 'True'; failoverLevel = '1' } })
            hosts         = @(@{
                    id = 'esx-cccc000001'; name = 'esx-cccc000001'; datacenter = 'dc-aaaa000001'; cluster = 'cluster-bbbb000001'
                    cpuModel = 'Test CPU'; cpuMhz = 2000; sockets = 2; cores = 16; memoryMiB = 1024; esxVersion = 'VMware ESXi 8.0.2 build-22380479'
                    vendor = 'Acme'; model = 'Box 1'; maintenance = $false; baseline = @{ cpuUsagePct = 30; memUsagePct = 50 }; config = [ordered]@{ htActive = 'True'; biosVersion = 'U30 v2.1' }
                    nics = @(@{ device = 'vmnic0'; driver = 'drv0'; speedMbps = 10000 }, @{ device = 'vmnic1'; driver = 'drv1'; speedMbps = 1000 }, @{ device = 'vmnic2'; driver = 'drv1'; speedMbps = 1000 })
                    hbas = @(@{ device = 'vmhba0'; driver = 'hbadrv' })
                    vmkernels = @(@{ device = 'vmk0'; network = 'net-dddd000001' })
                })
            datastores    = @(@{ id = 'ds-eeee000001'; name = 'ds-eeee000001'; type = 'VMFS'; capacityMiB = 2048; inUseMiB = 1024; provisionedMiB = 3072; hosts = @('esx-cccc000001') })
            switches      = @(
                @{ id = 'dvs-ffff000001'; name = 'dvs-ffff000001'; kind = 'distributed'; datacenter = 'dc-aaaa000001'; version = '8.0.0'; hosts = @('esx-cccc000001', 'esx-notinplan') }
                @{ id = 'vss-ffff000002'; name = 'vss-ffff000002'; kind = 'standard'; datacenter = 'dc-aaaa000001'; mtu = 1500; ports = 128; hosts = @('esx-cccc000001') }
            )
            networks      = @(
                @{ id = 'net-dddd000001'; name = 'net-dddd000001'; kind = 'distributed'; switch = 'dvs-ffff000001'; vlan = 120; config = [ordered]@{ allowPromiscuous = 'False' } }
                @{ id = 'net-dddd000002'; name = 'net-dddd000002'; kind = 'standard'; switch = ''; datacenter = 'dc-aaaa000001'; vlan = 5; hosts = @('esx-cccc000001', 'esx-notinplan') }
            )
            folders       = @(
                @{ id = 'folder-1111000001'; name = 'folder-1111000001'; datacenter = 'dc-aaaa000001'; parent = '' }
                @{ id = 'folder-1111000002'; name = 'folder-1111000002'; datacenter = 'dc-aaaa000001'; parent = 'folder-1111000001' }
            )
            resourcePools = @(@{ id = 'rp-2222000001'; name = 'Resources'; cluster = 'cluster-bbbb000001' })
            vms           = @(
                @{
                    id = 'vm-3333000001'; name = 'vm-3333000001'; powerState = 'poweredOn'; datacenter = 'dc-aaaa000001'; cluster = 'cluster-bbbb000001'
                    host = 'esx-cccc000001'; datastores = @('ds-eeee000001'); folderId = 'folder-1111000002'; resourcePoolId = 'rp-2222000001'
                    guestOs = 'Microsoft Windows Server 2022 (64-bit)'; hardwareVersion = 19; toolsVersion = 12345; config = [ordered]@{ creationDate = '2024-01-02T03:04:05' }
                    cpu = @{ vcpus = 4; sockets = 2; coresPerSocket = 2; capacityMhz = 8000; usageMhz = 1000; reservationMhz = 0; limitMhz = $null }
                    memory = @{ sizeMiB = 8192; activeMiB = 2048; consumedMiB = 4096; reservationMiB = 0; limitMiB = $null }
                    baseline = @{ cpuUsagePct = 12.5; memActivePct = 25; perf = @{ readIopsAvg = 40; writeIopsAvg = 10; readLatencyAvgMs = 1.5 } }
                    storage = @{
                        provisionedMiB = 61440
                        disks = @(@{ label = 'Hard disk 1'; capacityMiB = 40960; thin = $true; datastore = 'ds-eeee000001' }, @{ label = 'Hard disk 2'; capacityMiB = 20480; thin = $false; datastore = 'ds-eeee000001' })
                        partitions = @(@{ capacityMiB = 40960; consumedMiB = 10240 }, @{ capacityMiB = 20480; consumedMiB = 5120 })
                    }
                    nics = @(@{ network = 'net-dddd000001'; connected = $true }, @{ network = 'net-dddd000002'; connected = $false })
                }
                @{
                    id = 'vm-3333000002'; name = 'vm-3333000002'; powerState = 'poweredOff'; datacenter = 'dc-aaaa000001'
                    host = 'esx-notinplan'; datastores = @('ds-notinplan'); folderId = 'folder-1111000001'
                    guestOs = 'Ubuntu Linux (64-bit)'
                    cpu = @{ vcpus = 1 }; memory = @{ sizeMiB = 1024 }
                    storage = @{ disks = @(@{ capacityMiB = 1024; datastore = 'ds-eeee000001' }); partitions = @(@{ capacityMiB = 1024; consumedMiB = 0 }, @{ capacityMiB = 512; consumedMiB = 256 }) }
                    nics = @()
                }
            )
        }
        # Set after Complete-TestInventory, which treats every key as a collection of records.
        $inventory.source = @{ vcenter = 'vc-customer.example.test' }
        $inventory
    }

    function Get-PlanObject {
        param($Plan, [string]$Key)
        @($Plan.objects | Where-Object { $_.key -eq $Key })[0]
    }

    function Get-Entry {
        param($List, [string]$Key)
        $match = @($List | Where-Object { $_.key -eq $Key })
        if ($match.Count) { $match[0].value } else { $null }
    }
}

Describe 'New-SynthSeedPlan' {
    BeforeAll {
        $script:plan = New-SynthSeedPlan -Inventory (New-TestInventory) -Rubric (New-TestRubricSet) -VcId 'vc-uuid-0001' -Prefix 'Synth-' -PhysicalDatacenter 'Test PDC'
        $script:vm = Get-PlanObject $script:plan 'vm-3333000001'
        $script:linuxVm = Get-PlanObject $script:plan 'vm-3333000002'
        $script:esx = Get-PlanObject $script:plan 'esx-cccc000001'
    }

    It 'plans one object per inventory item of a VMWARE kind and counts the rest as skipped' {
        $counts = @{}
        $script:plan.objects | Group-Object { $_.kind } | ForEach-Object { $counts[$_.Name] = $_.Count }
        $counts.Datacenter | Should -Be 1
        $counts.ClusterComputeResource | Should -Be 1
        $counts.HostSystem | Should -Be 1
        $counts.Datastore | Should -Be 1
        $counts.VmwareDistributedVirtualSwitch | Should -Be 1
        $counts.DistributedVirtualPortgroup | Should -Be 1
        $counts.StandardSwitch | Should -Be 1
        $counts.StandardPortgroup | Should -Be 1
        $counts.PhysicalDatacenter | Should -Be 1
        $counts.VMFolder | Should -Be 2
        $counts.VirtualMachine | Should -Be 2
        $script:plan.skipped.rootResourcePools | Should -Be 1
        $script:plan.skipped.userResourcePools | Should -Be 0
    }

    It 'counts user-created resource pools apart from root pools, and creates neither' {
        $inventory = New-TestInventory
        $inventory.resourcePools += Complete-TestInventory @{ resourcePools = @(@{ id = 'rp-2222000002'; name = 'rp-2222000002'; cluster = 'cluster-bbbb000001'; parent = 'rp-2222000001' }) } | ForEach-Object { $_.resourcePools }
        $plan = New-SynthSeedPlan -Inventory $inventory -Rubric (New-TestRubricSet) -VcId 'vc-uuid-0001'
        $plan.skipped.rootResourcePools | Should -Be 1
        $plan.skipped.userResourcePools | Should -Be 1
        @($plan.objects | Where-Object { $_.key -like 'rp-*' }).Count | Should -Be 0
    }

    It 'keeps inventory names exactly by default' {
        $plain = New-SynthSeedPlan -Inventory (New-TestInventory) -Rubric (New-TestRubricSet) -VcId 'vc-uuid-0001'
        (Get-PlanObject $plain 'vm-3333000001').name | Should -Be 'vm-3333000001'
        Get-Entry (Get-PlanObject $plain 'esx-cccc000001').properties 'summary|parentCluster' | Should -Be 'cluster-bbbb000001'
        Get-Entry (Get-PlanObject $plain 'vm-3333000001').properties 'net:4000|portGroup' | Should -Be 'net-dddd000001'
        @($plain.objects | Where-Object kind -eq 'PhysicalDatacenter').Count | Should -Be 0
    }

    It 'tags every object as synthetic, rubric or not' {
        foreach ($o in $script:plan.objects) {
            Get-Entry $o.properties 'summary|tag' | Should -Be '[vcfops-synth-synthetic]' -Because "$($o.kind) $($o.name)"
            (Get-Entry $o.properties 'summary|tagJson' | ConvertFrom-Json).name | Should -Be 'synthetic'
        }
        $other = New-SynthSeedPlan -Inventory (New-TestInventory) -Rubric (New-TestRubricSet) -VcId 'vc-uuid-0001' -Tag @{ Category = 'Lab'; Name = 'Fake' }
        Get-Entry (Get-PlanObject $other 'vm-3333000001').properties 'summary|tag' | Should -Be '[Lab-Fake]'
    }

    It 'puts standard switches and port groups under the custom adapter kind with inventory properties' {
        $vss = Get-PlanObject $script:plan 'vss-ffff000002'
        $pg = Get-PlanObject $script:plan 'net-dddd000002'
        $vss.adapterKind | Should -Be 'VcfOpsSynth'
        $pg.adapterKind | Should -Be 'VcfOpsSynth'
        $script:vm.adapterKind | Should -Be 'VMWARE'
        $vss.identifiers | Should -HaveCount 1
        $vss.identifiers[0].name | Should -Be 'SynthId'
        $vss.identifiers[0].value | Should -Be 'vss-ffff000002'
        $vss.stats | Should -HaveCount 0
        Get-Entry $vss.properties 'config|mtu' | Should -Be 1500
        Get-Entry $vss.properties 'summary|parentHost' | Should -Be 'Synth-esx-cccc000001'
        Get-Entry $pg.properties 'config|policies|security|vlan_id' | Should -Be '5'
        Get-Entry $pg.properties 'config|name' | Should -Be 'Synth-net-dddd000002'
    }

    It 'adds a Physical Data Center with no identifiers when one is named' {
        $pdc = Get-PlanObject $script:plan 'pdc-synth'
        $pdc.kind | Should -Be 'PhysicalDatacenter'
        $pdc.adapterKind | Should -Be 'VMWARE'
        $pdc.name | Should -Be 'Synth-Test PDC'
        @($pdc.identifiers).Count | Should -Be 0
        $script:plan.objects[0].kind | Should -Be 'PhysicalDatacenter'
    }

    It 'names every object with the prefix and gives it a vCenter-style ID' {
        $script:plan.objects | ForEach-Object { $_.name | Should -BeLike 'Synth-*' }
        $script:vm.name | Should -Be 'Synth-vm-3333000001'
        $script:vm.moid | Should -Be 'vm-synth-3333000001'
        $script:esx.moid | Should -Be 'host-synth-cccc000001'
        (Get-PlanObject $script:plan 'cluster-bbbb000001').moid | Should -Be 'domain-c-synth-bbbb000001'
        $custom = New-SynthSeedPlan -Inventory (New-TestInventory) -Rubric (New-TestRubricSet) -VcId 'vc-uuid-0001' -Prefix 'Lab-'
        (Get-PlanObject $custom 'vm-3333000001').name | Should -Be 'Lab-vm-3333000001'
    }

    It 'gives each kind the identifiers the vCenter adapter uses' {
        $ids = @{}; $script:vm.identifiers | ForEach-Object { $ids[$_.name] = $_ }
        $ids.VMEntityObjectID.value | Should -Be 'vm-synth-3333000001'
        $ids.VMEntityObjectID.unique | Should -BeTrue
        $ids.VMEntityVCID.value | Should -Be 'vc-uuid-0001'
        $ids.VMEntityVCID.unique | Should -BeTrue
        $ids.VMEntityName.value | Should -Be 'Synth-vm-3333000001'
        $ids.VMEntityName.unique | Should -BeFalse
        $ids.VMEntityInstanceUUID.value | Should -Match '^[0-9a-f]{8}-[0-9a-f]{4}-'
        $ids.Keys | Should -Contain 'isPingEnabled'

        $folderIds = @((Get-PlanObject $script:plan 'folder-1111000001').identifiers | ForEach-Object { $_.name })
        $folderIds | Should -Not -Contain 'VMEntityName'
        $dsIds = @((Get-PlanObject $script:plan 'ds-eeee000001').identifiers)
        @($dsIds | Where-Object { $_.name -eq 'DataStrorePath' })[0].value | Should -Be 'ds:///vmfs/volumes/datastore-synth-eeee000001/'
    }

    It 'is stable: the same inventory gives the same identifiers' {
        $again = New-SynthSeedPlan -Inventory (New-TestInventory) -Rubric (New-TestRubricSet) -VcId 'vc-uuid-0001' -Prefix 'Synth-' -PhysicalDatacenter 'Test PDC'
        ((Get-PlanObject $again 'vm-3333000001').identifiers | ConvertTo-Json -Compress) | Should -Be ($script:vm.identifiers | ConvertTo-Json -Compress)
    }

    It 'expands virtual disk keys to the VM''s own disks only' {
        $keys = @($script:vm.stats | ForEach-Object { $_.key })
        $keys | Should -Contain 'virtualDisk:scsi0:0|read_average'
        $keys | Should -Contain 'virtualDisk:scsi0:1|read_average'
        $keys | Should -Contain 'virtualDisk:scsi0:1|write_average'
        $keys | Should -Not -Contain 'virtualDisk:scsi0:3|read_average'
        $keys | Should -Contain 'virtualDisk:Aggregate of all instances|read_average'
        Get-Entry $script:vm.properties 'virtualDisk:scsi0:0|configuredGB' | Should -Be 40
        Get-Entry $script:vm.properties 'virtualDisk:scsi0:1|label' | Should -Be 'Hard disk 2'
        @($script:linuxVm.stats | Where-Object { $_.key -like 'virtualDisk:scsi*|read_average' }).Count | Should -Be 1
    }

    It 'expands guest file systems with drive letters on Windows and mount points elsewhere' {
        Get-Entry $script:vm.stats 'guestfilesystem:C:\|percentage' | Should -Be 25
        Get-Entry $script:vm.properties 'guestfilesystem:D:\|capacity' | Should -Be 20
        Get-Entry $script:linuxVm.stats 'guestfilesystem:/|percentage' | Should -Be 0
        Get-Entry $script:linuxVm.stats 'guestfilesystem:/data1|percentage' | Should -Be 50
        @($script:vm.stats | Where-Object { $_.key -like 'guestfilesystem:/ref*' }).Count | Should -Be 0
    }

    It 'expands network adapters with their own port groups and generated MACs' {
        Get-Entry $script:vm.properties 'net:4000|portGroup' | Should -Be 'Synth-net-dddd000001'
        Get-Entry $script:vm.properties 'net:4001|portGroup' | Should -Be 'Synth-net-dddd000002'
        Get-Entry $script:vm.properties 'net:4001|mac_address' | Should -Match '^00:50:56:[0-3][0-9a-f]:[0-9a-f]{2}:[0-9a-f]{2}$'
        Get-Entry $script:vm.properties 'net:4000|mac_address' | Should -Not -Be '00:50:56:aa:bb:cc'
        $script:vm.stats.key | Should -Contain 'net:4001|usage_average'
        @($script:linuxVm.stats | Where-Object { $_.key -like 'net:4*' }).Count | Should -Be 0
    }

    It 'expands host NICs, VMkernel adapters and HBAs, and switch member hosts within the plan' {
        $keys = @($script:esx.stats | ForEach-Object { $_.key })
        $keys | Should -Contain 'net:vmnic2|received_average'
        $keys | Should -Contain 'net:Aggregate of all instances|received_average'
        Get-Entry $script:esx.properties 'net:vmnic2|speed' | Should -Be 1000
        Get-Entry $script:esx.properties 'net:vmnic1|nicDriver' | Should -Be 'drv1'
        Get-Entry $script:esx.properties 'net:vmk0|port_group_key' | Should -Be 'dvportgroup-synth-dddd000001'
        $keys | Should -Contain 'storageAdapter:vmhba0|commandsAveraged_average'
        $dvsKeys = @((Get-PlanObject $script:plan 'dvs-ffff000001').stats | ForEach-Object { $_.key })
        $dvsKeys | Should -Be @('host:Synth-esx-cccc000001|port_count')
    }

    It 'fills identity properties from the inventory' {
        Get-Entry $script:vm.properties 'summary|parentHost' | Should -Be 'Synth-esx-cccc000001'
        Get-Entry $script:vm.properties 'config|name' | Should -Be 'Synth-vm-3333000001'
        Get-Entry $script:esx.properties 'summary|parentCluster' | Should -Be 'Synth-cluster-bbbb000001'
        Get-Entry $script:esx.properties 'summary|version' | Should -Be '8.0.2-22380479'
        Get-Entry $script:esx.properties 'summary|version_4d' | Should -Be '8.0.2.0.22380479'
        Get-Entry $script:esx.properties 'config|product|apiVersion' | Should -Be '8.0.2.0'
        Get-Entry $script:esx.properties 'sys|build' | Should -Be '22380479'
        Get-Entry $script:vm.properties 'summary|parentHostVersion' | Should -Be '8.0.2'
        Get-Entry $script:vm.properties 'summary|parentHostVersion4d' | Should -Be '8.0.2.0'
        ($script:plan.objects | ForEach-Object { $_.properties } | ForEach-Object { [string]$_.value }) -join ' ' | Should -Not -Match '9\.1\.0|25557999'
        Get-Entry (Get-PlanObject $script:plan 'cluster-bbbb000001').properties 'configuration|dasConfig|enabled' | Should -Be 'Enabled'
        Get-Entry (Get-PlanObject $script:plan 'net-dddd000001').properties 'config|policies|security|vlan_id' | Should -Be '120'
    }

    It 'never copies a value from the rubric: inventory, derived or placeholder only' {
        # Properties the inventory has nothing for get a neutral value by type.
        Get-Entry $script:vm.properties 'config|annotation' | Should -Be '-'
        Get-Entry $script:esx.properties 'net:vmk0|ip_address' | Should -Be '-'
        Get-Entry $script:esx.properties 'net:vmk0|mac_address' | Should -Be '-'
        Get-Entry $script:esx.properties 'net:vmk0|discoveryProtocol|cdp|systemName' | Should -Be '-'
        Get-Entry $script:esx.properties 'config|network|dnsserver' | Should -Be '-'
        Get-Entry $script:vm.properties 'summary|guest|ipAddress' | Should -Be '-'
        Get-Entry $script:vm.properties 'net:4000|ip_address' | Should -Be '-'
        Get-Entry $script:vm.properties 'summary|parentVcenter' | Should -Be 'vc-customer.example.test'
        # Text metrics with no source are placeholders too; numbers are derived or zero.
        Get-Entry $script:esx.stats 'health|reports|hostd|state' | Should -Be '-'
        Get-Entry $script:vm.stats 'guest|tools_status' | Should -Be '-'
        Get-Entry $script:vm.stats 'virtualDisk:scsi0:1|write_average' | Should -Be 0
        Get-Entry (Get-PlanObject $script:plan 'cluster-bbbb000001').stats 'cpu|usage_average' | Should -Be 0
        $rubric = New-TestRubricSet
        $copied = foreach ($o in $script:plan.objects) {
            if (-not $rubric.ContainsKey($o.kind)) { continue }
            $ref = @{}; foreach ($p in $rubric[$o.kind].properties) { $ref[$p.name] = [string]$p.value }
            foreach ($p in $o.properties) {
                if ($ref.ContainsKey($p.key) -and [string]$p.value -eq $ref[$p.key] -and $ref[$p.key] -notin '-', '0', 'false', 'true', '') { "$($o.kind) $($p.key)" }
            }
        }
        @($copied) | Should -BeNullOrEmpty
        ($script:plan.objects | ForEach-Object { $_.properties; $_.stats } | ForEach-Object { [string]$_.value }) -join "`n" | Should -Not -Match 'ref-|10\.(9|20|0)\.|aa:bb:cc|toolsOk|green'
    }

    It 'derives current stats from the inventory: VM usage, host over capacity, cluster and datastore roll-ups' {
        Get-Entry $script:vm.stats 'cpu|usage_average' | Should -Be 12.5
        Get-Entry $script:vm.stats 'mem|usage_average' | Should -Be 25
        Get-Entry $script:linuxVm.stats 'cpu|usage_average' | Should -Be 0
        Get-Entry $script:esx.stats 'cpu|usage_average' | Should -Be 30
        Get-Entry $script:esx.stats 'cpu|usagemhz_average' | Should -Be 9600
        Get-Entry $script:esx.stats 'mem|consumed_average' | Should -Be 524288
        Get-Entry $script:esx.stats 'summary|total_number_vms' | Should -Be 1
        $cluster = Get-PlanObject $script:plan 'cluster-bbbb000001'
        Get-Entry $cluster.stats 'cpu|capacity_provisioned' | Should -Be 32000
        Get-Entry $cluster.stats 'summary|total_number_hosts' | Should -Be 1
        $ds = Get-PlanObject $script:plan 'ds-eeee000001'
        Get-Entry $ds.stats 'capacity|used_space' | Should -Be 1
    }

    It 'maps RVTools configuration onto Operations properties' {
        $cluster = Get-PlanObject $script:plan 'cluster-bbbb000001'
        Get-Entry $cluster.properties 'configuration|dasConfig|admissionControlEnabled' | Should -Be 'true'
        Get-Entry $cluster.properties 'configuration|dasConfig|hostFailoverLevel' | Should -Be '1'
        Get-Entry $script:esx.properties 'config|hyperThread|active' | Should -Be 'true'
        Get-Entry $script:esx.properties 'hardware|biosVersion' | Should -Be 'U30 v2.1'
        Get-Entry $script:esx.properties 'runtime|connectionState' | Should -Be 'connected'
        Get-Entry (Get-PlanObject $script:plan 'net-dddd000001').properties 'config|policies|security|allow_promiscuous' | Should -Be 'false'
        Get-Entry $script:vm.properties 'config|createDate' | Should -Be '2024-01-02T03:04:05'
        Get-Entry $script:vm.properties 'summary|config|isTemplate' | Should -Be 'false'
        # No config record: the placeholder, not the rubric's value.
        Get-Entry $script:linuxVm.properties 'config|createDate' | Should -Be '-'
    }

    It 'writes the VM''s tier, application and profile as the toolset''s own properties' {
        $inventory = New-TestInventory
        $inventory.vms[0].tier = 'Gold'; $inventory.vms[0].application = 'Payments'; $inventory.vms[0].profile = 'steady'
        $vm = Get-PlanObject (New-SynthSeedPlan -Inventory $inventory -Rubric (New-TestRubricSet) -VcId 'vc-uuid-0001') 'vm-3333000001'
        "$(Get-Entry $vm.properties 'vcfops-synth|tier') $(Get-Entry $vm.properties 'vcfops-synth|application') $(Get-Entry $vm.properties 'vcfops-synth|profile')" | Should -Be 'Gold Payments steady'
        Get-Entry (Get-PlanObject (New-SynthSeedPlan -Inventory (New-TestInventory) -Rubric (New-TestRubricSet) -VcId 'vc-uuid-0001') 'vm-3333000001').properties 'vcfops-synth|tier' | Should -BeNullOrEmpty
    }

    It 'writes several tags, the synthetic marker and the project' {
        $tagged = New-SynthSeedPlan -Inventory (New-TestInventory) -Rubric (New-TestRubricSet) -VcId 'vc-uuid-0001' -Tag @(@{ Category = 'vcfops-synth'; Name = 'synthetic' }, @{ Category = 'Project'; Name = '2026.0001 Example Ltd - OPP-1' })
        $o = Get-PlanObject $tagged 'vm-3333000001'
        Get-Entry $o.properties 'summary|tag' | Should -Be '[vcfops-synth-synthetic, Project-2026.0001 Example Ltd - OPP-1]'
        @(Get-Entry $o.properties 'summary|tagJson' | ConvertFrom-Json).category | Should -Be @('vcfops-synth', 'Project')
    }

    It 'links only objects in the plan, parents to children' {
        $keys = @($script:plan.objects | ForEach-Object { $_.key }) + '@vcenter'
        foreach ($entry in $script:plan.links) {
            $keys | Should -Contain $entry.parent
            foreach ($child in $entry.children) { $keys | Should -Contain $child }
        }
        $childrenOf = @{}; $script:plan.links | ForEach-Object { $childrenOf[$_.parent] = @($_.children) }
        $childrenOf['dc-aaaa000001'] | Should -Contain 'cluster-bbbb000001'
        $childrenOf['dc-aaaa000001'] | Should -Contain 'folder-1111000001'
        $childrenOf['folder-1111000001'] | Should -Contain 'folder-1111000002'
        $childrenOf['cluster-bbbb000001'] | Should -Be @('esx-cccc000001')
        $childrenOf['esx-cccc000001'] | Should -Contain 'ds-eeee000001'
        $childrenOf['esx-cccc000001'] | Should -Contain 'vm-3333000001'
        $childrenOf['dvs-ffff000001'] | Should -Be @('net-dddd000001')
        $childrenOf['net-dddd000001'] | Should -Be @('vm-3333000001')
        $childrenOf['@vcenter'] | Should -Be @('dc-aaaa000001')
        $childrenOf['pdc-synth'] | Should -Be @('dc-aaaa000001')
        $childrenOf['esx-cccc000001'] | Should -Contain 'vss-ffff000002'
        $childrenOf['esx-cccc000001'] | Should -Contain 'net-dddd000002'
        $childrenOf['net-dddd000002'] | Should -Be @('vm-3333000001')
        $childrenOf.Keys | Should -Not -Contain 'esx-notinplan'
        $childrenOf.Keys | Should -Not -Contain 'rp-2222000001'
        # The second VM's host and datastore are not in the plan; only its folder links to it.
        @($script:plan.links | Where-Object { $_.children -contains 'vm-3333000002' } | ForEach-Object { $_.parent }) | Should -Be @('folder-1111000001')
    }
}

Describe 'Get-SynthPlaceholder' {
    It 'reads only the type of the rubric value' {
        InModuleScope VcfOpsSynth {
            Get-SynthPlaceholder -Value 'lab-host-01.example.test' | Should -Be '-'
            Get-SynthPlaceholder -Value 42.5 | Should -Be 0
            Get-SynthPlaceholder -Value '42.5' | Should -Be 0
            Get-SynthPlaceholder -Value 'true' | Should -Be 'false'
            Get-SynthPlaceholder -Value $true | Should -BeFalse
            Get-SynthPlaceholder -Value '9.1.0.0' | Should -Be '-'
            Get-SynthPlaceholder -Value $null -Metric | Should -Be 0
        }
    }
}

Describe 'Get-SynthProjectName' {
    It 'takes the deepest YYYY.#### ... OPP-n folder of the path' {
        InModuleScope VcfOpsSynth {
            Get-SynthProjectName -Path 'C:\Projects\2026.0001 Example Ltd  Refresh - OPP-10001\Exports\rvtools.xlsx' | Should -Be '2026.0001 Example Ltd  Refresh - OPP-10001'
            Get-SynthProjectName -Path '/mnt/share/2025.0420 Other Co - OPP-7/rv.xlsx' | Should -Be '2025.0420 Other Co - OPP-7'
            Get-SynthProjectName -Path 'C:\data\rvtools.xlsx' | Should -BeNullOrEmpty
            Get-SynthProjectName -Path '' | Should -BeNullOrEmpty
        }
    }
}

Describe 'ConvertTo-SynthSampleList' {
    It 'sends numbers, and text that reads as a number, as data and other text as values' {
        InModuleScope VcfOpsSynth {
            $list = @(ConvertTo-SynthSampleList -Timestamp 1000 -Entry @(
                    @{ key = 'a'; value = 1.5 }, @{ key = 'b'; value = '42' }, @{ key = 'c'; value = 'green' }, @{ key = 'd'; value = $true }, @{ key = 'e'; value = $null }
                ))
            $list.Count | Should -Be 4
            $list[0].data | Should -Be @(1.5)
            $list[1].data | Should -Be @(42)
            $list[2].values | Should -Be @('green')
            $list[2].Contains('data') | Should -BeFalse
            $list[3].values | Should -Be @('true')
            $list[0].timestamps | Should -Be @(1000)
        }
    }
}

Describe 'Invoke-SynthSeed' {
    BeforeAll {
        $script:plan = New-SynthSeedPlan -Inventory (New-TestInventory) -Rubric (New-TestRubricSet) -VcId 'vc-uuid-0001' -PhysicalDatacenter 'Test PDC'

        # A resource as GET /api/resources lists it.
        function New-TestResource {
            param([string]$Id, [string]$Name, [string]$IdentifierName, [string]$Value)
            $identifiers = if ($IdentifierName) { @(@{ identifierType = @{ name = $IdentifierName }; value = $Value }) } else { @() }
            @{ identifier = $Id; resourceKey = @{ name = $Name; resourceIdentifiers = $identifiers } }
        }
    }

    BeforeEach {
        $script:posts = [System.Collections.Generic.List[object]]::new()
        $script:gets = [System.Collections.Generic.List[object]]::new()
        # The datacenter and host exist from an earlier run; a real VM shares a planned VM's name but not its ID.
        Mock -ModuleName VcfOpsSynth Invoke-SynthOpsRequest {
            $script:gets.Add($Query)
            $existing = switch ($Query.resourceKind) {
                'Datacenter' { @(New-TestResource 'ops-dc-existing' 'dc-aaaa000001' 'VMEntityObjectID' 'datacenter-synth-aaaa000001') }
                'HostSystem' { @((New-TestResource 'ops-esx-existing' 'old-esx-name' 'VMEntityObjectID' 'host-synth-cccc000001'), (New-TestResource 'ops-other' 'esx-other' 'VMEntityObjectID' 'host-42')) }
                'VirtualMachine' { @(New-TestResource 'ops-real-vm' 'vm-3333000001' 'VMEntityObjectID' 'vm-1001') }
                # Operations stores names with runs of spaces collapsed.
                'VMFolder' { @(New-TestResource 'ops-folder-existing' ' folder-1111000001 ' 'VMEntityObjectID' 'group-v-synth-1111000001') }
                default { @() }
            }
            [pscustomobject]@{ resourceList = $existing; pageInfo = [pscustomobject]@{ totalCount = @($existing).Count } }
        } -ParameterFilter { $Method -eq 'Get' }
        Mock -ModuleName VcfOpsSynth Invoke-SynthOpsRequest {
            $script:posts.Add(@{ Path = $Path; Body = $Body })
            if ($Path -like 'resources/adapters/*' -or $Path -like 'resources/adapterkinds/*') { [pscustomobject]@{ identifier = "ops-$($Body.resourceKey.resourceKindKey)-$($Body.resourceKey.name)" } }
        } -ParameterFilter { $Method -eq 'Post' }
    }

    It 'skips objects that already exist by identifier, not by name, and creates the rest' {
        $result = Invoke-SynthSeed -Plan $script:plan -AdapterInstanceId 'adapter-1'

        $result.existing.Datacenter | Should -Be 1
        $result.existing.HostSystem | Should -Be 1
        $result.created.Datacenter | Should -Be 0
        $result.created.HostSystem | Should -Be 0
        # The real VM with the same name is not mistaken for the planned one.
        $result.created.VirtualMachine | Should -Be 2
        $result.ids['vm-3333000001'] | Should -Not -Be 'ops-real-vm'
        $result.created.VMFolder | Should -Be 1
        $result.existing.VMFolder | Should -Be 1
        $result.failed.Count | Should -Be 0
        $result.ids['dc-aaaa000001'] | Should -Be 'ops-dc-existing'
        $result.ids['esx-cccc000001'] | Should -Be 'ops-esx-existing'
        $result.renamed | Should -HaveCount 1
        $result.renamed[0] | Should -BeLike "HostSystem 'old-esx-name' is planned as 'esx-cccc000001'*"
    }

    It 'creates VMWARE kinds under the adapter instance and the toolset''s kinds under their adapter kind, foundations first' {
        $null = Invoke-SynthSeed -Plan $script:plan -AdapterInstanceId 'adapter-1'

        $creates = @($script:posts | Where-Object { $_.Path -like 'resources/adapters/*' -or $_.Path -like 'resources/adapterkinds/*' })
        $creates.Count | Should -Be 10
        $native = @($creates | Where-Object { $_.Path -eq 'resources/adapters/adapter-1' })
        $custom = @($creates | Where-Object { $_.Path -eq 'resources/adapterkinds/VcfOpsSynth' })
        $native.Count | Should -Be 8
        @($custom | ForEach-Object { $_.Body.resourceKey.resourceKindKey }) | Should -Be @('StandardSwitch', 'StandardPortgroup')
        @($custom | ForEach-Object { $_.Body.resourceKey.adapterKindKey }) | Should -Be @('VcfOpsSynth', 'VcfOpsSynth')
        $kinds = [System.Collections.Generic.List[string]]@($creates | ForEach-Object { $_.Body.resourceKey.resourceKindKey })
        $kinds[0] | Should -Be 'PhysicalDatacenter'
        $kinds.IndexOf('Datastore') | Should -BeLessThan $kinds.IndexOf('VmwareDistributedVirtualSwitch')
        $kinds.IndexOf('VirtualMachine') | Should -Be ($kinds.Count - 2)
        @($script:gets | Where-Object { $_.resourceKind -eq 'StandardSwitch' })[0].ContainsKey('adapterInstanceId') | Should -BeFalse
    }

    It 'pushes stats where there are any, properties always, text as values' {
        $null = Invoke-SynthSeed -Plan $script:plan -AdapterInstanceId 'adapter-1'

        # Ten created; the Physical Data Center and the two standard objects have no rubric stats.
        @($script:posts | Where-Object { $_.Path -like 'resources/*/stats' }).Count | Should -Be 7
        @($script:posts | Where-Object { $_.Path -like 'resources/*/properties' }).Count | Should -Be 10
        $vmStats = @($script:posts | Where-Object { $_.Path -eq 'resources/ops-VirtualMachine-vm-3333000001/stats' })[0].Body.'stat-content'
        $tools = @($vmStats | Where-Object { $_.statKey -eq 'guest|tools_status' })[0]
        $tools.values | Should -Be @('-')
        $tools.Contains('data') | Should -BeFalse
        @($vmStats | Where-Object { $_.statKey -eq 'cpu|usage_average' })[0].data | Should -Be @(12.5)
        $vssProps = @($script:posts | Where-Object { $_.Path -eq 'resources/ops-StandardSwitch-vss-ffff000002/properties' })[0].Body.'property-content'
        @($vssProps | Where-Object { $_.statKey -eq 'summary|tag' })[0].values | Should -Be @('[vcfops-synth-synthetic]')
        @($script:posts | Where-Object { $_.Path -like 'resources/ops-esx-existing/*' -and $_.Path -notlike '*/relationships/*' }).Count | Should -Be 0
    }

    It 'links parents to children using only plan IDs and the adapter instance' {
        $result = Invoke-SynthSeed -Plan $script:plan -AdapterInstanceId 'adapter-1'

        $links = @($script:posts | Where-Object { $_.Path -like 'resources/*/relationships/children' })
        $known = @($result.ids.Values)
        foreach ($post in $links) {
            ($post.Path -replace '^resources/|/relationships/children$', '') | Should -BeIn $known
            foreach ($uuid in $post.Body.uuids) { $uuid | Should -BeIn $known }
        }
        $known | Should -Not -Contain 'ops-other'
        $known | Should -Not -Contain 'ops-real-vm'
        @($links | Where-Object { $_.Path -eq 'resources/adapter-1/relationships/children' })[0].Body.uuids | Should -Be @('ops-dc-existing')
        @($links | Where-Object { $_.Path -eq 'resources/ops-PhysicalDatacenter-Test PDC/relationships/children' })[0].Body.uuids | Should -Be @('ops-dc-existing')
        @($links | Where-Object { $_.Path -eq 'resources/ops-dc-existing/relationships/children' })[0].Body.uuids | Should -Contain 'ops-ClusterComputeResource-cluster-bbbb000001'
        $result.links | Should -Be (($script:plan.links | ForEach-Object { @($_.children).Count } | Measure-Object -Sum).Sum)
    }

    It 'refreshes the properties and stats of objects already there only when asked' {
        $null = Invoke-SynthSeed -Plan $script:plan -AdapterInstanceId 'adapter-1'
        @($script:posts | Where-Object { $_.Path -eq 'resources/ops-esx-existing/properties' }).Count | Should -Be 0

        $script:posts.Clear()
        $result = Invoke-SynthSeed -Plan $script:plan -AdapterInstanceId 'adapter-1' -Refresh
        $result.refreshed | Should -Be 3
        $hostProps = @($script:posts | Where-Object { $_.Path -eq 'resources/ops-esx-existing/properties' })[0].Body.'property-content'
        @($hostProps | Where-Object { $_.statKey -eq 'summary|version_4d' })[0].values | Should -Be @('8.0.2.0.22380479')
        @($script:posts | Where-Object { $_.Path -eq 'resources/ops-esx-existing/stats' }).Count | Should -Be 1
    }

    It 'creates nothing with -WhatIf' {
        $result = Invoke-SynthSeed -Plan $script:plan -AdapterInstanceId 'adapter-1' -WhatIf
        $script:posts.Count | Should -Be 0
        $result.links | Should -Be 0
    }

    It 'records a failed object and carries on' {
        Mock -ModuleName VcfOpsSynth Invoke-SynthOpsRequest {
            $script:posts.Add(@{ Path = $Path; Body = $Body })
            if ($Path -like 'resources/adapters/*' -or $Path -like 'resources/adapterkinds/*') {
                if ($Body.resourceKey.name -eq 'vm-3333000001') { throw 'HTTP 500' }
                [pscustomobject]@{ identifier = "ops-$($Body.resourceKey.resourceKindKey)-$($Body.resourceKey.name)" }
            }
        } -ParameterFilter { $Method -eq 'Post' }

        $result = Invoke-SynthSeed -Plan $script:plan -AdapterInstanceId 'adapter-1'

        $result.failed | Should -HaveCount 1
        $result.failed[0] | Should -BeLike 'VirtualMachine vm-3333000001*HTTP 500*'
        $result.created.VirtualMachine | Should -Be 1
        $result.ids.Keys | Should -Not -Contain 'vm-3333000001'
    }
}

Describe 'Resolve-SynthSeedTarget' {
    BeforeAll {
        # An adapter instance as GET /api/adapters lists it; a collecting one has lastCollected.
        function New-TestInstance {
            param([string]$Id, [string]$Name, [string]$VcId, [switch]$Collecting)
            $identifiers = if ($VcId) { @([pscustomobject]@{ identifierType = [pscustomobject]@{ name = 'VMEntityVCID' }; value = $VcId }) } else { @() }
            $instance = [pscustomobject]@{ id = $Id; resourceKey = [pscustomobject]@{ name = $Name; resourceIdentifiers = $identifiers } }
            if ($Collecting) { $instance | Add-Member lastCollected 1792507232330 }
            $instance
        }
    }

    BeforeEach {
        $script:calls = [System.Collections.Generic.List[object]]::new()
        $script:instances = @(New-TestInstance 'vc-1' 'vc-mgmt-a.site-a.example.test' 'vc-uuid-real' -Collecting)
        Mock -ModuleName VcfOpsSynth Invoke-SynthOpsRequest {
            $script:calls.Add(@{ Method = $Method; Path = $Path; Body = $Body })
            switch -Wildcard ("$Method $Path") {
                'Get adapters' { [pscustomobject]@{ adapterInstancesInfoDto = $script:instances } }
                'Get credentials' { [pscustomobject]@{ credentialInstances = @([pscustomobject]@{ id = 'cred-old'; name = 'holder' }, [pscustomobject]@{ id = 'cred-vc'; name = 'vc' }) } }
                'Get credentials/cred-old/adapters' { [pscustomobject]@{} }
                'Post adapters' { [pscustomobject]@{ id = 'holder-1' } }
                'Get adapters/holder-1' { New-TestInstance 'holder-1' 'holder' $Body.resourceIdentifiers }
                'Get resources' { [pscustomobject]@{ resourceList = @(@{ resourceKey = @{ resourceIdentifiers = @(@{ identifierType = @{ name = 'VMEntityVCID' }; value = 'vc-uuid-dc' }) } }) } }
            }
        }
        # The created instance reads back with the VCID that was posted.
        Mock -ModuleName VcfOpsSynth Invoke-SynthOpsRequest {
            $script:calls.Add(@{ Method = $Method; Path = $Path })
            $posted = @($script:calls | Where-Object { $_.Method -eq 'Post' -and $_.Path -eq 'adapters' })[0].Body
            New-TestInstance 'holder-1' $posted.name (@($posted.resourceIdentifiers | Where-Object name -eq 'VMEntityVCID')[0].value)
        } -ParameterFilter { $Method -eq 'Get' -and $Path -eq 'adapters/holder-1' }
    }

    It 'reads the VCID from the instance itself and says a vCenter instance collects' {
        $target = Resolve-SynthSeedTarget -Name 'vc-mgmt-a'

        $target.AdapterInstanceId | Should -Be 'vc-1'
        $target.VcId | Should -Be 'vc-uuid-real'
        $target.Collecting | Should -BeTrue
        $target.Created | Should -BeFalse
        @($script:calls | Where-Object Path -eq 'resources').Count | Should -Be 0
    }

    It 'falls back to a datacenter for the VCID' {
        $script:instances = @(New-TestInstance 'vc-1' 'vc-mgmt-a' $null -Collecting)

        (Resolve-SynthSeedTarget -Name 'vc-mgmt-a').VcId | Should -Be 'vc-uuid-dc'
    }

    It 'throws when the instance is missing and -Create is not given, and creates nothing' {
        { Resolve-SynthSeedTarget -Name 'holder' } | Should -Throw "*No VMWARE adapter instance named 'holder'*seed creates it*"
        @($script:calls | Where-Object Method -ne 'Get').Count | Should -Be 0
    }

    It 'creates a never-started holder with its own VCID and an unresolvable address' {
        $target = Resolve-SynthSeedTarget -Name 'holder' -Create

        $target.Created | Should -BeTrue
        $target.Collecting | Should -BeFalse
        $target.AdapterInstanceId | Should -Be 'holder-1'
        $body = @($script:calls | Where-Object { $_.Method -eq 'Post' -and $_.Path -eq 'adapters' })[0].Body
        $ids = @{}; foreach ($i in $body.resourceIdentifiers) { $ids[$i.name] = $i.value }
        $ids.VCURL | Should -Be "$($ids.VMEntityVCID).synth.invalid"
        $ids.AUTODISCOVERY | Should -Be 'false'
        $ids.VMEntityVCID | Should -Not -Be 'vc-uuid-real'
        $target.VcId | Should -Be $ids.VMEntityVCID
        $body.description | Should -BeLike '*Do not start*'
        # Nothing starts the instance.
        @($script:calls | Where-Object { $_.Path -like '*monitoringstate*' }).Count | Should -Be 0
    }

    It 'removes an unused credential of the same name left by an earlier instance, and only that one' {
        $null = Resolve-SynthSeedTarget -Name 'holder' -Create

        $deleted = @($script:calls | Where-Object Method -eq 'Delete' | ForEach-Object Path)
        $deleted | Should -Be @('credentials/cred-old')
    }
}
