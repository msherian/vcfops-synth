# Pester 5 tests for the RVTools importer, run against an invented export in tests/fixtures. No lab needed.
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Test helpers that write into the Pester TestDrive.')]
param()

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '../src/VcfOpsSynth/VcfOpsSynth.psd1') -Force
    $script:fixture = Join-Path $PSScriptRoot 'fixtures/rvtools-4x'
    $script:rules = Get-SynthTieringRule -Path (Join-Path $PSScriptRoot '../config/tiering.example.json')
    $script:key = [System.Text.Encoding]::UTF8.GetBytes('pester-key')

    function Import-Fixture {
        param([string]$Path = $script:fixture, [switch]$Anonymise, [byte[]]$Key = $script:key)
        Import-SynthRvtools -Path $Path -Key $Key -TieringRules $script:rules -Anonymise:$Anonymise
    }

    # Copies the fixture to the TestDrive, letting a test rewrite each file's text first.
    function Copy-Fixture {
        param([string]$Name, [scriptblock]$Transform = { param($text) $text }, [string[]]$Exclude = @())
        $target = Join-Path $TestDrive $Name
        $null = New-Item -ItemType Directory -Path $target -Force
        foreach ($file in Get-ChildItem -Path $script:fixture -Filter '*.csv') {
            if ($file.Name -in $Exclude) { continue }
            $text = & $Transform (Get-Content -LiteralPath $file.FullName -Raw)
            Set-Content -LiteralPath (Join-Path $target $file.Name) -Value $text -NoNewline
        }
        $target
    }

    function Get-Vm {
        param($Inventory, [string]$Name)
        $Inventory.vms | Where-Object { $_.name -eq $Name }
    }

    # The parts of an inventory that should not depend on the file format.
    function Get-Comparable {
        param($Inventory)
        $copy = [ordered]@{}
        foreach ($name in 'datacenters', 'clusters', 'hosts', 'datastores', 'switches', 'networks', 'resourcePools', 'folders', 'vms', 'report') { $copy[$name] = $Inventory[$name] }
        $copy | ConvertTo-Json -Depth 20
    }
}

Describe 'Import-SynthRvtools from CSV' {
    BeforeAll { $script:inventory = Import-Fixture }

    It 'builds the estate and skips what is not a VM' {
        @($inventory.vms).Count | Should -Be 8
        @($inventory.hosts).Count | Should -Be 3
        @($inventory.clusters).Count | Should -Be 2
        @($inventory.datastores).Count | Should -Be 3
        @($inventory.datacenters).Count | Should -Be 1
        ($inventory.report.skipped | ForEach-Object { "$($_.tab):$($_.row):$($_.reason)" }) |
            Should -Be @('vInfo:8:template', 'vInfo:9:no VM name')
    }

    It 'warns about a VM on a host the export does not describe, and keeps it' {
        $inventory.report.warnings | Should -HaveCount 1
        $inventory.report.warnings[0] | Should -BeLike '*vInfo row 10 (lost-vm-01)*not in vHost*'
        $lost = Get-Vm $inventory 'lost-vm-01'
        $lost.host | Should -BeNullOrEmpty
        $lost.cluster | Should -Be ($inventory.clusters | Where-Object name -eq 'PROD-01').id
    }

    It 'places a VM on its host, cluster, datacenter and datastore' {
        $vm = Get-Vm $inventory 'app-pay-01'
        $vm.host | Should -Be ($inventory.hosts | Where-Object name -eq 'esx01.example.test').id
        $vm.cluster | Should -Be ($inventory.clusters | Where-Object name -eq 'PROD-01').id
        $vm.datacenter | Should -Be $inventory.datacenters[0].id
        $vm.datastores | Should -Be @(($inventory.datastores | Where-Object name -eq 'vsan-prod').id)
    }

    It 'derives baselines from the single RVTools sample' {
        $vm = Get-Vm $inventory 'app-pay-01'
        $vm.baseline.cpuUsagePct | Should -Be 25      # 2600 of 10400 MHz
        $vm.baseline.memActivePct | Should -Be 25     # 4096 of 16384 MiB
        $vm.baseline.memConsumedPct | Should -Be 75
        $vm.baseline.diskUsedPct | Should -Be 53.3    # 163840 of 307200 MiB over two partitions

        $esx = $inventory.hosts | Where-Object name -eq 'esx02.example.test'
        $esx.baseline.cpuUsagePct | Should -Be 44
        $esx.baseline.memUsagePct | Should -Be 72
        ($inventory.datastores | Where-Object name -eq 'vsan-dev').baseline.usedPct | Should -Be 75
    }

    It 'gives a powered-off VM zero usage and the off profile' {
        $vm = Get-Vm $inventory 'dev-test-02'
        $vm.profile | Should -Be 'off'
        $vm.baseline.cpuUsagePct | Should -Be 0
    }

    It 'carries configuration for the hygiene dashboard' {
        $vm = Get-Vm $inventory 'dev-build-01'
        $vm.hardwareVersion | Should -Be 'vmx-13'
        $vm.toolsStatus | Should -Be 'toolsOld'
        $vm.snapshots.created | Should -Be @('2025-01-15T09:00:00', '2025-06-20T14:30:00')
        $vm.guestOs | Should -Be 'Ubuntu Linux (64-bit)'
    }

    It 'reads -1 limits as unlimited and keeps reservations' {
        $vm = Get-Vm $inventory 'sql-pay-01'
        $vm.cpu.limitMhz | Should -BeNullOrEmpty
        $vm.cpu.reservationMhz | Should -Be 1000
        $vm.memory.reservationMiB | Should -Be 8192
    }

    It 'lists the hosts that mount each datastore' {
        ($inventory.datastores | Where-Object name -eq 'nfs-iso').hosts | Should -HaveCount 3
    }

    It 'never reads IP addresses or DNS names' {
        $json = $inventory | ConvertTo-Json -Depth 20
        $json | Should -Not -Match '192\.0\.2\.'
        $json | Should -Not -Match 'corp\.example\.test'
    }

    It 'records where the data came from' {
        $inventory.source.format | Should -Be 'csv'
        $inventory.source.rvtoolsVersion | Should -Be '4.7.1'
        $inventory.source.exportedAt | Should -Be '2026-09-30T08:00:00'
        $inventory.source.anonymised | Should -BeFalse
    }
}

Describe 'The rest of the estate' {
    BeforeAll { $script:inventory = Import-Fixture }

    It 'builds switches, networks, resource pools and folders' {
        @($inventory.switches | Where-Object kind -eq 'distributed').Count | Should -Be 1
        @($inventory.switches | Where-Object kind -eq 'standard').Count | Should -Be 1
        ($inventory.networks.name | Sort-Object) | Should -Be @('Management Network', 'pg-mgmt', 'pg-prod-app', 'pg-prod-db', 'VM Network')
        @($inventory.resourcePools).Count | Should -Be 3
        ($inventory.folders.name | Sort-Object) | Should -Be @('Batch', 'Dev', 'Payments', 'Prod', 'Shop')
    }

    It 'links distributed port groups to their switch, VLAN and member hosts' {
        $dvs = $inventory.switches | Where-Object kind -eq 'distributed'
        $dvs.name | Should -Be 'dvs-prod'
        $dvs.hosts | Should -HaveCount 2
        $dvs.mtu | Should -Be 9000
        $db = $inventory.networks | Where-Object name -eq 'pg-prod-db'
        $db.kind | Should -Be 'distributed'
        $db.switch | Should -Be $dvs.id
        $db.vlan | Should -Be '120'
        $db.hosts | Should -Be $dvs.hosts
    }

    It 'gives a standard port group the hosts that carry it' {
        $esx03 = ($inventory.hosts | Where-Object name -eq 'esx03.example.test').id
        $vmNetwork = $inventory.networks | Where-Object name -eq 'VM Network'
        $vmNetwork.kind | Should -Be 'standard'
        $vmNetwork.hosts | Should -Be @($esx03)
        $vss = $inventory.switches | Where-Object kind -eq 'standard'
        $vss.hosts | Should -Be @($esx03)
        $vss.portGroups | Should -HaveCount 2
    }

    It 'gives each VM its virtual disks and network adapters' {
        $vm = Get-Vm $inventory 'sql-pay-01'
        $vm.storage.disks.label | Should -Be @('Hard disk 1', 'Hard disk 2')
        $vm.storage.disks.capacityMiB | Should -Be @(51200, 563200)
        $vm.storage.disks[0].thin | Should -BeTrue
        $vm.storage.disks[1].datastore | Should -Be ($inventory.datastores | Where-Object name -eq 'vsan-prod').id
        $vm.nics.network | Should -Be @(
            ($inventory.networks | Where-Object name -eq 'pg-prod-app').id
            ($inventory.networks | Where-Object name -eq 'pg-prod-db').id
        )
        $vm.nics[0].adapter | Should -Be 'Vmxnet3'
    }

    It 'places a VM in its folder and resource pool' {
        $vm = Get-Vm $inventory 'app-pay-01'
        $folder = $inventory.folders | Where-Object id -eq $vm.folderId
        $folder.name | Should -Be 'Payments'
        ($inventory.folders | Where-Object id -eq $folder.parent).name | Should -Be 'Prod'
        $pool = $inventory.resourcePools | Where-Object id -eq $vm.resourcePoolId
        $pool.name | Should -Be 'Resources'
        $pool.cluster | Should -Be $vm.cluster
        $pool.cpu.reservationMhz | Should -Be 150000
    }

    It 'nests a child pool under its cluster root and reads -1 as unlimited' {
        $batch = $inventory.resourcePools | Where-Object name -eq 'Batch'
        $root = $inventory.resourcePools | Where-Object id -eq $batch.parent
        $root.name | Should -Be 'Resources'
        $batch.cluster | Should -Be ($inventory.clusters | Where-Object name -eq 'PROD-01').id
        $batch.cpu.limitMhz | Should -BeNullOrEmpty
        $batch.cpu.shares | Should -Be 'high'
        $batch.memory.expandable | Should -BeTrue
    }

    It 'gives each host its NICs, HBAs and VMkernel adapters' {
        $esx01 = $inventory.hosts | Where-Object name -eq 'esx01.example.test'
        $esx01.nics.device | Should -Be @('vmnic0', 'vmnic1')
        $esx01.nics[0].speedMbps | Should -Be 25000
        $esx01.nics[0].switch | Should -Be ($inventory.switches | Where-Object kind -eq 'distributed').id
        $esx01.hbas.device | Should -Be @('vmhba0')
        $esx01.vmkernels[0].network | Should -Be ($inventory.networks | Where-Object name -eq 'pg-mgmt').id
    }

    It 'never reads MAC addresses or VMkernel addresses' {
        $json = $inventory | ConvertTo-Json -Depth 20
        $json | Should -Not -Match '00:50:56'
        $json | Should -Not -Match '255\.255\.255'
    }
}

Describe 'Tiering during import' {
    BeforeAll { $script:inventory = Import-Fixture }

    It 'gives <Name> tier <Tier>, profile <Profile> and application <App>' -ForEach @(
        @{ Name = 'app-pay-01';   Tier = 'Gold';   Profile = 'business-hours'; App = 'Payments' }
        @{ Name = 'sql-pay-01';   Tier = 'Gold';   Profile = 'steady';         App = 'Payments' }
        @{ Name = 'web-shop-01';  Tier = 'Silver'; Profile = 'business-hours'; App = 'Web Shop' }
        @{ Name = 'batch-etl-01'; Tier = 'Silver'; Profile = 'batch';          App = 'Data Platform' }
        @{ Name = 'dev-build-01'; Tier = 'Bronze'; Profile = 'idle';           App = $null }
        @{ Name = 'dev-hot-01';   Tier = 'Bronze'; Profile = 'saturated';      App = $null }
    ) {
        $vm = Get-Vm $inventory $Name
        $vm.tier | Should -Be $Tier
        $vm.profile | Should -Be $Profile
        $vm.application | Should -Be $App
    }

    It 'makes every VM Bronze without a tiering file' {
        $plain = Import-SynthRvtools -Path $script:fixture -Key $script:key
        ($plain.vms.tier | Sort-Object -Unique) | Should -Be 'Bronze'
    }
}

Describe 'Anonymised import' {
    BeforeAll {
        $script:anonymous = Import-Fixture -Anonymise
        $script:json = $anonymous | ConvertTo-Json -Depth 20
    }

    It 'replaces every name with its ID' {
        foreach ($set in 'datacenters', 'clusters', 'hosts', 'datastores', 'networks', 'folders', 'vms') {
            foreach ($item in $anonymous[$set]) { $item.name | Should -Be $item.id }
        }
        ($anonymous.switches | Where-Object kind -eq 'distributed').name | Should -Match '^dvs-[0-9a-f]{10}$'
        ($anonymous.resourcePools | Where-Object name -ne 'Resources').name | Should -Match '^rp-[0-9a-f]{10}$'
    }

    It 'leaves no real name, folder, network, annotation, snapshot name or path in the output' {
        foreach ($text in 'app-pay-01', 'esx01', 'PROD-01', 'DC-Dublin', 'vsan-prod', '/Prod/Payments', '"Prod"',
            'dvs-prod', 'pg-prod', 'pg-mgmt', 'VM Network', '"Shop"', '.vmdk',
            'Tier 1 payments', 'Before October patching', 'mssql', 'C:\\', 'rvtools-4x', 'vc01') {
            $json | Should -Not -Match ([regex]::Escape($text))
        }
        $anonymous.source.file | Should -BeNullOrEmpty
    }

    It 'still tiers by the real values' {
        @($anonymous.vms | Where-Object tier -eq 'Gold').Count | Should -Be 2
        @($anonymous.vms | Where-Object application -eq 'Payments').Count | Should -Be 2
    }

    It 'numbers partitions instead of naming them' {
        $twoDisks = @($anonymous.vms | Where-Object { $_.storage.partitions.Count -eq 2 })
        $twoDisks.Count | Should -Be 2
        foreach ($vm in $twoDisks) { $vm.storage.partitions.disk | Should -Be @('disk1', 'disk2') }
    }

    It 'gives the same IDs for the same key and different ones for another' {
        $again = Import-Fixture -Anonymise
        $again.vms.id | Should -Be $anonymous.vms.id
        $other = Import-Fixture -Anonymise -Key ([System.Text.Encoding]::UTF8.GetBytes('another-key'))
        @($other.vms.id | Where-Object { $_ -in $anonymous.vms.id }).Count | Should -Be 0
    }

    It 'shows nothing identifying in warnings' {
        $anonymous.report.warnings[0] | Should -Match 'vInfo row 10 \(vm-[0-9a-f]{10}\)'
    }
}

Describe 'LiveOptics performance' -Skip:(-not (Get-Module -ListAvailable -Name ImportExcel)) {
    BeforeAll {
        Import-Module ImportExcel -WarningAction SilentlyContinue
        # An invented LiveOptics VMware workbook: a header-less Details sheet and the two performance sheets.
        $script:liveOptics = Join-Path $TestDrive 'LiveOptics_000000_VMWARE_09_04_2026.xlsx'
        @(
            [pscustomobject]@{ P1 = 'Project Name'; P2 = 'Example Customer - Assessment' }
            [pscustomobject]@{ P1 = 'Date'; P2 = '2026/09/04' }
            [pscustomobject]@{ P1 = 'Owner'; P2 = 'Someone (someone@example.test)' }
        ) | Export-Excel -Path $liveOptics -WorksheetName 'Details' -NoHeader
        $vm = {
            param($Name, $MobId, $CpuAvg, $CpuPeak, $MemAvg, $MemPeak)
            [pscustomobject][ordered]@{
                'VM Name' = $Name; 'MOB ID' = $MobId; 'Host' = 'esx01.example.test'; 'VM IO Classification' = 'Standard'
                'Peak vCPU %' = $CpuPeak; 'Average vCPU %' = $CpuAvg; 'Peak Memory %' = $MemPeak; 'Avg Memory %' = $MemAvg
                'Peak IOPS' = 900; 'Average IOPS' = 120; 'Peak Read IOPS' = 600; 'Peak Write IOPS' = 300; 'Avg Read IOPS' = 80; 'Avg Write IOPS' = 40
                'Peak Read MB/s' = 40; 'Peak Write MB/s' = 20; 'Avg Read MB/s' = 4; 'Avg Write MB/s' = 2
                'Peak Read Latency' = 12; 'Peak Write Latency' = 9; 'Avg Read Latency' = 1.5; 'Avg Write Latency' = 2.5
            }
        }
        @(
            & $vm 'app-pay-01' 'vm-1001' 30 90 40 60        # joined on the managed object ID and name
            & $vm 'sql-pay-01-renamed' 'vm-1002' 50 95 70 80 # joined on the ID alone: one vCenter, one candidate
            & $vm 'dev-build-01' 'vm-9999' 1 4 5 8          # joined on the name after the ID fails
            & $vm 'dev-hot-01' 'vm-2005' 2 6 3 5            # LiveOptics says idle, RVTools' sample said saturated
            & $vm 'ghost-vm' 'vm-7777' 10 20 10 20          # in no RVTools export
        ) | Export-Excel -Path $liveOptics -WorksheetName 'VM Performance'
        @(
            [pscustomobject]@{ Host = 'esx01.example.test'; 'Peak CPU %' = 80; 'Average CPU %' = 35; 'Peak Memory %' = 75; 'Average Memory %' = 62; 'Peak IOPS' = 5000; 'Average IOPS' = 900; 'Peak Throughput MB/s' = 300; 'Avg Throughput MB/s' = 45; 'Peak Read Latency' = 8; 'Peak Write Latency' = 6; 'Avg Read Latency' = 1; 'Avg Write Latency' = 1.2 }
            [pscustomobject]@{ Host = 'esx02'; 'Peak CPU %' = 70; 'Average CPU %' = 40; 'Peak Memory %' = 80; 'Average Memory %' = 70; 'Peak IOPS' = 4000; 'Average IOPS' = 800; 'Peak Throughput MB/s' = 250; 'Avg Throughput MB/s' = 40; 'Peak Read Latency' = 7; 'Peak Write Latency' = 5; 'Avg Read Latency' = 1; 'Avg Write Latency' = 1.1 }
            [pscustomobject]@{ Host = 'esx77.example.test'; 'Peak CPU %' = 10; 'Average CPU %' = 5; 'Peak Memory %' = 10; 'Average Memory %' = 5; 'Peak IOPS' = 10; 'Average IOPS' = 1; 'Peak Throughput MB/s' = 1; 'Avg Throughput MB/s' = 1; 'Peak Read Latency' = 1; 'Peak Write Latency' = 1; 'Avg Read Latency' = 1; 'Avg Write Latency' = 1 }
        ) | Export-Excel -Path $liveOptics -WorksheetName 'ESX Performance'

        $script:perf = Read-SynthLiveOptics -Path $liveOptics
        $script:inventory = Import-SynthRvtools -Path $script:fixture -Key $script:key -TieringRules $script:rules -Performance $perf
    }

    It 'reads the collection date but not the project or owner' {
        $perf.CollectedOn | Should -Be '2026-09-04T00:00:00'
        $inventory.source.performance.format | Should -Be 'LiveOptics'
        $inventory.source.performance.collectedOn | Should -Be '2026-09-04T00:00:00'
        $json = $inventory | ConvertTo-Json -Depth 20
        $json | Should -Not -Match 'Example Customer'
        $json | Should -Not -Match 'someone@example'
    }

    It 'joins VMs on the managed object ID, then on the name' {
        (Get-Vm $inventory 'app-pay-01').baseline.perf.cpuAvgPct | Should -Be 30
        (Get-Vm $inventory 'app-pay-01').baseline.perf.cpuPeakPct | Should -Be 90
        (Get-Vm $inventory 'app-pay-01').baseline.perf.readLatencyAvgMs | Should -Be 1.5
        (Get-Vm $inventory 'app-pay-01').baseline.perf.ioClass | Should -Be 'Standard'
        (Get-Vm $inventory 'sql-pay-01').baseline.perf.memAvgPct | Should -Be 70
        (Get-Vm $inventory 'dev-build-01').baseline.perf.cpuPeakPct | Should -Be 4
        (Get-Vm $inventory 'web-shop-01').baseline.perf | Should -BeNullOrEmpty
    }

    It 'keeps the RVTools sample alongside' {
        (Get-Vm $inventory 'app-pay-01').baseline.cpuUsagePct | Should -Be 25
    }

    It 'profiles a VM by its LiveOptics averages' {
        (Get-Vm $inventory 'dev-hot-01').profile | Should -Be 'idle'
    }

    It 'joins hosts on the full or short name' {
        ($inventory.hosts | Where-Object name -eq 'esx01.example.test').baseline.perf.cpuAvgPct | Should -Be 35
        ($inventory.hosts | Where-Object name -eq 'esx02.example.test').baseline.perf.throughputPeakMBps | Should -Be 250
        ($inventory.hosts | Where-Object name -eq 'esx03.example.test').baseline.perf | Should -BeNullOrEmpty
    }

    It 'counts what matched and warns about what did not' {
        $p = $inventory.report.performance
        $p.vmsMatched | Should -Be 4
        $p.vmsWithout | Should -Be 4
        $p.vmRowsUnused | Should -Be 1
        $p.hostsMatched | Should -Be 2
        $p.hostRowsUnused | Should -Be 1
        $inventory.report.warnings | Should -Contain 'LiveOptics has 1 VM row(s) that match no VM in the RVTools export; they were ignored.'
        Get-SynthInventorySummary -Inventory $inventory | Should -Contain 'Performance: LiveOptics for 4 of 8 VMs and 2 of 3 hosts'
    }

    It 'leaves no real name in an anonymised import' {
        $anonymous = Import-SynthRvtools -Path $script:fixture -Key $script:key -TieringRules $script:rules -Performance $perf -Anonymise
        $json = $anonymous | ConvertTo-Json -Depth 20
        foreach ($text in 'app-pay-01', 'ghost-vm', 'esx01', 'renamed') { $json | Should -Not -Match ([regex]::Escape($text)) }
        @($anonymous.vms | Where-Object { $_.baseline.perf }).Count | Should -Be 4
    }

    It 'refuses a workbook without the performance sheets' {
        $other = Join-Path $TestDrive 'not-liveoptics.xlsx'
        [pscustomobject]@{ A = 1 } | Export-Excel -Path $other -WorksheetName 'Sheet1'
        { Read-SynthLiveOptics -Path $other } | Should -Throw "*no 'VM Performance' sheet*"
    }
}


Describe 'Other export shapes' {
    It 'reads the xlsx export the same way as the CSV export' -Skip:(-not (Get-Module -ListAvailable -Name ImportExcel)) {
        Import-Module ImportExcel -WarningAction SilentlyContinue
        $xlsx = Join-Path $TestDrive 'rvtools.xlsx'
        foreach ($file in Get-ChildItem -Path $script:fixture -Filter '*.csv') {
            $tab = $file.BaseName -replace '^RVTools_tab', ''
            Import-Csv -LiteralPath $file.FullName | Export-Excel -Path $xlsx -WorksheetName $tab -WarningAction SilentlyContinue
        }
        $fromXlsx = Import-Fixture -Path $xlsx
        $fromXlsx.source.format | Should -Be 'xlsx'
        Get-Comparable $fromXlsx | Should -Be (Get-Comparable (Import-Fixture))
    }

    It 'reads RVTools 3.x headers (MB, no VM ID) and joins on the VM UUID' {
        $old = Copy-Fixture -Name 'rvtools-3x' -Transform {
            param($text)
            $lines = $text -split "`r`n"
            $lines[0] = $lines[0] -replace ' MiB', ' MB' -replace '(^|,)VM ID(?=,|$)', '$1Legacy ID'
            $lines -join "`r`n"
        }
        $inventory = Import-Fixture -Path $old
        @($inventory.vms).Count | Should -Be 8
        (Get-Vm $inventory 'app-pay-01').memory.sizeMiB | Should -Be 16384
        (Get-Vm $inventory 'app-pay-01').baseline.diskUsedPct | Should -Be 53.3
        (Get-Vm $inventory 'sql-pay-01').baseline.cpuUsagePct | Should -Be 40
    }

    It 'reads semicolon-separated CSV from a European desktop' {
        $semicolon = Copy-Fixture -Name 'semicolon' -Transform {
            param($text)
            ($text -split "`r`n" | ForEach-Object {
                    if ($_) { ($_ | ConvertFrom-Csv -Header (1..60) | ForEach-Object { $_.PSObject.Properties.Value | Where-Object { $null -ne $_ } }) -join ';' }
                }) -join "`r`n"
        }
        $inventory = Import-Fixture -Path $semicolon
        @($inventory.vms).Count | Should -Be 8
        (Get-Vm $inventory 'app-pay-01').baseline.cpuUsagePct | Should -Be 25
    }

    It 'warns and carries on when an optional tab is missing' {
        $partial = Copy-Fixture -Name 'no-memory' -Exclude 'RVTools_tabvMemory.csv'
        $inventory = Import-Fixture -Path $partial
        $inventory.report.warnings | Should -Contain 'The export has no vMemory tab; the values it carries are left empty.'
        (Get-Vm $inventory 'app-pay-01').baseline.memActivePct | Should -BeNullOrEmpty
        (Get-Vm $inventory 'app-pay-01').memory.sizeMiB | Should -Be 16384
    }

    It 'stops when vHost is missing' {
        $partial = Copy-Fixture -Name 'no-host' -Exclude 'RVTools_tabvHost.csv'
        { Import-Fixture -Path $partial } | Should -Throw '*no vHost tab*'
    }

    It 'stops and names the column when vInfo has no VM column' {
        $broken = Copy-Fixture -Name 'no-vm-column' -Transform {
            param($text)
            if ($text.StartsWith('VM,Powerstate,Template,SRM Placeholder,Config status')) { 'Name' + $text.Substring(2) } else { $text }
        }
        { Import-Fixture -Path $broken } | Should -Throw '*vInfo has no vm (column VM)*'
    }

    It 'refuses a file that is neither xlsx nor a CSV folder' {
        $file = Join-Path $TestDrive 'export.txt'
        Set-Content -Path $file -Value 'x'
        { Import-Fixture -Path $file } | Should -Throw '*neither an .xlsx file nor a folder*'
    }
}

Describe 'Save-SynthInventory and Get-SynthInventory' {
    It 'round-trips the model through JSON' {
        $path = Join-Path $TestDrive 'out/inventory.json'
        Save-SynthInventory -Inventory (Import-Fixture -Anonymise) -Path $path
        $loaded = Get-SynthInventory -Path $path
        @($loaded.vms).Count | Should -Be 8
        $loaded.source.anonymised | Should -BeTrue
        Get-SynthInventorySummary -Inventory $loaded | Should -Contain 'Tiers: Gold 2, Silver 3, Bronze 3'
    }

    It 'refuses a model from another schema version' {
        $path = Join-Path $TestDrive 'old.json'
        '{ "schemaVersion": 0 }' | Set-Content -Path $path
        { Get-SynthInventory -Path $path } | Should -Throw '*schema version 0*'
    }
}

Describe 'Get-SynthAnonymisationKey' {
    AfterEach { Remove-Item Env:VCFOPS_SYNTH_ANON_KEY -ErrorAction SilentlyContinue }

    It 'creates a key once and reuses it' {
        $data = Join-Path $TestDrive 'data'
        $first = Get-SynthAnonymisationKey -DataPath $data
        $first.Length | Should -Be 32
        Get-SynthAnonymisationKey -DataPath $data | Should -Be $first
    }

    It 'prefers VCFOPS_SYNTH_ANON_KEY' {
        $env:VCFOPS_SYNTH_ANON_KEY = 'from-env'
        [System.Text.Encoding]::UTF8.GetString((Get-SynthAnonymisationKey -DataPath $TestDrive)) | Should -Be 'from-env'
    }
}
