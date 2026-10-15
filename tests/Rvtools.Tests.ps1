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
        foreach ($name in 'datacenters', 'clusters', 'hosts', 'datastores', 'vms', 'report') { $copy[$name] = $Inventory[$name] }
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
        foreach ($set in 'datacenters', 'clusters', 'hosts', 'datastores', 'vms') {
            foreach ($item in $anonymous[$set]) { $item.name | Should -Be $item.id }
        }
    }

    It 'leaves no real name, folder, annotation, snapshot name or path in the output' {
        foreach ($text in 'app-pay-01', 'esx01', 'PROD-01', 'DC-Dublin', 'vsan-prod', '/Prod/Payments',
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
