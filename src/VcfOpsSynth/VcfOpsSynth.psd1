@{
    RootModule        = 'VcfOpsSynth.psm1'
    ModuleVersion     = '0.1.0'
    GUID              = '5d0f3b3e-8a4c-4f0e-9a52-2f7c1c6a9e41'
    Author            = 'Matthew Sherian'
    Description       = 'Builds a synthetic estate in VCF Operations from RVTools exports and pushes history, live metrics and Day-2 content through the Suite API.'
    PowerShellVersion = '7.4'
    FunctionsToExport = @(
        'Get-SynthConfig'
        'Test-SynthConfig'
        'Connect-SynthOps'
        'Disconnect-SynthOps'
        'Invoke-SynthOpsRequest'
        'Get-SynthOpsVersion'
    )
    CmdletsToExport   = @()
    VariablesToExport = @()
    AliasesToExport   = @()
}
