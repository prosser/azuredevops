using namespace System.Collections.Generic
using namespace System.Text.RegularExpressions

param(
    [Parameter(Mandatory = $true)]
    [int] $BuildDefinition,
    [Parameter(Mandatory = $true)]
    [string] $Organization,
    [Parameter(Mandatory = $true)]
    [string] $Project,
    [string] $OutputPath = "$PSScriptRoot\TestStatistics.json",
    [string] $PersonalAccessToken,
    [int] $BatchSize = 3
)

$baseUrl = "https://dev.azure.com/{0}/{1}/_apis/build" -f $Organization.Replace(" ", "%20"),$Project.Replace(" ", "%20")
$ver = "api-version=5.1"

class Batch {
    [SortedList[string, TimeSpan]] $TestCases = [SortedList[string, TimeSpan]]::new()
    [TimeSpan] $TotalDuration

    [List[KeyValuePair[string, TimeSpan]]] GetSlowTests([TimeSpan] $threshold) {
        $result = [List[KeyValuePair[string, TimeSpan]]]::new()
        foreach ($testCase in $this.TestCases.GetEnumerator()) {
            if ($testCase.Value -ge $threshold) {
                $result.Add($testCase)
            }
        }
        return $result
    }

    [Hashtable] ToSerializable() {
        $result = @{
            TestCases     = [SortedList[string, string]]::new()
            TotalDuration = $this.TotalDuration.ToString()
        }

        foreach ($kvp in $this.TestCases.GetEnumerator()) {
            $result.TestCases.Add($kvp.Key, $kvp.Value.ToString())
        }

        return $result
    }
}

class BatchConfiguration {
    [List[Batch]] $Batches
    [SortedDictionary[string, TimeSpan]] $SlowTests

    static [BatchConfiguration] Create($testCases, [int] $numBatches, [TimeSpan] $slowTestThreshold) {
        $config = [BatchConfiguration]::new()
        $config.Batches = [List[Batch]]::new($numBatches)
        for ($i = 0; $i -lt $numBatches; $i++) {
            $config.Batches.Add([Batch]::new())
        }
        $config.SlowTests = [SortedDictionary[string, TimeSpan]]::new()

        $byName = @{ }
        foreach ($testCase in $testCases) {
            if (!$byName[$testCase.Name] -or $byName[$testCase.Name].Duration -lt $testCase.Duration) {
                $byName[$testCase.Name] = $testCase
            }
        }

        foreach ($testCase in ($byName.Values | Sort-Object -Property Duration -Descending)) {
            [Batch] $batch = $config.Batches | Sort-Object -Property TotalDuration | Select-Object -First 1
            $batch.TotalDuration += $testCase.Duration
            $batch.TestCases.Add($testCase.Name, $testCase.Duration)
            if ($testCase.Duration -ge $slowTestThreshold) {
                $config.SlowTests.Add($testCase.Name, $testCase.Duration)
            }
        }

        return $config;
    }

    [Hashtable] ToSerializable() {
        $result = @{
            CreatedDate = (Get-Date).ToString("o")
            Batches     = @()
            SlowTests   = [SortedDictionary[string, string]]::new()
        }

        foreach ($batch in $this.Batches) {
            $result.Batches += $batch.ToSerializable()
        }

        foreach ($kvp in $this.SlowTests.GetEnumerator()) {
            $result.SlowTests.Add($kvp.Key, $kvp.Value.ToString())
        }

        return $result
    }
}

function FindAndParseTestLog {
    param([string] $BuildId)
    $testCases = @()

    # find and parse the test log
    $logs = (ApiGet -Uri ("{0}/builds/{1}/logs?{2}" -f $baseUrl, $id, $ver)).value

    for ($i = $logs.Length; $i -ge 0; $i--) {
        $log = $logs[$i]
        if ($log.lineCount -lt 500) {
            continue
        }
        $logLine = ApiGet -Uri ("$baseUrl/builds/$BuildId/logs/{0}?startLine=1&endLine=2&$ver" -f $log.id)
    
        if ($logLine -match "##\[section\]Starting: Test") {
            # parse the test case info from the log
            $lines = (ApiGet -Uri ("$baseUrl/builds/$id/logs/{0}?$ver" -f $log.id)) #.Split("`n")
            #2019-08-29T11:23:22.2689109Z   â MyTestName [1s 4ms]
            [Regex] $regex = [Regex]::new("[^\w\.\s]+ (?<name>\w+) \[(?<epsilon>< )?(?<value1>\d+)(?<unit1>m|s|ms)( (?<value2>\d+)(?<unit2>s|ms))?\]")
            foreach ($line in $lines.Split("`n")) {
                $match = $regex.Match($line)
                if ($match.Success) {
                    $testCases += @{ Name = $match.Groups["name"].Value; Duration = (ParseDuration $match) }
                }
            }
    
        }
    }
    return $testCases    
}

function ApiGet {
    param($Uri)

    Write-Host -ForegroundColor Cyan "### Requesting $Uri"
    $scheme = "bearer"
    $token = $env:SYSTEM_ACCESSTOKEN
    if ($PersonalAccessToken) {
        $token = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes(("{0}:{1}" -f "", $PersonalAccessToken))) 
        $scheme = "basic"
    }
    if (!$token) {
        throw [ArgumentException]::new("No system access token available, and -PersonalAccessToken was not specified. Did you remember to allow scripts access to the OAuth token?")
    }

    $headers = @{ Authorization = "$scheme $token" }
    Invoke-RestMethod -Uri $Uri -Headers $headers
}

function GetDuration {
    param([System.Text.RegularExpressions.Group] $ValueGroup, [System.Text.RegularExpressions.Group] $UnitGroup)
    if ($valueGroup.Success) {
        return [TimeSpan]::FromMilliseconds(([int]$valueGroup.Value * (GetUnitMultiplier $UnitGroup.Value)))
    }
    return [TimeSpan]::Zero
}

function GetUnitMultiplier {
    param([string] $Unit)
    switch ($Unit) {
        "m" { return 60 * 1000 }
        "s" { return 1000 }
        "ms" { return 1 }
        default { throw [NotSupportedException]::new() }
    }
}

function ParseDuration {
    param([System.Text.RegularExpressions.Match] $match)
    if ($match.Groups["epsilon"].Success) {
        return [TimeSpan]::FromMilliseconds(0.5)
    }

    return (GetDuration -ValueGroup $match.Groups["value1"] -UnitGroup $match.Groups["unit1"]) +
    (GetDuration -ValueGroup $match.Groups["value2"] -UnitGroup $match.Groups["unit2"])
}

$pipeline = ApiGet -Uri ("{0}/builds?statusFilter=completed&resultFilter=succeeded&maxBuildsPerDefinition=1&queryOrder=finishTimeDescending&definitions={1}&{2}" -f $baseUrl, $BuildDefinition, $ver)

$latestBuild = $pipeline.value | Sort-Object -Property finishTime -Descending | Select-Object -First 1
$id = $latestBuild.id

$testCases = FindAndParseTestLog -BuildId $latestBuild.Id

$config = [BatchConfiguration]::Create($testCases, $BatchSize, [TimeSpan]::FromSeconds(10))

$json = $config.ToSerializable() | ConvertTo-Json -Depth 100

if ($OutputPath) {
    Write-Host "Writing batch configuration to $OutputPath"
    $json | Out-File $OutputPath
}
else {
    $json | Out-Host
}
