<#
.SYNOPSIS
Get-CinebenchR20Scores.ps1 - Automated execution of Cinebench R20.

.DESCRIPTION 
Automates the execution of multiple runs of the MAXON Cinebench R20 benchmark and calculates the average, minimum,
maximum and standard deviation figures from the scores obtained from all runs.

.INPUTS
None.

.OUTPUTS
Results are written to the console, optionally to a file.

.PARAMETER Runs
Number of runs executed for each thread count. Acceptable values are 1-100 with the default at 3. For more precise
results, specify a value in the range of 5-10.

.PARAMETER Threads
Comma-separated list of different thread counts for each set of runs. The default is the maximum number of threads
(logical cores) your CPU supports.

.PARAMETER Cooldown
Number of seconds to wait between each run. Acceptable values are 0-600 with the default at 120. This is used to
ensure that the temperatures of your CPU, cooling system and chassis after every run have dropped down to idle
levels. If there is a large fluctuation in the individual scores for each thread count (also indicated by large
STDEV% values) and there are no other CPU-intensive processes running, try larger values.

.PARAMETER IdleWait
Number of seconds to wait before first run. Acceptable values are 0-1200 with the default at 0. This is used to
ensure that the system has settled to an idle state with minimal to no background process activity, especially
when the script is run shortly after a fresh boot into Windows.

.PARAMETER ExePath
Path and filename of the Cinebench R20 executable. By default it is assumed to be located in the same directory as
this script and to have a filename of "Cinebench.exe".

.EXAMPLE
PS> .\Get-CinebenchScores.ps1
Runs 3 executions with the max amount of threads your CPU supports.

.EXAMPLE
PS> .\Get-CinebenchScores.ps1 -Runs 5
Runs 5 executions with the max amount of threads your CPU supports.

.EXAMPLE
PS> .\Get-CinebenchScores.ps1 5
Same as example 2.

.EXAMPLE
PS> .\Get-CinebenchScores.ps1 -Runs 10 -Threads 4
Runs 10 executions with 4 threads used.

.EXAMPLE
PS> .\Get-CinebenchScores.ps1 10 4
Same as example 4.

.EXAMPLE
PS> .\Get-CinebenchScores.ps1 -Runs 5 -Threads 16,4,1 -Cooldown 300
Runs with 16, 4 and 1 threads, 5 executions each, with a 5min cooldown.

.EXAMPLE
PS> .\Get-CinebenchScores.ps1 5 16,4,1 300 -IdleWait 600
Same as example 6, but with an initial wait period of 10mins to settle to idle.

.EXAMPLE
PS> .\Get-CinebenchScores.ps1 -ExePath "C:\Apps\CB20\Cinebench.exe"
Runs with default settings using the CB R20 executable at the specified path.

.LINK
https://github.com/AlexGidarakos/Get-CinebenchScores

.NOTES
Version: 0.1
Author: Alexandros Gidarakos
Email: algida79@gmail.com
Change Log
v0.1 - 2021-11-06 - Initial version
#>

[CmdletBinding()]
Param(
    [Parameter(
        Mandatory = $false,
        ValueFromPipeline = $false,
        ValueFromPipelineByPropertyName = $false,
        Position = 0
        )]
    [ValidateRange(1, 100)]
    [Int] $Runs = 3,
    [Parameter(
        Mandatory = $false,
        ValueFromPipeline = $false,
        ValueFromPipelineByPropertyName = $false,
        Position = 1
        )]
    [ValidatePattern("^\d+$|^(\d+,)+\d+$")]
    [Int[]] $Threads = (Get-CimInstance Win32_ComputerSystem).NumberOfLogicalProcessors,
    [Parameter(
        Mandatory = $false,
        ValueFromPipeline = $false,
        ValueFromPipelineByPropertyName = $false,
        Position = 2
        )]
    [ValidateRange(0, 600)]
    [Int] $Cooldown = 120,
    [Parameter(
        Mandatory = $false,
        ValueFromPipeline = $false,
        ValueFromPipelineByPropertyName = $false,
        Position = 3
        )]
    [ValidateRange(0, 1200)]
    [Int] $IdleWait = 0,
    [Parameter(
        Mandatory = $false,
        ValueFromPipeline = $false,
        ValueFromPipelineByPropertyName = $false,
        Position = 4
        )]
    [String] $ExePath = $PSScriptRoot + "\Cinebench.exe"
)

BEGIN {
    # Initializations
    $PrefsFileSearch = "$Env:APPDATA\MAXON\cb20_*\cinebenchprefs\CINEMA 4D.prf"

    # Sanity checks
    # Check Cinebench R20 executable presence
    If (-Not (Test-Path -Path $ExePath -PathType Leaf)) {
        Write-Error -Category ObjectNotFound -Message "Cinebench R20 executable ""$ExePath"" not found"
        Exit 1
    }

    # Check Cinebench R20 preferences file presence
    If (Test-Path -Path $PrefsFileSearch -PathType Leaf) {
        $PrefsFile = (Get-ChildItem $PrefsFileSearch).FullName
    }
    Else {
        $ErrorMessage = "Cinebench R20 preferences file ""$PrefsFileSearch"" not found, please run " +
        "Cinebench R20 at least once and retry"
        Write-Error -Category ObjectNotFound -Message $ErrorMessage
        Exit 2
    }

    # More initializations
    $CustomThreadsEnabledOffset = 0x1B2
    $CustomThreadsOffset = 0x1A3
    $Results = (1..$Threads.Count)

    # Backup initial Cinebench R20 thread preferences to restore at the end of the script
    [Byte[]] $Prefs = Get-Content $PrefsFile -Encoding Byte -ReadCount 0
    $CustomThreadsEnabled = $Prefs[$CustomThreadsEnabledOffset]
    $CustomThreads = $Prefs[$CustomThreadsOffset]
    $Prefs[$CustomThreadsEnabledOffset] = 0x1

    # It's better to run the high-thread sets earlier, especially on liquid-cooled CPUs where even relatively long
    # cooldown delays are not enough to completely cool down the radiator(s) and the water in the loop. Leaving
    # the low-thread count runs near the end makes sense since they are not as thermally constrained
    $Threads = $Threads | Sort-Object -Descending
    $ThreadCounter = -1
}

PROCESS {
    Function Wait-Period {
        Param(
            [Parameter(
            Mandatory = $true,
            ValueFromPipeline = $false,
            ValueFromPipelineByPropertyName = $false,
            Position = 0
            )]
            [Int] $Period
        )
    
        for ($i = $Period; $i -gt 0; $i--) {
            Write-Progress -Activity "Waiting for $Period seconds" -Status "$i seconds remaining"
            Start-Sleep -Seconds 1
        }
    }

    If ($IdleWait -gt 0 -And $IdleWait -gt $Cooldown) {
        Write-Host "$IdleWait seconds wait to ensure CPU and OS services are idling"
        Wait-Period $IdleWait
    }

    ForEach ($ThreadNumber In $Threads) {
        $ThreadCounter++
        $Prefs[$CustomThreadsOffset] = $ThreadNumber
        Set-Content -Path $PrefsFile -Encoding Byte -Value $Prefs
        $SumOfDiffsSquared = 0.0

        $Results[$ThreadCounter] = [ordered]@{
            Threads = $ThreadNumber
            Scores = [Double[]](1..$Runs)
            Average = 0.0
            Minimum = 0.0
            Maximum = 0.0
            StDev   = 0.0
            StDevP  = ""
        }

        For ($Run = 1; $Run -le $Runs; $Run++) {
            If ($Cooldown -gt 0) {
                If ($Run -gt 1 -Or ($Run -eq 1 -And $Cooldown -gt $IdleWait)) {
                Write-Host "$ThreadNumber thread(s) - Run $Run/$Runs - $Cooldown seconds cooldown"
                Wait-Period $Cooldown
                }
            }

            Write-Host "$ThreadNumber thread(s) - Run $Run/$Runs - Starting"
            $ExeOutput = & $ExePath g_CinebenchCpuXTest=true | Out-String

            If (-Not ($ExeOutput -Match "Values: {(?<Score>.*)}")) {
                Write-Error -Category ParserError -Message "Score not found in Cinebench R20 console output"
                Exit 3
            }

            $Results[$ThreadCounter].Scores[$Run - 1] = $Score = $Matches.Score
            Write-Host "$ThreadNumber thread(s) - Run $Run/$Runs - Completed - Score: $Score"
        }

        $Stats = ($Results[$ThreadCounter].Scores | Measure-Object -Minimum -Maximum -Average)
        $Results[$ThreadCounter].Minimum = $Stats.Minimum
        $Results[$ThreadCounter].Maximum = $Stats.Maximum
        $Results[$ThreadCounter].Average = $Stats.Average

        ForEach($Score In $Results[$ThreadCounter].Scores) {
            $SumOfDiffsSquared += [Math]::Pow(($Score - $Stats.Average), 2)
        }

        $Count = $Stats.Count
        $Results[$ThreadCounter].StDev = [Math]::Sqrt($SumOfDiffsSquared / $Count)
        $Results[$ThreadCounter].StDevP = [String]((100 * $Results[$ThreadCounter].StDev) / $Stats.Average) + "%"
    }

    Write-Host "Results:"
    $Results | ConvertTo-JSON
}

END {
    # Restore initial Cinebench R20 thread preferences
    $Prefs[$CustomThreadsOffset] = $CustomThreads
    $Prefs[$CustomThreadsEnabledOffset] = $CustomThreadsEnabled
    Set-Content -Path $PrefsFile -Encoding Byte -Value $Prefs
}
