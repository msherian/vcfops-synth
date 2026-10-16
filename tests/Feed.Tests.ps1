# Pester 5 tests for the live feed and scenario overlays. Inventory and plan are invented;
# the engine's HTTP side is not called (Invoke-SynthFeedEngine is mocked).
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Test helpers that only build objects.')]
param()

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '../src/VcfOpsSynth/VcfOpsSynth.psd1') -Force
    $script:step = 300000
    $script:points = 8640
    # Monday 2026-09-07 00:00 UTC, a whole number of 5-minute steps.
    $script:start = [DateTimeOffset]::new(2026, 9, 7, 0, 0, 0, [TimeSpan]::Zero).ToUnixTimeMilliseconds()
    $script:refEnd = $script:start + [long]($script:points - 1) * $script:step
    $script:tz = [TimeZoneInfo]::FindSystemTimeZoneById('Europe/Dublin')

    function New-TestObjectSpec {
        param([string]$Key = 'vm-1', [string]$WorkloadProfile = 'business-hours', [object[]]$Series = @())
        $o = [VcfOpsSynth.ObjectSpec]::new()
        $o.Key = $Key; $o.Seed = $Key; $o.ResourceId = "ops-$Key"
        $c = [VcfOpsSynth.ShapeComponent]::new(); $c.Profile = $WorkloadProfile; $c.Seed = $Key; $c.Weight = 1
        $o.Components = @($c)
        $o.Series = [VcfOpsSynth.SeriesSpec[]]@($Series)
        $o
    }

    function New-TestSeries {
        param([string]$Key, [string]$Mode, [double]$A, [double]$B = 0, [double]$Cap = [double]::NaN)
        $s = [VcfOpsSynth.SeriesSpec]::new()
        $s.Key = $Key; $s.Mode = $Mode; $s.A = $A; $s.B = $B; $s.Cap = $Cap
        $s
    }

    function New-TestOverlay {
        param([string]$Pattern, [string]$Op, [double]$Value, [long]$StartMs, [long]$RampMs = 0)
        $ov = [VcfOpsSynth.Overlay]::new()
        $ov.Scenario = 'T'; $ov.Pattern = $Pattern; $ov.Op = $Op; $ov.Value = $Value; $ov.StartMs = $StartMs; $ov.RampMs = $RampMs
        $ov
    }

    # Feed values for one series at each of the given times.
    function Get-FeedValue {
        param($Feed, [int]$Index, [long[]]$Time)
        foreach ($t in $Time) {
            $shape = [VcfOpsSynth.Feed]::ShapeAt($Feed.Spec, $t, $script:step, [VcfOpsSynth.Feed]::HourOfWeekAt($t, $script:tz))
            [VcfOpsSynth.Feed]::ValueAt($Feed, $Index, $shape, $t, $script:step)
        }
    }

    # A week of live timestamps after the reference window.
    $script:week = [long[]]@(for ($i = 1; $i -le 2016; $i++) { $script:refEnd + [long]$i * $script:step })
}

Describe 'Feed engine' {
    It 'carries a calibrated series on at the level the backfill set' {
        $o = New-TestObjectSpec -Series @(New-TestSeries -Key 'cpu|usage_average' -Mode Calibrated -A 20 -B 80 -Cap 100)
        $f = [VcfOpsSynth.Feed]::Prepare($o, $script:start, $script:step, $script:points, 'Europe/Dublin')
        $m = Get-FeedValue $f 0 $script:week | Measure-Object -Average -Maximum -Minimum
        $m.Average | Should -BeGreaterThan 15
        $m.Average | Should -BeLessThan 25
        $m.Maximum | Should -BeLessOrEqual 100
        $m.Minimum | Should -BeGreaterOrEqual 0
    }

    It 'keeps an activity series at its mean and follows the working day' {
        $o = New-TestObjectSpec -Series @(New-TestSeries -Key 'net|usage_average' -Mode Activity -A 250)
        $f = [VcfOpsSynth.Feed]::Prepare($o, $script:start, $script:step, $script:points, 'Europe/Dublin')
        $v = @(Get-FeedValue $f 0 $script:week)
        ($v | Measure-Object -Average).Average | Should -BeGreaterThan 200
        ($v | Measure-Object -Average).Average | Should -BeLessThan 300
        $noon = [VcfOpsSynth.Feed]::ValueAt($f, 0, [VcfOpsSynth.Feed]::ShapeAt($o, $script:week[0], $script:step, 12), $script:week[0], $script:step)
        $night = [VcfOpsSynth.Feed]::ValueAt($f, 0, [VcfOpsSynth.Feed]::ShapeAt($o, $script:week[0], $script:step, 3), $script:week[0], $script:step)
        $noon | Should -BeGreaterThan (2 * $night)
    }

    It 'keeps the edge cases: flat when the peak is the average, zero when the average is zero, constants constant' {
        $o = New-TestObjectSpec -Series @(
            (New-TestSeries -Key 'mem|usage_average' -Mode Calibrated -A 45 -B 45 -Cap 100),
            (New-TestSeries -Key 'virtualDisk|write_average' -Mode Calibrated -A 0 -B 51200),
            (New-TestSeries -Key 'cpu|totalCapacity_average' -Mode Constant -A 32000))
        $f = [VcfOpsSynth.Feed]::Prepare($o, $script:start, $script:step, $script:points, 'Europe/Dublin')
        @(Get-FeedValue $f 0 $script:week | Sort-Object -Unique) | Should -Be @(45)
        @(Get-FeedValue $f 1 $script:week | Sort-Object -Unique) | Should -Be @(0)
        @(Get-FeedValue $f 2 $script:week | Sort-Object -Unique) | Should -Be @(32000)
    }

    It 'keeps space in use growing past the backfill at the same weekly rate' {
        $o = New-TestObjectSpec -Series @(New-TestSeries -Key 'guestfilesystem|usage_total' -Mode Ramp -A 100 -B 0.01)
        $f = [VcfOpsSynth.Feed]::Prepare($o, $script:start, $script:step, $script:points, 'Europe/Dublin')
        $v = @(Get-FeedValue $f 0 @($script:refEnd, ($script:refEnd + 7 * 86400000L)))
        $v[0] | Should -Be 100
        [math]::Round($v[1], 6) | Should -Be 101
    }

    It 'gives the same point for the same object and time, so a repeated push writes the same value' {
        $o = New-TestObjectSpec -Series @(New-TestSeries -Key 'cpu|usage_average' -Mode Calibrated -A 20 -B 80 -Cap 100)
        $f = [VcfOpsSynth.Feed]::Prepare($o, $script:start, $script:step, $script:points, 'Europe/Dublin')
        (Get-FeedValue $f 0 $script:week[0..20]) -join ',' | Should -Be ((Get-FeedValue $f 0 $script:week[0..20]) -join ',')
    }

    It 'ramps an overlay in from its start, then holds it; Multiply, Add and Floor work on the base value' {
        $o = New-TestObjectSpec -Series @(
            (New-TestSeries -Key 'cpu|readyPct' -Mode Constant -A 2),
            (New-TestSeries -Key 'mem|usage_average' -Mode Constant -A 40 -Cap 100),
            (New-TestSeries -Key 'summary|number_running_hosts' -Mode Constant -A 4),
            (New-TestSeries -Key 'cpu|demandPct' -Mode Constant -A 30 -Cap 100))
        $f = [VcfOpsSynth.Feed]::Prepare($o, $script:start, $script:step, $script:points, 'Europe/Dublin')
        $t0 = $script:week[10]
        $f.Overlays = [VcfOpsSynth.Overlay[]]@(
            (New-TestOverlay -Pattern '^cpu\|readyPct$' -Op Set -Value 12 -StartMs $t0 -RampMs (10 * 60000)),
            (New-TestOverlay -Pattern '^mem\|usage_average$' -Op Multiply -Value 2 -StartMs $t0),
            (New-TestOverlay -Pattern '^summary\|number_running_hosts$' -Op Add -Value -1 -StartMs $t0),
            (New-TestOverlay -Pattern '^cpu\|demandPct$' -Op Floor -Value 115 -StartMs $t0))
        $at = { param($j, $t) [VcfOpsSynth.Feed]::ValueAt($f, $j, 1.0, $t, $script:step) }
        & $at 0 ($t0 - $script:step) | Should -Be 2
        & $at 0 ($t0 + 5 * 60000) | Should -Be 7
        & $at 0 ($t0 + 60 * 60000) | Should -Be 12
        & $at 1 $t0 | Should -Be 80
        & $at 2 $t0 | Should -Be 3
        # A scenario may push past the cap on purpose: a host demanding more CPU than it has.
        & $at 3 $t0 | Should -Be 115
    }

    It 'leaves dropped keys out of the body and adds text stats only to the live point' {
        $o = New-TestObjectSpec -Series @((New-TestSeries -Key 'cpu|usage_average' -Mode Constant -A 5), (New-TestSeries -Key 'sys|poweredOn' -Mode Constant -A 1))
        $f = [VcfOpsSynth.Feed]::Prepare($o, $script:start, $script:step, $script:points, 'Europe/Dublin')
        $f.TextKeys = [string[]]@('health|reports|hostd|state'); $f.TextValues = [string[]]@('green')
        $t = $script:week[0..1]
        $samples = 0L
        $live = [VcfOpsSynth.Feed]::Body($f, $t, $script:step, $script:tz, $true, [ref]$samples) | ConvertFrom-Json
        @($live.'stat-content'.statKey) | Should -Be @('cpu|usage_average', 'sys|poweredOn', 'health|reports|hostd|state')
        @($live.'stat-content'[0].timestamps) | Should -Be @($t)
        $samples | Should -Be 5
        $history = [VcfOpsSynth.Feed]::Body($f, $t, $script:step, $script:tz, $false, [ref]$samples) | ConvertFrom-Json
        @($history.'stat-content'.statKey) | Should -Be @('cpu|usage_average', 'sys|poweredOn')
        $f.Overlays = [VcfOpsSynth.Overlay[]]@((New-TestOverlay -Pattern '^(?!sys\|poweredOn$).*' -Op Drop -Value 0 -StartMs $t[0]), (New-TestOverlay -Pattern '^sys\|poweredOn$' -Op Set -Value 0 -StartMs $t[0]))
        $down = [VcfOpsSynth.Feed]::Body($f, $t, $script:step, $script:tz, $true, [ref]$samples) | ConvertFrom-Json
        @($down.'stat-content'.statKey) | Should -Be @('sys|poweredOn')
        @($down.'stat-content'[0].data) | Should -Be @(0, 0)
    }
}

Describe 'Get-SynthFeedTime' {
    It 'pushes the last whole interval live and fills the gap since the last push' {
        $now = [DateTimeOffset]::FromUnixTimeMilliseconds($script:refEnd + 3 * $script:step + 90000)
        $t = Get-SynthFeedTime -LastMs $script:refEnd -StepMs $script:step -Now $now
        $t.Live | Should -Be ($script:refEnd + 3 * $script:step)
        @($t.CatchUp) | Should -Be @(($script:refEnd + $script:step), ($script:refEnd + 2 * $script:step))
    }

    It 'fills at most MaxCatchUpHours and nothing when the feed is up to date' {
        $now = [DateTimeOffset]::FromUnixTimeMilliseconds($script:refEnd + 5 * 86400000L)
        @((Get-SynthFeedTime -LastMs $script:refEnd -StepMs $script:step -Now $now -MaxCatchUpHours 2).CatchUp).Count | Should -Be 24
        $live = (Get-SynthFeedTime -StepMs $script:step -Now $now).Live
        @((Get-SynthFeedTime -LastMs ($live - $script:step) -StepMs $script:step -Now $now).CatchUp).Count | Should -Be 0
        @((Get-SynthFeedTime -StepMs $script:step -Now $now).CatchUp).Count | Should -Be 0
    }
}

Describe 'Scenarios' {
    BeforeAll {
        $vm = { param($id, $hostId, $tier, [string]$power = 'poweredOn') @{ id = $id; name = "name-$id"; host = $hostId; cluster = 'cl-1'; tier = $tier; powerState = $power; datastores = @('ds-1'); cpu = @{ capacityMhz = 4000 }; memory = @{ sizeMiB = 4096 }; storage = @{ partitions = @(@{ path = 'C:\' }) } } }
        $script:inventory = @{
            hosts      = @(
                @{ id = 'esx-1'; name = 'name-esx-1'; cluster = 'cl-1'; cores = 16; cpuMhz = 2000; memoryMiB = 65536 }
                @{ id = 'esx-2'; name = 'name-esx-2'; cluster = 'cl-1'; cores = 16; cpuMhz = 2000; memoryMiB = 65536 }
                @{ id = 'esx-3'; name = 'name-esx-3'; cluster = 'cl-1'; cores = 16; cpuMhz = 2000; memoryMiB = 65536 }
            )
            datastores = @(@{ id = 'ds-1'; name = 'name-ds-1' }, @{ id = 'ds-2'; name = 'name-ds-2' })
            vms        = @(
                (& $vm 'vm-g1' 'esx-1' 'Gold'), (& $vm 'vm-b1' 'esx-1' 'Bronze'), (& $vm 'vm-b2' 'esx-1' 'Bronze'),
                (& $vm 'vm-s1' 'esx-2' 'Silver'), (& $vm 'vm-b3' 'esx-2' 'Bronze'), (& $vm 'vm-b4' 'esx-2' 'Bronze'), (& $vm 'vm-b5' 'esx-2' 'Bronze'),
                (& $vm 'vm-off' 'esx-3' 'Bronze' 'poweredOff')
            )
        }
        $stat = { param($k, $v) @{ key = $k; value = $v } }
        $script:plan = @{
            objects = @(
                @{ key = 'vm-g1'; kind = 'VirtualMachine'; stats = @((& $stat 'guestfilesystem:C:\|capacity' 100), (& $stat 'guestfilesystem:C:\|usage' 40), (& $stat 'guestfilesystem:C:\|percentage' 40), (& $stat 'guestfilesystem|capacity_total' 100)) }
            )
        }
        $script:state = Join-Path $TestDrive 'state.json'
    }

    It 'lists the five overlay scenarios' {
        @((Get-SynthScenarioCatalogue).Keys) | Should -Be @('S1', 'S2', 'S3', 'S4', 'S8')
    }

    It 'picks a sensible default target, or the one named by ID or name' {
        # esx-2 has more VMs but no Gold, so the noisy neighbour goes where Gold and Bronze share a host.
        (Resolve-SynthScenarioTarget -Id S1 -Inventory $script:inventory).id | Should -Be 'esx-1'
        (Resolve-SynthScenarioTarget -Id S2 -Inventory $script:inventory).id | Should -Be 'esx-2'
        (Resolve-SynthScenarioTarget -Id S2 -Inventory $script:inventory -Avoid 'esx-2').id | Should -Be 'esx-1'
        (Resolve-SynthScenarioTarget -Id S3 -Inventory $script:inventory).id | Should -Be 'ds-1'
        (Resolve-SynthScenarioTarget -Id S4 -Inventory $script:inventory).id | Should -Be 'vm-g1'
        (Resolve-SynthScenarioTarget -Id S8 -Inventory $script:inventory -Target 'NAME-ESX-3').id | Should -Be 'esx-3'
        { Resolve-SynthScenarioTarget -Id S8 -Inventory $script:inventory -Target 'nope' } | Should -Throw '*No HostSystem*'
        { Resolve-SynthScenarioTarget -Id S9 -Inventory $script:inventory } | Should -Throw '*Unknown scenario*'
    }

    It 'S1 loads the Bronze VMs, gives the Gold VM ready time, and marks the neighbours' {
        $e = Get-SynthScenarioEffect -Scenario @{ id = 'S1'; target = 'esx-1'; startedMs = 0; rampMinutes = 0 } -Inventory $script:inventory -Plan $script:plan
        @($e.Overlays.Keys | Sort-Object) | Should -Be @('esx-1', 'vm-b1', 'vm-b2', 'vm-g1')
        $mhz = @($e.Overlays['vm-b1'] | Where-Object { $_.Pattern -like '*usagemhz*' })[0]
        $mhz.Value | Should -Be 3800
        @($e.Overlays['vm-g1'] | Where-Object { $_.Pattern -like '*readyPct*' })[0].Value | Should -Be 12
        $e.Start['vm-b1']['vcfops-synth|scenario'] | Should -Be 'noisy-neighbour'
        $e.Stop['vm-b1']['vcfops-synth|scenario'] | Should -Be 'none'
    }

    It 'S8 silences the host, shows it not responding, and shifts its load and capacity' {
        $e = Get-SynthScenarioEffect -Scenario @{ id = 'S8'; target = 'esx-3'; startedMs = 0; rampMinutes = 0 } -Inventory $script:inventory -Plan $script:plan
        @($e.Overlays['esx-3'].Op) | Should -Be @('Drop', 'Set')
        $e.Start['esx-3']['runtime|connectionState'] | Should -Be 'notResponding'
        $e.Stop['esx-3']['runtime|connectionState'] | Should -Be 'connected'
        $e.Overlays['esx-1'][0].Value | Should -Be 1.5
        @($e.Overlays['cl-1'] | Where-Object { $_.Op -eq 'Multiply' })[0].Value | Should -BeGreaterThan 0.66
        @($e.Overlays['cl-1'] | Where-Object { $_.Op -eq 'Multiply' })[0].Value | Should -BeLessThan 0.67
    }

    It 'S4 fills each guest file system to 95 % of its own capacity' {
        $e = Get-SynthScenarioEffect -Scenario @{ id = 'S4'; target = 'vm-g1'; startedMs = 0; rampMinutes = 0 } -Inventory $script:inventory -Plan $script:plan
        $usage = @($e.Overlays['vm-g1'] | Where-Object { 'guestfilesystem:C:\|usage' -match $_.Pattern })
        $usage.Count | Should -Be 1
        $usage[0].Value | Should -Be 95
        @($e.Overlays['vm-g1'] | Where-Object { 'guestfilesystem|usage_total' -match $_.Pattern })[0].Value | Should -Be 95
    }

    It 'records a started scenario, restarts it in place, and stops one or all' {
        $null = Start-SynthScenario -Id s3 -Inventory $script:inventory -Plan $script:plan -StatePath $script:state
        $null = Start-SynthScenario -Id S1 -Inventory $script:inventory -Plan $script:plan -StatePath $script:state -RampMinutes 5
        $null = Start-SynthScenario -Id S3 -Inventory $script:inventory -Plan $script:plan -StatePath $script:state -Target 'name-ds-2'
        $running = @(Read-SynthScenarioState -Path $script:state)
        @($running.id) | Should -Be @('S1', 'S3')
        @($running | Where-Object { $_.id -eq 'S3' })[0].target | Should -Be 'ds-2'
        @(Stop-SynthScenario -Id S1 -Inventory $script:inventory -Plan $script:plan -StatePath $script:state).id | Should -Be 'S1'
        @((Read-SynthScenarioState -Path $script:state).id) | Should -Be @('S3')
        $null = Stop-SynthScenario -Id all -Inventory $script:inventory -Plan $script:plan -StatePath $script:state
        @(Read-SynthScenarioState -Path $script:state).Count | Should -Be 0
    }

    It 'puts the running scenarios'' overlays on the matching feed objects only' {
        $feed = @(foreach ($k in 'esx-1', 'vm-b1', 'vm-s1') { $f = [VcfOpsSynth.FeedObject]::new(); $f.Spec = New-TestObjectSpec -Key $k; $f })
        Set-SynthFeedOverlay -Feed $feed -Scenario @(@{ id = 'S1'; target = 'esx-1'; startedMs = 0; rampMinutes = 0 }) -Inventory $script:inventory -Plan $script:plan
        $feed[0].Overlays.Count | Should -BeGreaterThan 0
        $feed[1].Overlays.Count | Should -BeGreaterThan 0
        $feed[2].Overlays.Count | Should -Be 0
        Set-SynthFeedOverlay -Feed $feed -Scenario @() -Inventory $script:inventory -Plan $script:plan
        $feed[0].Overlays.Count | Should -Be 0
    }
}

Describe 'Invoke-SynthFeed' {
    BeforeAll {
        $script:feedState = Join-Path $TestDrive 'feed-state.json'
        $script:feedObjects = [VcfOpsSynth.FeedObject[]]@(foreach ($k in 'vm-1', 'vm-2') {
                $o = New-TestObjectSpec -Key $k -Series @(New-TestSeries -Key 'cpu|usage_average' -Mode Constant -A 5)
                [VcfOpsSynth.Feed]::Prepare($o, $script:start, $script:step, 288, 'Europe/Dublin')
            })
    }

    BeforeEach {
        InModuleScope VcfOpsSynth { $script:OpsSession = [pscustomobject]@{ BaseUri = 'https://ops.test/suite-api'; Token = 't'; SkipCertificateCheck = $false; TimeoutSec = 30 } }
        Mock -ModuleName VcfOpsSynth Invoke-SynthOpsRequest { }
        Mock -ModuleName VcfOpsSynth Invoke-SynthFeedEngine { foreach ($f in $Feed) { $r = [VcfOpsSynth.PushResult]::new(); $r.Key = $f.Spec.Key; $r.Samples = $Time.Count; $r } }
    }

    AfterEach { InModuleScope VcfOpsSynth { $script:OpsSession = $null } }

    It 'fills the gap since the backfill with analytics off, then pushes the live point with analytics on, and saves it' {
        $live = (Get-SynthFeedTime -StepMs $script:step).Live
        @{ backfill = @{ range = @{ EndMs = $live - 3 * $script:step } } } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $script:feedState
        $result = Invoke-SynthFeed -Feed $script:feedObjects -Inventory @{ hosts = @(); vms = @() } -Plan @{ objects = @() } -StatePath $script:feedState -StepMs $script:step -Cycles 1
        $result.cycles | Should -Be 1
        $result.samples | Should -Be 6
        Should -Invoke -ModuleName VcfOpsSynth Invoke-SynthFeedEngine -Times 1 -Exactly -ParameterFilter { -not $Analytics -and $Time.Count -eq 2 }
        Should -Invoke -ModuleName VcfOpsSynth Invoke-SynthFeedEngine -Times 1 -Exactly -ParameterFilter { $Analytics -and $Time.Count -eq 1 -and $Time[0] -eq $live }
        (Get-Content -LiteralPath $script:feedState -Raw | ConvertFrom-Json).feed.lastMs | Should -Be $live
    }

    It 'does not push the same live point twice' {
        $live = (Get-SynthFeedTime -StepMs $script:step).Live
        @{ feed = @{ lastMs = $live + $script:step } } | ConvertTo-Json | Set-Content -LiteralPath $script:feedState
        $null = Invoke-SynthFeed -Feed $script:feedObjects -Inventory @{ hosts = @(); vms = @() } -Plan @{ objects = @() } -StatePath $script:feedState -StepMs $script:step -Cycles 1
        Should -Invoke -ModuleName VcfOpsSynth Invoke-SynthFeedEngine -Times 0 -Exactly
    }

    It 'pushes nothing with -WhatIf' {
        $null = Invoke-SynthFeed -Feed $script:feedObjects -Inventory @{ hosts = @(); vms = @() } -Plan @{ objects = @() } -StatePath $script:feedState -StepMs $script:step -Cycles 1 -WhatIf
        Should -Invoke -ModuleName VcfOpsSynth Invoke-SynthFeedEngine -Times 0 -Exactly
    }
}
