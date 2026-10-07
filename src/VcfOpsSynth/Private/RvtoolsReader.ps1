function Read-SynthRvtoolsSource {
    <#
    .SYNOPSIS
        Reads the RVTools tabs the importer uses from an xlsx export or a folder of CSV exports.

    .DESCRIPTION
        An xlsx export holds one worksheet per tab. The CSV export (RVTools -c
        ExportAll2csv) writes one file per tab, named RVTools_tab<tab>.csv; a folder
        holding those files is accepted, as are files named <tab>.csv.

        Rows come back as case-insensitive hashtables keyed by column header, so
        both formats look the same to the importer. Tabs not in the export are
        left out; the importer decides which ones it cannot do without.

    .OUTPUTS
        @{ Format; Source; Tabs = @{ <tab> = @{ Headers; Rows } } }
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][string]$Path,
        [string[]]$Tab = @('vInfo', 'vCPU', 'vMemory', 'vHost', 'vCluster', 'vDatastore', 'vPartition', 'vSnapshot', 'vTools', 'vMetaData')
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        throw "RVTools export '$Path' was not found. Put the xlsx, or the folder of CSV files, under /data."
    }
    $item = Get-Item -LiteralPath $Path
    $result = @{ Source = $item.FullName; Tabs = @{} }

    if ($item.PSIsContainer) {
        $result.Format = 'csv'
        $files = Get-ChildItem -LiteralPath $item.FullName -Filter '*.csv' -File
        foreach ($name in $Tab) {
            $file = $files | Where-Object { $_.Name -ieq "RVTools_tab$name.csv" -or $_.Name -ieq "$name.csv" } | Select-Object -First 1
            if ($file) { $result.Tabs[$name] = Read-SynthRvtoolsCsv -Path $file.FullName }
        }
        if ($result.Tabs.Count -eq 0) {
            throw "Folder '$Path' holds no RVTools CSV files. Expected names such as RVTools_tabvInfo.csv."
        }
    }
    elseif ($item.Extension -ieq '.xlsx') {
        $result.Format = 'xlsx'
        if (-not (Get-Module -Name ImportExcel)) {
            try { Import-Module -Name ImportExcel -ErrorAction Stop -WarningAction SilentlyContinue }
            catch { throw 'Reading xlsx needs the ImportExcel module, which the image includes. Install it with: Install-PSResource ImportExcel' }
        }
        $sheets = @(Get-ExcelSheetInfo -Path $item.FullName | ForEach-Object Name)
        foreach ($name in $Tab) {
            $sheet = $sheets | Where-Object { $_ -ieq $name } | Select-Object -First 1
            if ($sheet) { $result.Tabs[$name] = Read-SynthRvtoolsSheet -Path $item.FullName -Worksheet $sheet }
        }
    }
    else {
        throw "'$Path' is neither an .xlsx file nor a folder of RVTools CSV files."
    }
    $result
}

function Read-SynthRvtoolsSheet {
    <# Reads one worksheet into header-keyed hashtables. #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Worksheet
    )

    $records = @(Import-Excel -Path $Path -WorksheetName $Worksheet -ErrorAction Stop)
    $headers = if ($records.Count -gt 0) { @($records[0].PSObject.Properties.Name) } else { @() }
    @{ Headers = $headers; Rows = @($records | ForEach-Object { ConvertTo-SynthRowTable -Record $_ }) }
}

function Read-SynthRvtoolsCsv {
    <#
    .SYNOPSIS
        Reads one RVTools CSV file into header-keyed hashtables.

    .DESCRIPTION
        RVTools writes the list separator of the Windows locale it ran under, so a
        file from a European desktop may use semicolons. The header line decides.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([Parameter(Mandatory)][string]$Path)

    $first = Get-Content -LiteralPath $Path -TotalCount 1
    if ([string]::IsNullOrWhiteSpace($first)) { return @{ Headers = @(); Rows = @() } }
    $delimiter = if (($first.Split(';').Count) -gt ($first.Split(',').Count)) { ';' } else { ',' }

    $records = @(Import-Csv -LiteralPath $Path -Delimiter $delimiter)
    # Read the header line as a data row, so headers are known even for a tab with no rows.
    $columns = 1..($first.Split($delimiter).Count)
    $headers = @(ConvertFrom-Csv -InputObject $first -Delimiter $delimiter -Header $columns |
        ForEach-Object { $_.PSObject.Properties.Value } | Where-Object { $_ } | ForEach-Object { $_.Trim() })
    @{ Headers = $headers; Rows = @($records | ForEach-Object { ConvertTo-SynthRowTable -Record $_ }) }
}

function ConvertTo-SynthRowTable {
    <# Turns a row object into a case-insensitive hashtable, with blank cells as $null. #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([Parameter(Mandatory)]$Record)

    $row = @{}
    foreach ($property in $Record.PSObject.Properties) {
        $value = $property.Value
        if ($value -is [string] -and [string]::IsNullOrWhiteSpace($value)) { $value = $null }
        $row[$property.Name.Trim()] = $value
    }
    $row
}

function ConvertTo-SynthNumber {
    <#
    .SYNOPSIS
        Reads a numeric cell from either format; $null when blank or unreadable.

    .DESCRIPTION
        xlsx cells arrive as numbers already. CSV cells are text, written with
        invariant digits by RVTools; thousands separators are tolerated.
    #>
    [CmdletBinding()]
    [OutputType([double])]
    param([AllowNull()]$Value)

    if ($null -eq $Value) { return $null }
    if ($Value -is [double] -or $Value -is [int] -or $Value -is [long] -or $Value -is [decimal] -or $Value -is [single]) {
        return [double]$Value
    }
    $text = ([string]$Value).Trim().TrimEnd('%').Trim()
    $number = 0.0
    $styles = [System.Globalization.NumberStyles]::Float -bor [System.Globalization.NumberStyles]::AllowThousands
    if ([double]::TryParse($text, $styles, [System.Globalization.CultureInfo]::InvariantCulture, [ref]$number)) {
        return $number
    }
    $null
}

function ConvertTo-SynthBoolean {
    <# Reads True/False, Yes/No or 1/0 from either format; $null when blank or unreadable. #>
    [CmdletBinding()]
    [OutputType([bool])]
    param([AllowNull()]$Value)

    if ($null -eq $Value) { return $null }
    if ($Value -is [bool]) { return $Value }
    switch -Regex (([string]$Value).Trim()) {
        '^(true|yes|1)$' { return $true }
        '^(false|no|0)$' { return $false }
    }
    $null
}

function ConvertTo-SynthDateText {
    <#
    .SYNOPSIS
        Reads a date cell and returns it as yyyy-MM-ddTHH:mm:ss, or $null.

    .DESCRIPTION
        RVTools records vCenter local time without a zone, so none is added here.
        xlsx cells may arrive as DateTime or as an OLE Automation day number.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([AllowNull()]$Value)

    if ($null -eq $Value) { return $null }
    $format = 'yyyy-MM-ddTHH:mm:ss'
    if ($Value -is [datetime]) { return $Value.ToString($format, [cultureinfo]::InvariantCulture) }
    if ($Value -is [double]) { return [datetime]::FromOADate($Value).ToString($format, [cultureinfo]::InvariantCulture) }

    $parsed = [datetime]::MinValue
    foreach ($culture in [cultureinfo]::InvariantCulture, [cultureinfo]::CurrentCulture) {
        if ([datetime]::TryParse([string]$Value, $culture, [System.Globalization.DateTimeStyles]::None, [ref]$parsed)) {
            return $parsed.ToString($format, [cultureinfo]::InvariantCulture)
        }
    }
    $null
}

function ConvertTo-SynthText {
    <#
    .SYNOPSIS
        Reads a text cell from either format; $null when blank.

    .DESCRIPTION
        Excel stores text that looks like a number (a Tools version such as 12416)
        as a number, so the xlsx reader returns 12416.0 where the CSV reader
        returns "12416". This returns "12416" for both.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([AllowNull()]$Value)

    if ($null -eq $Value) { return $null }
    if ($Value -is [double] -and $Value -eq [math]::Floor($Value) -and [math]::Abs($Value) -lt 1e15) {
        return ([long]$Value).ToString([cultureinfo]::InvariantCulture)
    }
    if ($Value -is [System.IFormattable]) { return $Value.ToString($null, [cultureinfo]::InvariantCulture) }
    $text = ([string]$Value).Trim()
    if ($text) { $text } else { $null }
}
