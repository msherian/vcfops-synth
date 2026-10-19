function Get-SynthBackfillRange {
    <#
    .SYNOPSIS
        The time range a backfill covers: Days of points at the interval, ending at the last whole interval before now.

    .PARAMETER Days
        How many days of history.

    .PARAMETER IntervalMinutes
        Minutes between points.

    .PARAMETER Now
        The time to count back from; defaults to the current time.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [ValidateRange(1, 400)][int]$Days = 30,
        [ValidateRange(1, 60)][int]$IntervalMinutes = 5,
        [Nullable[DateTimeOffset]]$Now
    )

    $step = $IntervalMinutes * 60000
    $nowMs = if ($Now) { ([DateTimeOffset]$Now).ToUnixTimeMilliseconds() } else { [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds() }
    $end = [long]([math]::Floor($nowMs / $step) * $step) - $step
    $points = [int]($Days * 1440 / $IntervalMinutes)
    @{ StartMs = $end - [long]($points - 1) * $step; EndMs = $end; StepMs = $step; Points = $points; Days = $Days }
}

function Resolve-SynthPlanId {
    <#
    .SYNOPSIS
        Finds each planned object in Operations by its unique identifier and returns plan key to resource ID.

    .PARAMETER Plan
        A plan from New-SynthSeedPlan.

    .PARAMETER AdapterInstanceId
        The vCenter adapter instance the VMWARE objects sit under.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$Plan,
        [Parameter(Mandatory)][string]$AdapterInstanceId
    )

    $ids = @{}
    foreach ($kind in Get-SynthSeedKind) {
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
            if ($match) { $ids[$object.key] = $match.id }
        }
    }
    $ids
}

function Invoke-SynthBackfill {
    <#
    .SYNOPSIS
        Pushes back-dated history for every numeric stat key of the seeded objects.

    .DESCRIPTION
        Builds a spec per object (New-SynthBackfillSpec) and hands batches to the
        engine, which generates each object's history and posts it with
        analytics processing off, several objects at a time. After each batch the
        keys done are saved to the state file, so a run that stops resumes where
        it left off over the same time range; a token rejected mid-run is renewed
        and the batch's failures retried once.

        A busy Operations (seen on a lab node short of memory) answers some posts
        with HTTP 500 for minutes at a time. Each post is retried up to MaxRetries
        times with waits growing to MaxRetryDelaySeconds, and objects still refused
        as busy (429 or 5xx) get up to RetryPasses more tries at the end of the run,
        one object at a time.

        Run Connect-SynthOps first.

    .PARAMETER Spec
        Object specs from New-SynthBackfillSpec.

    .PARAMETER Range
        The time range from Get-SynthBackfillRange.

    .PARAMETER StatePath
        File that records the range and the objects done, for resuming.

    .PARAMETER TimeZone
        Time zone the workload profiles' hours are in.

    .PARAMETER Concurrency
        Objects posted at the same time.

    .PARAMETER BatchSize
        Objects per engine call, between state saves.

    .PARAMETER MaxSamplesPerCall
        Upper bound on samples in one POST.

    .PARAMETER MaxRetries
        Retries of one POST answered with 429 or 5xx before the object is given up for this pass.

    .PARAMETER MaxRetryDelaySeconds
        Longest wait between retries; the waits are 2, 4, 8 seconds and so on up to this, or Retry-After.

    .PARAMETER RetryPasses
        Passes at the end of the run over the objects refused as busy, one object at a time,
        each after a wait of MaxRetryDelaySeconds.

    .EXAMPLE
        Invoke-SynthBackfill -Spec $spec -Range (Get-SynthBackfillRange -Days 30) -StatePath ./data/state.json
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][VcfOpsSynth.ObjectSpec[]]$Spec,
        [Parameter(Mandatory)][hashtable]$Range,
        [Parameter(Mandatory)][string]$StatePath,
        [string]$TimeZone = 'Europe/Dublin',
        [ValidateRange(1, 32)][int]$Concurrency = 4,
        [ValidateRange(1, 1000)][int]$BatchSize = 20,
        [ValidateRange(1000, 5000000)][int]$MaxSamplesPerCall = 500000,
        [ValidateRange(0, 30)][int]$MaxRetries = 10,
        [ValidateRange(1, 600)][int]$MaxRetryDelaySeconds = 60,
        [ValidateRange(0, 10)][int]$RetryPasses = 2
    )

    if (-not $script:OpsSession) { throw 'Not signed in to VCF Operations; run Connect-SynthOps first.' }
    $state = Read-SynthBackfillState -Path $StatePath -Range $Range
    $done = [System.Collections.Generic.HashSet[string]]::new([string[]]@($state.done))
    $todo = @($Spec | Where-Object { -not $done.Contains($_.Key) })
    $result = [ordered]@{ objects = 0; samples = 0L; calls = 0; skipped = $Spec.Count - $todo.Count; failed = [System.Collections.Generic.List[string]]::new(); seconds = 0 }
    if (-not $todo.Count) { return $result }
    if (-not $PSCmdlet.ShouldProcess("$($todo.Count) objects, $($state.range.Points) points each", 'Backfill history')) { return $result }

    $engine = @{ State = $state; TimeZone = $TimeZone; MaxSamplesPerCall = $MaxSamplesPerCall; MaxRetries = $MaxRetries; MaxRetryDelaySeconds = $MaxRetryDelaySeconds }
    # The last failure of each object not done, by key; a later pass replaces or clears it.
    $failure = [ordered]@{}
    $clock = [Diagnostics.Stopwatch]::StartNew()
    $passes = @(@{ Name = ''; Objects = $todo; Concurrency = $Concurrency })
    for ($pass = 0; $pass -lt $passes.Count; $pass++) {
        $list = @($passes[$pass].Objects)
        if ($pass) {
            Write-Verbose ('{0:HH:mm:ss}Z {1}: {2} objects refused as busy; trying again one at a time in {3} s' -f [DateTime]::UtcNow, $passes[$pass].Name, $list.Count, $MaxRetryDelaySeconds)
            Start-Sleep -Seconds $MaxRetryDelaySeconds
        }
        $passSamples = 0L
        $passClock = [Diagnostics.Stopwatch]::StartNew()
        for ($i = 0; $i -lt $list.Count; $i += $BatchSize) {
            $batch = [VcfOpsSynth.ObjectSpec[]]@($list[$i..([math]::Min($i + $BatchSize, $list.Count) - 1)])
            $batchStart = $clock.Elapsed
            # A cheap call first, so an expired token is renewed before the engine uses it.
            $null = Invoke-SynthOpsRequest -Method Get -Path 'versions/current'
            $outcome = @(Invoke-SynthBackfillEngine -Batch $batch -Concurrency $passes[$pass].Concurrency @engine)
            $rejected = @($outcome | Where-Object { $_.Status -eq 401 })
            if ($rejected.Count) {
                $null = Connect-SynthOps -Config $script:OpsSession.Config -Password $script:OpsSession.Password
                $retry = [VcfOpsSynth.ObjectSpec[]]@($batch | Where-Object { $_.Key -in @($rejected | ForEach-Object Key) })
                $again = @{}
                foreach ($r in (Invoke-SynthBackfillEngine -Batch $retry -Concurrency $passes[$pass].Concurrency @engine)) { $again[$r.Key] = $r }
                $outcome = @($outcome | ForEach-Object { if ($again.ContainsKey($_.Key)) { $again[$_.Key] } else { $_ } })
            }
            foreach ($r in $outcome) {
                $result.calls += $r.Calls
                if ($r.Status -eq 0) {
                    $result.objects++
                    $result.samples += $r.Samples
                    $passSamples += $r.Samples
                    $null = $done.Add($r.Key)
                    $failure.Remove($r.Key)
                }
                else { $failure[$r.Key] = $r }
            }
            $state.done = @($done)
            Save-SynthBackfillState -Path $StatePath -State $state
            $finished = [math]::Min($i + $BatchSize, $list.Count)
            $rate = if ($passClock.Elapsed.TotalSeconds -gt 0) { $passSamples / $passClock.Elapsed.TotalSeconds } else { 0 }
            Write-Progress -Activity "Backfilling history$($passes[$pass].Name)" -Status ('{0} of {1} objects, {2:N0} samples ({3:N0}/s)' -f $finished, $list.Count, $passSamples, $rate) -PercentComplete ($finished / $list.Count * 100)
            # Time of day, batch duration and an estimate of the rest, to see how each batch is going.
            $batchSeconds = ($clock.Elapsed - $batchStart).TotalSeconds
            $left = if ($finished) { [TimeSpan]::FromSeconds($passClock.Elapsed.TotalSeconds / $finished * ($list.Count - $finished)) } else { [TimeSpan]::Zero }
            Write-Verbose ('{0:HH:mm:ss}Z {1}{2} of {3} objects, {4:N0} samples, {5:N0} samples/s; batch {6:N1} s, about {7:hh\:mm\:ss} left' -f [DateTime]::UtcNow, $(if ($pass) { "$($passes[$pass].Name): " }), $finished, $list.Count, $passSamples, $rate, $batchSeconds, $left)
        }
        # Objects refused as busy get another pass, one at a time, while passes are left.
        $busy = @($list | Where-Object { $failure.Contains($_.Key) -and ($failure[$_.Key].Status -eq 429 -or $failure[$_.Key].Status -ge 500) })
        if ($busy.Count -and $passes.Count -le $RetryPasses) { $passes += @{ Name = "retry pass $($passes.Count) of $RetryPasses"; Objects = $busy; Concurrency = 1 } }
    }
    Write-Progress -Activity 'Backfilling history' -Completed
    foreach ($r in $failure.Values) { $result.failed.Add("$($r.Key): $($r.Error)") }
    $result.seconds = [int]$clock.Elapsed.TotalSeconds
    $result
}

function Invoke-SynthBackfillEngine {
    <# One engine call for a batch, with the session's address, token and certificate setting. #>
    [CmdletBinding()]
    [OutputType([VcfOpsSynth.PushResult])]
    param(
        [Parameter(Mandatory)][VcfOpsSynth.ObjectSpec[]]$Batch,
        [Parameter(Mandatory)][hashtable]$State,
        [Parameter(Mandatory)][string]$TimeZone,
        [Parameter(Mandatory)][int]$Concurrency,
        [Parameter(Mandatory)][int]$MaxSamplesPerCall,
        [Parameter(Mandatory)][int]$MaxRetries,
        [Parameter(Mandatory)][int]$MaxRetryDelaySeconds
    )
    $session = $script:OpsSession
    [VcfOpsSynth.Backfill]::Run($session.BaseUri, $session.Token, [bool]$session.SkipCertificateCheck, $Batch,
        [long]$State.range.StartMs, [int]$State.range.StepMs, [int]$State.range.Points, $TimeZone, $Concurrency, $MaxSamplesPerCall, [int][math]::Max(120, $session.TimeoutSec),
        $MaxRetries, $MaxRetryDelaySeconds)
}

function Read-SynthBackfillState {
    <#
    .SYNOPSIS
        The backfill part of the state file: the range in use and the objects done.

    .DESCRIPTION
        A saved range with the same length and interval is reused, so a resumed
        run writes the same timestamps; otherwise the new range starts afresh.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][hashtable]$Range
    )
    $all = if (Test-Path -LiteralPath $Path) { Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json -AsHashtable } else { @{} }
    if (-not $all) { $all = @{} }
    $saved = if ($all.ContainsKey('backfill')) { $all.backfill } else { $null }
    if ($saved -and $saved.range -and [int]$saved.range.Points -eq $Range.Points -and [long]$saved.range.StepMs -eq $Range.StepMs) {
        return @{ range = $saved.range; done = @($saved.done) }
    }
    @{ range = $Range; done = @() }
}

function Save-SynthBackfillState {
    <# Writes the backfill part of the state file, keeping anything else in it. #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][hashtable]$State
    )
    $all = if (Test-Path -LiteralPath $Path) { Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json -AsHashtable } else { @{} }
    if (-not $all) { $all = @{} }
    $all.backfill = [ordered]@{ range = $State.range; done = @($State.done); updatedAt = [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ', [cultureinfo]::InvariantCulture) }
    $folder = Split-Path -Parent $Path
    if ($folder -and -not (Test-Path -LiteralPath $folder)) { $null = New-Item -ItemType Directory -Path $folder }
    if ($PSCmdlet.ShouldProcess($Path, 'Save backfill state')) {
        $temp = "$Path.tmp"
        $all | ConvertTo-Json -Depth 6 -Compress | Set-Content -LiteralPath $temp -Encoding utf8
        Move-Item -LiteralPath $temp -Destination $Path -Force
    }
}
