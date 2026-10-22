# Pester 5 tests for the backfill: the C# engine's curves, the specs built from a seed plan, and the resumable batch loop.
# Inventory and rubrics are invented; the engine's HTTP side is not called (Invoke-SynthBackfillEngine is mocked).
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Test helpers that only build objects.')]
param()

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '../src/VcfOpsSynth/VcfOpsSynth.psd1') -Force
    $script:step = 300000
    $script:points = 8640
    # Monday 2026-09-07 00:00 UTC, a whole number of 5-minute steps.
    $script:start = [DateTimeOffset]::new(2026, 9, 7, 0, 0, 0, [TimeSpan]::Zero).ToUnixTimeMilliseconds()
    $script:how = [VcfOpsSynth.Backfill]::HourOfWeek($script:start, $script:step, $script:points, 'Europe/Dublin')

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

    function Get-Curve {
        param($Object, $Series)
        [VcfOpsSynth.Backfill]::Values($Series, [VcfOpsSynth.Backfill]::Shape($Object, $script:how, $script:step), $script:step)
    }
}

Describe 'Backfill engine' {
    It 'matches a LiveOptics average and peak exactly, never going below zero, for every profile' {
        foreach ($case in @(@('business-hours', 11.32, 89), @('batch', 30, 95), @('steady', 50, 60), @('idle', 2, 10), @('bursty', 8, 70), @('saturated', 85, 99))) {
            $s = New-TestSeries -Key 'cpu|usage_average' -Mode Calibrated -A $case[1] -B $case[2] -Cap 100
            $m = Get-Curve (New-TestObjectSpec -Key "vm-$($case[0])" -WorkloadProfile $case[0]) $s | Measure-Object -Average -Maximum -Minimum
            [math]::Round($m.Average, 3) | Should -Be $case[1] -Because $case[0]
            [math]::Round($m.Maximum, 3) | Should -Be $case[2] -Because $case[0]
            $m.Minimum | Should -BeGreaterOrEqual 0
        }
    }

    It 'stays flat when the LiveOptics peak is the average, rather than keeping the curve''s own peaks' {
        foreach ($workload in 'business-hours', 'bursty', 'steady') {
            $m = Get-Curve (New-TestObjectSpec -Key "vm-$workload" -WorkloadProfile $workload) (New-TestSeries -Key 'mem|usage_average' -Mode Calibrated -A 45 -B 45 -Cap 100) | Measure-Object -Average -Maximum -Minimum
            "$($m.Minimum) $($m.Average) $($m.Maximum)" | Should -Be '45 45 45' -Because $workload
        }
    }

    It 'keeps a LiveOptics peak when the average is 0: one spike at the busiest point, zero elsewhere' {
        $v = Get-Curve (New-TestObjectSpec) (New-TestSeries -Key 'virtualDisk|write_average' -Mode Calibrated -A 0 -B 51200 -Cap ([double]::NaN))
        ($v | Measure-Object -Maximum).Maximum | Should -Be 51200
        @($v | Where-Object { $_ -gt 0 }).Count | Should -Be 1
        ($v | Measure-Object -Average).Average | Should -BeLessThan 6
    }

    It 'follows the profile: busy weekday working hours, quiet nights' {
        $v = Get-Curve (New-TestObjectSpec) (New-TestSeries -Key 'cpu|usage_average' -Mode Calibrated -A 10 -B 80 -Cap 100)
        $day = 0.0; $dayN = 0; $night = 0.0; $nightN = 0
        for ($i = 0; $i -lt $v.Count; $i++) {
            $h = $script:how[$i] % 24
            if ($script:how[$i] -lt 120 -and $h -ge 10 -and $h -lt 16) { $day += $v[$i]; $dayN++ } elseif ($h -ge 1 -and $h -lt 5) { $night += $v[$i]; $nightN++ }
        }
        ($day / $dayN) | Should -BeGreaterThan (5 * $night / $nightN)
    }

    It 'meets a host''s LiveOptics average and peak when all its VMs are powered off' {
        $o = New-TestObjectSpec -Key 'esx-off' -WorkloadProfile 'off'
        $c = [VcfOpsSynth.ShapeComponent]::new(); $c.Profile = 'off'; $c.Seed = 'vm-off-2'; $c.Weight = 1
        $o.Components = @($o.Components[0], $c)
        $m = Get-Curve $o (New-TestSeries -Key 'cpu|usage_average' -Mode Calibrated -A 30 -B 90 -Cap 100) | Measure-Object -Average -Maximum -Minimum
        [math]::Round($m.Average, 3) | Should -Be 30
        [math]::Round($m.Maximum, 3) | Should -Be 90
        $m.Minimum | Should -BeGreaterOrEqual 0
    }

    It 'gives the same curve for the same seed, so a rerun overwrites with identical values' {
        $s = New-TestSeries -Key 'cpu|usage_average' -Mode Calibrated -A 10 -B 80 -Cap 100
        (Get-Curve (New-TestObjectSpec -Key 'vm-a') $s) -join ',' | Should -Be ((Get-Curve (New-TestObjectSpec -Key 'vm-a') $s) -join ',')
        (Get-Curve (New-TestObjectSpec -Key 'vm-a') $s) -join ',' | Should -Not -Be ((Get-Curve (New-TestObjectSpec -Key 'vm-b') $s) -join ',')
    }

    It 'keeps activity at its mean, capacity flat, space growing to its current value; a curve of zeros keeps the value flat' {
        $o = New-TestObjectSpec
        [math]::Round((Get-Curve $o (New-TestSeries -Key 'net|usage_average' -Mode Activity -A 250) | Measure-Object -Average).Average, 3) | Should -Be 250
        @(Get-Curve $o (New-TestSeries -Key 'cpu|capacity_provisioned' -Mode Constant -A 9600) | Sort-Object -Unique) | Should -Be @(9600)
        $ramp = Get-Curve $o (New-TestSeries -Key 'capacity|used_space' -Mode Ramp -A 100 -B 0.01)
        $ramp[-1] | Should -Be 100
        $ramp[0] | Should -BeLessThan 96
        $ramp[0] | Should -BeGreaterThan 95
        @(Get-Curve (New-TestObjectSpec -WorkloadProfile off) (New-TestSeries -Key 'mem|guest_provisioned' -Mode Activity -A 5) | Sort-Object -Unique) | Should -Be @(5)
    }

    It 'caps percentages' {
        $v = Get-Curve (New-TestObjectSpec -WorkloadProfile batch) (New-TestSeries -Key 'cpu|readyPct' -Mode Activity -A 60 -Cap 100)
        ($v | Measure-Object -Maximum).Maximum | Should -BeLessOrEqual 100
    }

    It 'reads business hours in Europe/Dublin, summer time included' {
        # 2026-09-07 08:00 UTC is 09:00 in Dublin (IST): Monday hour 9.
        $script:how[96] | Should -Be 9
        $later = [VcfOpsSynth.Backfill]::HourOfWeek([DateTimeOffset]::new(2026, 11, 2, 9, 0, 0, [TimeSpan]::Zero).ToUnixTimeMilliseconds(), $script:step, 1, 'Europe/Dublin')
        $later[0] | Should -Be 9
    }

    It 'writes stat-content bodies of at most the sample limit, with timestamps on the grid' {
        $series = @(1..5 | ForEach-Object { New-TestSeries -Key "k$_|x" -Mode Constant -A $_ })
        $o = New-TestObjectSpec -Series $series
        $samples = 0L
        $bodies = [VcfOpsSynth.Backfill]::Bodies($o, $script:start, $script:step, $script:how, 2 * $script:points, [ref]$samples)
        $bodies.Count | Should -Be 3
        $samples | Should -Be (5L * $script:points)
        $first = $bodies[0] | ConvertFrom-Json
        @($first.'stat-content').Count | Should -Be 2
        $first.'stat-content'[0].statKey | Should -Be 'k1|x'
        $first.'stat-content'[0].timestamps.Count | Should -Be $script:points
        $first.'stat-content'[0].timestamps[1] - $first.'stat-content'[0].timestamps[0] | Should -Be $script:step
        @($first.'stat-content'[1].data | Sort-Object -Unique) | Should -Be @(2)
    }
}

Describe 'Backfill specs' {
    BeforeAll {
        $script:inventory = @{
            source = @{}
            hosts  = @(@{ id = 'esx-1'; cores = 16; cpuMhz = 2000; memoryMiB = 1024; baseline = @{ perf = @{ cpuAvgPct = 30; cpuPeakPct = 90; memAvgPct = 50; memPeakPct = 70; iopsAvg = 100; iopsPeak = 900 } } })
            vms    = @(
                @{ id = 'vm-1'; powerState = 'poweredOn'; profile = 'business-hours'; host = 'esx-1'; cluster = 'cl-1'; datacenter = 'dc-1'; folderId = 'f-1'; datastores = @('ds-1'); nics = @(@{ network = 'pg-1' })
                    cpu = @{ capacityMhz = 8000; usageMhz = 1000 }; memory = @{ sizeMiB = 8192 }
                    baseline = @{ perf = @{ cpuAvgPct = 10; cpuPeakPct = 80; memAvgPct = 20; memPeakPct = 40; readIopsAvg = 5; readIopsPeak = 50 } }
                }
                @{ id = 'vm-2'; powerState = 'poweredOff'; profile = 'off'; host = 'esx-1'; cluster = 'cl-1'; datacenter = 'dc-1'; folderId = 'f-1'; datastores = @('ds-1'); nics = @()
                    cpu = @{ capacityMhz = 2000; usageMhz = 0 }; memory = @{ sizeMiB = 1024 }; baseline = @{ perf = @{ cpuAvgPct = 0; cpuPeakPct = 0 } }
                }
            )
            networks = @(@{ id = 'pg-1'; switch = 'dvs-1' })
        }
        $stat = { param($k, $v) @{ key = $k; value = $v } }
        $script:plan = @{
            objects = @(
                @{ key = 'vm-1'; kind = 'VirtualMachine'; stats = @((& $stat 'cpu|usage_average' 12.5), (& $stat 'cpu|usagemhz_average' 1000), (& $stat 'cpu|readyPct' 0.7), (& $stat 'guestfilesystem:C:\|usage' 30), (& $stat 'config|hardware|num_Cpu' 4), (& $stat 'mem|balloon' 0), (& $stat 'guest|tools_status' '-')) }
                @{ key = 'vm-2'; kind = 'VirtualMachine'; stats = @((& $stat 'cpu|usage_average' 0)) }
                @{ key = 'esx-1'; kind = 'HostSystem'; stats = @((& $stat 'cpu|usage_average' 30), (& $stat 'storage|commandsAveraged_average' 120), (& $stat 'summary|total_number_vms' 2)) }
                @{ key = 'ds-1'; kind = 'Datastore'; stats = @((& $stat 'capacity|used_space' 500), (& $stat 'capacity|total_capacity' 1000)) }
                @{ key = 'vss-1'; kind = 'StandardSwitch'; stats = @() }
                @{ key = 'gone'; kind = 'VirtualMachine'; stats = @((& $stat 'cpu|usage_average' 5)) }
            )
        }
        $script:ids = @{ 'vm-1' = 'r-vm-1'; 'vm-2' = 'r-vm-2'; 'esx-1' = 'r-esx-1'; 'ds-1' = 'r-ds-1'; 'vss-1' = 'r-vss-1' }
        $script:spec = @(New-SynthBackfillSpec -Plan $script:plan -Inventory $script:inventory -Ids $script:ids)
        $script:byKey = @{}; foreach ($o in $script:spec) { $script:byKey[$o.Key] = $o }
        function Get-Series { param($Object, $Key) @($Object.Series | Where-Object { $_.Key -eq $Key })[0] }
    }

    It 'covers objects in Ops with numeric keys, skipping text metrics, keyless kinds and objects not seeded' {
        @($script:spec | ForEach-Object Key) | Sort-Object | Should -Be @('ds-1', 'esx-1', 'vm-1', 'vm-2')
        @($script:byKey['vm-1'].Series | ForEach-Object Key) | Should -Not -Contain 'guest|tools_status'
        $script:byKey['vm-1'].ResourceId | Should -Be 'r-vm-1'
    }

    It 'calibrates VM and host keys to LiveOptics, scaled over the object''s capacity' {
        $cpu = Get-Series $script:byKey['vm-1'] 'cpu|usage_average'
        "$($cpu.Mode) $($cpu.A) $($cpu.B) $($cpu.Cap)" | Should -Be 'Calibrated 10 80 100'
        $mhz = Get-Series $script:byKey['vm-1'] 'cpu|usagemhz_average'
        "$($mhz.Mode) $($mhz.A) $($mhz.B)" | Should -Be 'Calibrated 800 6400'
        $io = Get-Series $script:byKey['esx-1'] 'storage|commandsAveraged_average'
        "$($io.Mode) $($io.A) $($io.B)" | Should -Be 'Calibrated 100 900'
    }

    It 'puts a VM''s LiveOptics disk throughput on its first disk too, since Ops sums disks into the total' {
        InModuleScope VcfOpsSynth {
            $plan = @{ objects = @(@{ key = 'vm-1'; kind = 'VirtualMachine'; stats = @(
                            @{ key = 'virtualDisk|write_average'; value = 0 }, @{ key = 'virtualDisk:scsi0:1|write_average'; value = 0 },
                            @{ key = 'virtualDisk:scsi0:0|write_average'; value = 0 }, @{ key = 'virtualDisk:scsi0:0|read_average'; value = 0 }) }) }
            $inventory = @{ datacenters = @(); clusters = @(); hosts = @(); datastores = @(); switches = @(); networks = @(); folders = @(); vms = @(@{ id = 'vm-1'; powerState = 'poweredOn'; profile = 'steady'; host = $null; cluster = $null; datacenter = $null; folderId = $null; datastores = @(); nics = @(); cpu = @{ capacityMhz = 2000; usageMhz = 100 }; memory = @{ sizeMiB = 1024 }
                        baseline = @{ perf = @{ writeMBpsAvg = 2; writeMBpsPeak = 40 } } }) }
            $series = (New-SynthBackfillSpec -Plan $plan -Inventory $inventory -Ids @{ 'vm-1' = 'r1' }).Series
            $get = { param($k) @($series | Where-Object Key -eq $k)[0] }
            "$((& $get 'virtualDisk:scsi0:0|write_average').Mode) $((& $get 'virtualDisk:scsi0:0|write_average').A) $((& $get 'virtualDisk:scsi0:0|write_average').B)" | Should -Be 'Calibrated 2048 40960'
            "$((& $get 'virtualDisk|write_average').Mode)" | Should -Be 'Calibrated'
            "$((& $get 'virtualDisk:scsi0:1|write_average').Mode) $((& $get 'virtualDisk:scsi0:1|write_average').A)" | Should -Be 'Constant 0'
            "$((& $get 'virtualDisk:scsi0:0|read_average').Mode)" | Should -Be 'Constant'
        }
    }

    It 'classifies the rest: activity, growth, flat, zero; and never calibrates a powered-off VM' {
        (Get-Series $script:byKey['vm-1'] 'cpu|readyPct').Mode | Should -Be 'Activity'
        (Get-Series $script:byKey['vm-1'] 'cpu|readyPct').Cap | Should -Be 100
        (Get-Series $script:byKey['vm-1'] 'guestfilesystem:C:\|usage').Mode | Should -Be 'Ramp'
        (Get-Series $script:byKey['vm-1'] 'config|hardware|num_Cpu').Mode | Should -Be 'Constant'
        $zero = Get-Series $script:byKey['vm-1'] 'mem|balloon'
        "$($zero.Mode) $($zero.A)" | Should -Be 'Constant 0'
        (Get-Series $script:byKey['ds-1'] 'capacity|used_space').Mode | Should -Be 'Ramp'
        (Get-Series $script:byKey['ds-1'] 'capacity|total_capacity').Mode | Should -Be 'Constant'
        $off = Get-Series $script:byKey['vm-2'] 'cpu|usage_average'
        "$($off.Mode) $($off.A)" | Should -Be 'Constant 0'
    }

    It 'shapes a host and datastore from their VMs, with the VM''s own seed and profile' {
        @($script:byKey['esx-1'].Components | ForEach-Object Seed) | Sort-Object | Should -Be @('vm-1', 'vm-2')
        @($script:byKey['esx-1'].Components | Where-Object Seed -eq 'vm-2')[0].Profile | Should -Be 'off'
        @($script:byKey['ds-1'].Components | ForEach-Object Seed) | Sort-Object | Should -Be @('vm-1', 'vm-2')
        @($script:byKey['vm-1'].Components).Count | Should -Be 1
        $script:byKey['vm-1'].Components[0].Weight | Should -Be 1
    }
}

Describe 'Keys Operations computes' {
    It 'leaves analytics, badges and capacity results to Operations' {
        InModuleScope VcfOpsSynth {
            foreach ($k in 'OnlineCapacityAnalytics|timeRemaining', 'OnlineCapacityAnalytics|mem|demand|capacityRemaining', 'badge|health', 'System Attributes|total_alert_count', 'cpu|demand|workload', 'mem|demand|active_shortterm_load', 'cpu|demand|usableCapacity', 'reclaimable|vm_count', 'rightsizing|cpu|recommendation') {
                Test-SynthComputedStatKey -Key $k | Should -BeTrue -Because $k
            }
            foreach ($k in 'cpu|demandmhz', 'mem|host_usable', 'mem|host_demand', 'capacity|usableCapacity', 'diskspace|total|usableCapacity', 'cpu|totalCapacity_average') {
                Test-SynthComputedStatKey -Key $k | Should -BeFalse -Because $k
            }
        }
    }

    It 'keeps capacity flat in the backfill, even when the name ends in _average' {
        InModuleScope VcfOpsSynth {
            foreach ($k in 'cpu|totalCapacity_average', 'cpu|haTotalCapacity_average', 'mem|host_usable', 'cpu|capacity_provisioned', 'diskspace|total_capacity') {
                "$((Get-SynthSeriesMode -Key $k).Mode)" | Should -Be 'Constant' -Because $k
            }
            "$((Get-SynthSeriesMode -Key 'cpu|capacity_usagepct_average').Mode)" | Should -Be 'Activity'
            "$((Get-SynthSeriesMode -Key 'mem|host_demand').Mode)" | Should -Be 'Activity'
        }
    }
}
Describe 'Get-SynthBackfillRange' {
    It 'ends at the last whole interval before now and holds Days of points' {
        $r = Get-SynthBackfillRange -Days 30 -IntervalMinutes 5 -Now ([DateTimeOffset]::new(2026, 10, 15, 12, 7, 30, [TimeSpan]::Zero))
        [DateTimeOffset]::FromUnixTimeMilliseconds($r.EndMs).ToString('u') | Should -Be '2026-10-15 12:00:00Z'
        $r.Points | Should -Be 8640
        ($r.EndMs - $r.StartMs) / $r.StepMs | Should -Be 8639
    }
}

Describe 'Backfill engine retry delay' {
    It 'doubles from 2 seconds up to the cap' {
        @(1..7 | ForEach-Object { [VcfOpsSynth.Backfill]::RetryDelaySeconds($_, 60, $null) }) -join ',' | Should -Be '2,4,8,16,32,60,60'
    }
    It 'takes Retry-After when the server gives it, within the cap' {
        [VcfOpsSynth.Backfill]::RetryDelaySeconds(1, 60, [TimeSpan]::FromSeconds(25)) | Should -Be 25
        [VcfOpsSynth.Backfill]::RetryDelaySeconds(1, 60, [TimeSpan]::FromSeconds(300)) | Should -Be 60
    }
}

Describe 'Backfill engine against a server that refuses large bodies' {
    BeforeAll {
        # A local listener that answers 500 to a body with more than 2 series and 200 otherwise, and counts the series it accepted.
        $script:port = Get-Random -Minimum 20000 -Maximum 60000
        $script:listener = [System.Net.HttpListener]::new(); $script:listener.Prefixes.Add("http://127.0.0.1:$script:port/"); $script:listener.Start()
        $l = $script:listener
        $script:server = Start-ThreadJob -ScriptBlock {
            $l = $using:l
            $accepted = 0; $refused = 0
            while ($l.IsListening) {
                try { $c = $l.GetContext() } catch { break }
                $body = [IO.StreamReader]::new($c.Request.InputStream).ReadToEnd()
                $n = ([regex]::Matches($body, '"statKey"')).Count
                if ($n -gt 2) { $c.Response.StatusCode = 500; $refused++ } else { $c.Response.StatusCode = 200; $accepted += $n }
                $c.Response.Close()
                if ($c.Request.Url.AbsolutePath -like '*/done') { break }
                [pscustomobject]@{ Accepted = $accepted; Refused = $refused }
            }
        }
    }
    AfterAll { $script:listener.Stop(); $script:server | Remove-Job -Force }

    It 'halves refused bodies and still posts every series once' {
        $series = @(1..8 | ForEach-Object { New-TestSeries -Key "k|$_" -Mode Constant -A 1 })
        $objects = [VcfOpsSynth.ObjectSpec[]]@(New-TestObjectSpec -Key 'vm-1' -Series $series; New-TestObjectSpec -Key 'vm-2' -Series $series)
        # 8 series of 12 points with at most 96 samples a body: one body of 8 series, refused, then 4, then 2.
        $r = [VcfOpsSynth.Backfill]::Run("http://127.0.0.1:$script:port/suite-api", 't', $false, $objects, $script:start, $script:step, 12, 'UTC', 1, 96, 30, 2, 1)
        @($r | ForEach-Object Status) -join ',' | Should -Be '0,0'
        $r[0].Splits | Should -Be 2
        # The second object starts at the size learned from the first.
        $r[1].Splits | Should -Be 0
        $r[1].Calls | Should -Be 4
        $last = @($script:server | Receive-Job)[-1]
        $last.Accepted | Should -Be 16
        $last.Refused | Should -Be 2
    }
}

Describe 'Get-SynthBackfillUnstored' {
    BeforeAll {
        $script:range = @{ StartMs = $script:start; EndMs = $script:start + 8639L * $script:step; StepMs = $script:step; Points = 8640; Days = 30 }
        $script:objs = [VcfOpsSynth.ObjectSpec[]]@(1..3 | ForEach-Object { New-TestObjectSpec -Key "vm-$_" -Series @((New-TestSeries -Key 'cpu|usage_average' -Mode Constant -A 1), (New-TestSeries -Key 'guestfilesystem:D:\|usage' -Mode Constant -A 1)) })
        for ($n = 0; $n -lt 3; $n++) { $script:objs[$n].ResourceId = "res-$($n + 1)" }
    }

    It 'returns the objects missing the last point on their first or last series, and asks for both keys escaped' {
        Mock -ModuleName VcfOpsSynth Invoke-SynthOpsRequest {
            # The last point is the request's end minus one; one step is the gap between begin and it.
            $last = [long]([regex]::Match($Path, 'end=(\d+)').Groups[1].Value) - 1
            $oneStep = $last - [long]([regex]::Match($Path, 'begin=(\d+)').Groups[1].Value)
            $stat = { param($k, $ts) [pscustomobject]@{ statKey = [pscustomobject]@{ key = $k }; timestamps = @($ts) } }
            $stats = switch -Wildcard ($Path) {
                'resources/res-1/*' { @((& $stat 'cpu|usage_average' $last), (& $stat 'guestfilesystem:D:\|usage' $last)) }
                'resources/res-2/*' { @((& $stat 'cpu|usage_average' $last), (& $stat 'guestfilesystem:D:\|usage' ($last - $oneStep))) }
                default { @() }
            }
            [pscustomobject]@{ values = @([pscustomobject]@{ 'stat-list' = [pscustomobject]@{ stat = $stats } }) }
        }
        $missing = @(InModuleScope VcfOpsSynth -Parameters @{ Objs = $script:objs; Range = $script:range } { param($Objs, $Range) Get-SynthBackfillUnstored -Spec $Objs -Range $Range })
        $missing | Should -Be @('vm-2', 'vm-3')
        Should -Invoke -ModuleName VcfOpsSynth Invoke-SynthOpsRequest -Times 1 -ParameterFilter { $Path -like 'resources/res-1/stats?*statKey=cpu%7Cusage_average&statKey=guestfilesystem%3AD%3A%5C%7Cusage' }
    }
}

Describe 'Invoke-SynthBackfill' {
    BeforeAll {
        $script:specs = [VcfOpsSynth.ObjectSpec[]]@(1..5 | ForEach-Object { New-TestObjectSpec -Key "vm-$_" -Series @(New-TestSeries -Key 'cpu|usage_average' -Mode Constant -A 1) })
        $script:range = @{ StartMs = $script:start; EndMs = $script:start + 8639L * $script:step; StepMs = $script:step; Points = 8640; Days = 30 }
    }

    BeforeEach {
        $script:statePath = Join-Path $TestDrive "state-$([guid]::NewGuid()).json"
        InModuleScope VcfOpsSynth { $script:OpsSession = @{ BaseUri = 'https://ops.example.test/suite-api'; Token = 't1'; SkipCertificateCheck = $true; TimeoutSec = 60; Config = @{}; Password = $null } }
        Mock -ModuleName VcfOpsSynth Invoke-SynthOpsRequest { }
        Mock -ModuleName VcfOpsSynth Connect-SynthOps { }
        Mock -ModuleName VcfOpsSynth Start-Sleep { }
        Mock -ModuleName VcfOpsSynth Get-SynthBackfillUnstored { }
        Mock -ModuleName VcfOpsSynth Invoke-SynthBackfillEngine {
            foreach ($o in $Batch) { $r = [VcfOpsSynth.PushResult]::new(); $r.Key = $o.Key; $r.Calls = 1; $r.Samples = 8640; $r }
        }
    }

    It 'pushes every object in batches and records them as done' {
        $result = Invoke-SynthBackfill -Spec $script:specs -Range $script:range -StatePath $script:statePath -BatchSize 2
        $result.objects | Should -Be 5
        $result.samples | Should -Be (5 * 8640)
        Should -Invoke -ModuleName VcfOpsSynth Invoke-SynthBackfillEngine -Times 3
        $state = Get-Content $script:statePath -Raw | ConvertFrom-Json
        @($state.backfill.done).Count | Should -Be 5
        [long]$state.backfill.range.StartMs | Should -Be $script:start
    }

    It 'resumes: objects already done are skipped, over the saved range' {
        $null = Invoke-SynthBackfill -Spec $script:specs[0..1] -Range $script:range -StatePath $script:statePath
        $shifted = $script:range.Clone(); $shifted.StartMs += 3600000; $shifted.EndMs += 3600000
        $result = Invoke-SynthBackfill -Spec $script:specs -Range $shifted -StatePath $script:statePath
        $result.skipped | Should -Be 2
        $result.objects | Should -Be 3
        [long](Get-Content $script:statePath -Raw | ConvertFrom-Json).backfill.range.StartMs | Should -Be $script:start
    }

    It 'signs in again and retries the objects a rejected token failed' {
        Mock -ModuleName VcfOpsSynth Invoke-SynthBackfillEngine {
            foreach ($o in $Batch) {
                $r = [VcfOpsSynth.PushResult]::new(); $r.Key = $o.Key
                if ($o.Key -eq 'vm-2' -and -not $script:rejectedOnce) { $script:rejectedOnce = $true; $r.Status = 401; $r.Error = 'HTTP 401' } else { $r.Calls = 1; $r.Samples = 8640 }
                $r
            }
        }
        $result = Invoke-SynthBackfill -Spec $script:specs -Range $script:range -StatePath $script:statePath -BatchSize 5
        $result.objects | Should -Be 5
        $result.failed.Count | Should -Be 0
        Should -Invoke -ModuleName VcfOpsSynth Connect-SynthOps -Times 1
    }

    It 'reports other failures and leaves those objects for the next run' {
        Mock -ModuleName VcfOpsSynth Invoke-SynthBackfillEngine {
            foreach ($o in $Batch) { $r = [VcfOpsSynth.PushResult]::new(); $r.Key = $o.Key; if ($o.Key -eq 'vm-3') { $r.Status = 400; $r.Error = 'HTTP 400: bad key' } else { $r.Calls = 1; $r.Samples = 8640 }; $r }
        }
        $result = Invoke-SynthBackfill -Spec $script:specs -Range $script:range -StatePath $script:statePath
        $result.failed | Should -HaveCount 1
        $result.failed[0] | Should -BeLike 'vm-3: HTTP 400*'
        @((Get-Content $script:statePath -Raw | ConvertFrom-Json).backfill.done) | Should -Not -Contain 'vm-3'
        # A 400 is not busy, so no retry pass.
        Should -Invoke -ModuleName VcfOpsSynth Invoke-SynthBackfillEngine -Times 1
    }

    It 'gives objects refused as busy more passes, one at a time, after a wait' {
        $script:busyLeft = 2
        Mock -ModuleName VcfOpsSynth Start-Sleep { }
        Mock -ModuleName VcfOpsSynth Invoke-SynthBackfillEngine {
            foreach ($o in $Batch) {
                $r = [VcfOpsSynth.PushResult]::new(); $r.Key = $o.Key
                if ($o.Key -eq 'vm-4' -and $script:busyLeft -gt 0) { $script:busyLeft--; $r.Status = 500; $r.Error = 'HTTP 500: busy' } else { $r.Calls = 1; $r.Samples = 8640 }
                $r
            }
        }
        $result = Invoke-SynthBackfill -Spec $script:specs -Range $script:range -StatePath $script:statePath -RetryPasses 2 -MaxRetryDelaySeconds 30
        $result.objects | Should -Be 5
        $result.failed.Count | Should -Be 0
        Should -Invoke -ModuleName VcfOpsSynth Invoke-SynthBackfillEngine -Times 2 -ParameterFilter { $Concurrency -eq 1 -and $Batch.Count -eq 1 -and $Batch[0].Key -eq 'vm-4' }
        Should -Invoke -ModuleName VcfOpsSynth Start-Sleep -Times 2 -ParameterFilter { $Seconds -eq 30 }
        @((Get-Content $script:statePath -Raw | ConvertFrom-Json).backfill.done) | Should -Contain 'vm-4'
    }

    It 'reports an object still busy after the last pass, once' {
        Mock -ModuleName VcfOpsSynth Start-Sleep { }
        Mock -ModuleName VcfOpsSynth Invoke-SynthBackfillEngine {
            foreach ($o in $Batch) { $r = [VcfOpsSynth.PushResult]::new(); $r.Key = $o.Key; if ($o.Key -eq 'vm-1') { $r.Status = 500; $r.Error = 'HTTP 500: busy' } else { $r.Calls = 1; $r.Samples = 8640 }; $r }
        }
        $result = Invoke-SynthBackfill -Spec $script:specs -Range $script:range -StatePath $script:statePath -RetryPasses 1
        $result.objects | Should -Be 4
        $result.failed | Should -HaveCount 1
        $result.failed[0] | Should -BeLike 'vm-1: HTTP 500*'
        Should -Invoke -ModuleName VcfOpsSynth Invoke-SynthBackfillEngine -Times 2
    }

    It 'reads back the pushed objects after the wait and reports the ones not stored' {
        Mock -ModuleName VcfOpsSynth Get-SynthBackfillUnstored { 'vm-2' }
        $result = Invoke-SynthBackfill -Spec $script:specs -Range $script:range -StatePath $script:statePath -VerifyDelaySeconds 120
        Should -Invoke -ModuleName VcfOpsSynth Start-Sleep -ParameterFilter { $Seconds -eq 120 }
        Should -Invoke -ModuleName VcfOpsSynth Get-SynthBackfillUnstored -Times 1 -ParameterFilter { $Spec.Count -eq 5 }
        $result.objects | Should -Be 4
        $result.unstored | Should -Be 1
        $result.failed | Should -HaveCount 1
        $result.failed[0] | Should -BeLike 'vm-2: posted and answered, but Operations has not stored*'
        @((Get-Content $script:statePath -Raw | ConvertFrom-Json).backfill.done) | Should -Not -Contain 'vm-2'
    }

    It 'skips the read-back with VerifyDelaySeconds 0' {
        $null = Invoke-SynthBackfill -Spec $script:specs -Range $script:range -StatePath $script:statePath -VerifyDelaySeconds 0
        Should -Invoke -ModuleName VcfOpsSynth Get-SynthBackfillUnstored -Times 0
    }

    It 'lists the objects that had a post refused, even when they went in later' {
        Mock -ModuleName VcfOpsSynth Invoke-SynthBackfillEngine {
            foreach ($o in $Batch) { $r = [VcfOpsSynth.PushResult]::new(); $r.Key = $o.Key; $r.Calls = 1; $r.Samples = 8640; if ($o.Key -eq 'vm-5') { $r.Refusals = 3; $r.Splits = 1 }; $r }
        }
        $result = Invoke-SynthBackfill -Spec $script:specs -Range $script:range -StatePath $script:statePath
        $result.objects | Should -Be 5
        @($result.refused) | Should -Be @('vm-5')
        $result.splits | Should -Be 1
    }

    It 'hands the retry settings to the engine' {
        $null = Invoke-SynthBackfill -Spec $script:specs -Range $script:range -StatePath $script:statePath -MaxRetries 7 -MaxRetryDelaySeconds 90
        Should -Invoke -ModuleName VcfOpsSynth Invoke-SynthBackfillEngine -ParameterFilter { $MaxRetries -eq 7 -and $MaxRetryDelaySeconds -eq 90 }
    }

    It 'pushes nothing with -WhatIf' {
        $null = Invoke-SynthBackfill -Spec $script:specs -Range $script:range -StatePath $script:statePath -WhatIf
        Should -Invoke -ModuleName VcfOpsSynth Invoke-SynthBackfillEngine -Times 0
        Test-Path $script:statePath | Should -BeFalse
    }
}

Describe 'Get-SynthCalibration keys' {
    It 'puts a VM''s LiveOptics IOPS and latency on the aggregate disk instance, as the vCenter adapter writes them' {
        $vm = @{ id = 'vm-1'; powerState = 'poweredOn'; cpu = @{ capacityMhz = 2000 }; memory = @{ sizeMiB = 1024 }
            baseline = @{ perf = @{ readIopsAvg = 5; readIopsPeak = 50; writeIopsAvg = 2; writeIopsPeak = 20; readLatencyAvgMs = 1.5; readLatencyPeakMs = 9; writeLatencyAvgMs = 2; writeLatencyPeakMs = 12; readMBpsAvg = 1; readMBpsPeak = 4 } } }
        $keys = @(InModuleScope VcfOpsSynth -Parameters @{ Vm = $vm } { param($Vm) (Get-SynthCalibration -Kind 'VirtualMachine' -Item $Vm).Keys })

        foreach ($leaf in 'numberReadAveraged_average', 'numberWriteAveraged_average', 'totalReadLatency_average', 'totalWriteLatency_average') {
            $keys | Should -Contain "virtualDisk:Aggregate of all instances|$leaf"
            $keys | Should -Not -Contain "virtualDisk|$leaf"
        }
        # Throughput has a plain key on real VMs.
        $keys | Should -Contain 'virtualDisk|read_average'
        $keys | Should -Contain 'storage|totalReadLatency_average'
    }

    It 'calibrates a datastore''s latency from its powered-on VMs, weighted by their IOPS' {
        $vms = @(
            @{ id = 'vm-1'; powerState = 'poweredOn'; baseline = @{ perf = @{ readLatencyAvgMs = 2; readLatencyPeakMs = 10; readIopsAvg = 300; readIopsPeak = 1000; writeLatencyAvgMs = 4; writeIopsAvg = 100 } } }
            @{ id = 'vm-2'; powerState = 'poweredOn'; baseline = @{ perf = @{ readLatencyAvgMs = 8; readLatencyPeakMs = 40; readIopsAvg = 100; readIopsPeak = 1000 } } }
            @{ id = 'vm-3'; powerState = 'poweredOff'; baseline = @{ perf = @{ readLatencyAvgMs = 500; readLatencyPeakMs = 900 } } }
            @{ id = 'vm-4'; powerState = 'poweredOn' }
        )
        $result = InModuleScope VcfOpsSynth -Parameters @{ Vms = $vms } {
            param($Vms)
            @{
                Full  = Get-SynthCalibration -Kind 'Datastore' -Item @{ id = 'ds-1' } -Vms $Vms
                Empty = Get-SynthCalibration -Kind 'Datastore' -Item @{ id = 'ds-2' } -Vms @()
            }
        }
        # Read: (2 x 300 + 8 x 100) / 400 on average, (10 x 1000 + 40 x 1000) / 2000 at peak; the powered-off VM is left out.
        "$($result.Full['datastore|totalReadLatency_average'][0]) $($result.Full['datastore|totalReadLatency_average'][1])" | Should -Be '3.5 25'
        # Write: one VM with no peak figure keeps its average as the peak.
        "$($result.Full['datastore|totalWriteLatency_average'][0]) $($result.Full['datastore|totalWriteLatency_average'][1])" | Should -Be '4 4'
        $result.Empty.Count | Should -Be 0
    }

    It 'gives a datastore''s latency series the calibrated curve in the backfill spec' {
        InModuleScope VcfOpsSynth {
            $plan = @{ objects = @(@{ key = 'ds-1'; kind = 'Datastore'; stats = @(@{ key = 'datastore|totalReadLatency_average'; value = 1.5 }, @{ key = 'datastore|totalWriteLatency_average'; value = 0 }) }) }
            $inventory = @{ datacenters = @(); clusters = @(); hosts = @(); datastores = @(@{ id = 'ds-1' }); switches = @(); networks = @(); folders = @()
                vms = @(@{ id = 'vm-1'; powerState = 'poweredOn'; profile = 'steady'; host = $null; cluster = $null; datacenter = $null; folderId = $null; datastores = @('ds-1'); nics = @(); cpu = @{ capacityMhz = 2000; usageMhz = 100 }; memory = @{ sizeMiB = 1024 }
                        baseline = @{ perf = @{ readLatencyAvgMs = 1.5; readLatencyPeakMs = 30; readIopsAvg = 10; readIopsPeak = 100 } } }) }
            $series = (New-SynthBackfillSpec -Plan $plan -Inventory $inventory -Ids @{ 'ds-1' = 'r1' }).Series
            $read = @($series | Where-Object Key -eq 'datastore|totalReadLatency_average')[0]
            "$($read.Mode) $($read.A) $($read.B)" | Should -Be 'Calibrated 1.5 30'
            # No write figures on any VM: the key stays at its seeded value.
            $write = @($series | Where-Object Key -eq 'datastore|totalWriteLatency_average')[0]
            "$($write.Mode) $($write.A)" | Should -Be 'Constant 0'
        }
    }
}
