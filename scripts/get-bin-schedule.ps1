# Fetches upcoming bin collections from York Council waste API.
# Usage: pwsh -File get-bin-schedule.ps1 [-DaysAhead 7]
# Returns JSON array of upcoming collections within the window.

param(
    [int]$DaysAhead = 7
)

$configPath = "$PSScriptRoot\..\config\bin-config.json"
if (-not (Test-Path $configPath)) {
    Write-Error "bin-config.json not found. Create it with: { ""uprn"": ""YOUR_UPRN"" }"
    exit 1
}
$config = Get-Content $configPath | ConvertFrom-Json
$uprn = $config.uprn

$response = Invoke-RestMethod "https://waste-api.york.gov.uk/api/Collections/GetBinCollectionDataForUprn/$uprn"
$today = [datetime]::Today
$cutoff = $today.AddDays($DaysAhead)

$upcoming = [System.Collections.Generic.List[PSCustomObject]]::new()

foreach ($svc in $response.services) {
    $nextDate = [datetime]::Parse($svc.nextCollection, [System.Globalization.CultureInfo]::InvariantCulture)

    # If nextCollection is exactly 14 days out, the API already flipped past today's collection
    if (($nextDate.Date - $today).Days -eq 14) {
        $upcoming.Add([PSCustomObject]@{
            service     = $svc.service
            date        = $today.ToString("yyyy-MM-dd")
            dayOfWeek   = $today.DayOfWeek.ToString()
            description = $svc.binDescription
        })
    }

    if ($nextDate -ge $today -and $nextDate -le $cutoff) {
        $upcoming.Add([PSCustomObject]@{
            service     = $svc.service
            date        = $nextDate.ToString("yyyy-MM-dd")
            dayOfWeek   = $nextDate.DayOfWeek.ToString()
            description = $svc.binDescription
        })
    }
}

$upcoming | Sort-Object date | ConvertTo-Json -Depth 2
