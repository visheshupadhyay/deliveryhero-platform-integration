param(
    [string]$BaseUrl = "http://localhost:8081",
    [int]$OutletId = 1,
    [int]$Requests = 300
)

$ErrorActionPreference = "Stop"
Add-Type -AssemblyName System.Net.Http
$uri = "$BaseUrl/api/v1/outlets/$OutletId/menu"
$client = [System.Net.Http.HttpClient]::new()
$client.Timeout = [TimeSpan]::FromSeconds(30)

$results = @()
for ($i = 1; $i -le $Requests; $i++) {
    $watch = [System.Diagnostics.Stopwatch]::StartNew()
    try {
        $response = $client.GetAsync($uri).GetAwaiter().GetResult()
        $response.Content.ReadAsStringAsync().GetAwaiter().GetResult() | Out-Null
        $watch.Stop()
        $results += [pscustomobject]@{
            Success = $response.IsSuccessStatusCode
            Status = [int]$response.StatusCode
            Milliseconds = $watch.Elapsed.TotalMilliseconds
        }
    }
    catch {
        $watch.Stop()
        $results += [pscustomobject]@{
            Success = $false
            Status = 0
            Milliseconds = $watch.Elapsed.TotalMilliseconds
        }
    }
}
$ordered = @($results | Sort-Object Milliseconds)
$latencies = @($ordered | ForEach-Object Milliseconds)
$successes = @($ordered | Where-Object Success)
$start = [DateTime]::UtcNow

function Percentile([double[]]$Values, [double]$Percent) {
    if ($Values.Count -eq 0) { return 0 }
    $index = [Math]::Ceiling(($Percent / 100) * $Values.Count) - 1
    return [Math]::Round($Values[[Math]::Max(0, [int]$index)], 2)
}

[pscustomobject]@{
    Endpoint = $uri
    Requests = $Requests
    Concurrency = 1
    Successful = $successes.Count
    Failed = $Requests - $successes.Count
    P50Milliseconds = Percentile $latencies 50
    P95Milliseconds = Percentile $latencies 95
    P99Milliseconds = Percentile $latencies 99
    AverageMilliseconds = if ($latencies.Count) { [Math]::Round(($latencies | Measure-Object -Average).Average, 2) } else { 0 }
} | Format-List

$client.Dispose()
