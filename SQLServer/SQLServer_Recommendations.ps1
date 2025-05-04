param(
    [Parameter(Mandatory=$true)][string]$InputFile,
    [Parameter(ParameterSetName='SQLAuth')][PSCredential]$SQLCredential,
    [Parameter(ParameterSetName='WindowsAuth')][switch]$WindowsAuth,
    [string]$OutputPath = ".\Output",
    [string]$LogPath = ".\Logs"
)

function Write-Log {
    param(
        [string]$Message,
        [ValidateSet('Info', 'Warning', 'Error', 'Success')][string]$Level = 'Info',
        [System.ConsoleColor]$ForegroundColor = 'White'
    )
    
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $logMessage = "[$timestamp] [$Level] $Message"
    Write-Host $logMessage -ForegroundColor $ForegroundColor
    
    if (-not (Test-Path $LogPath)) { New-Item -ItemType Directory -Path $LogPath -Force | Out-Null }
    Add-Content -Path "$(Join-Path $LogPath 'Analysis.log')" -Value $logMessage
}

function Get-RecommendedMaxDop {
    param ([int]$CPUCount, [int]$NumaNodes)
    
    if ($NumaNodes -eq 1) {
        return [Math]::Min($CPUCount, 8)
    }
    else {
        $LogicalProcessorsPerNuma = [math]::Ceiling($CPUCount / $NumaNodes)
        return [math]::Min([math]::Min($LogicalProcessorsPerNuma, 16), [math]::Floor($LogicalProcessorsPerNuma / 2))
    }
}

try {
    Add-Type -AssemblyName System.Data
    if (-not (Test-Path $InputFile)) { throw "Input file not found: $InputFile" }
    if (-not (Test-Path $OutputPath)) { New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null }
    
    $timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
    $recommendationPath = Join-Path $OutputPath "ServerRecommendations_$timestamp.csv"
    $detailedPath = Join-Path $OutputPath "DetailedAnalysis_$timestamp.csv"
    
    $recommendations = New-Object System.Text.StringBuilder
    $detailed = New-Object System.Text.StringBuilder
    
    $recommendations.AppendLine("Server Name,Setting,Current Value,Recommended Value,Recommendation") | Out-Null
    $detailed.AppendLine("Server Configuration Details") | Out-Null

    $servers = Get-Content $InputFile | Where-Object { $_ -match '\S' }
    Write-Log "Found $($servers.Count) servers to analyze" -Level Info -ForegroundColor Yellow

    foreach ($server in $servers) {
        Write-Log "Processing: $server" -Level Info
        
        try {
            $connectionString = if ($WindowsAuth) {
                "Server=$server;Integrated Security=SSPI;ApplicationIntent=ReadOnly;"
            } else {
                "Server=$server;User ID=$($SQLCredential.UserName);Password=$($SQLCredential.GetNetworkCredential().Password);ApplicationIntent=ReadOnly;"
            }
            
            $connection = New-Object System.Data.SqlClient.SqlConnection($connectionString)
            $connection.Open()
            $command = New-Object System.Data.SqlClient.SqlCommand("", $connection)

            # Gather all configuration settings
            $command.CommandText = @"
WITH SystemInfo AS (
    SELECT 
        cpu_count,
        hyperthread_ratio,
        softnuma_configuration_desc,
        socket_count,
        numa_node_count,
        physical_memory_kb/1024.0/1024.0 as total_memory_gb,
        committed_target_kb/1024.0/1024.0 as committed_target_gb,
        sql_memory_model_desc
    FROM sys.dm_os_sys_info
),
TempDBInfo AS (
    SELECT 
        COUNT(CASE WHEN type_desc = 'ROWS' THEN 1 END) as data_files,
        COUNT(DISTINCT CASE WHEN type_desc = 'ROWS' THEN size END) as distinct_sizes,
        COUNT(CASE WHEN is_percent_growth = 1 THEN 1 END) as percent_growth_files
    FROM sys.master_files 
    WHERE database_id = 2
)
SELECT
    s.*,
    t.*,
    (SELECT value_in_use FROM sys.configurations WHERE name = 'cost threshold for parallelism') as cost_threshold,
    (SELECT value_in_use FROM sys.configurations WHERE name = 'max degree of parallelism') as maxdop,
    (SELECT value_in_use FROM sys.configurations WHERE name = 'min server memory (MB)') as min_memory_mb,
    (SELECT value_in_use FROM sys.configurations WHERE name = 'max server memory (MB)') as max_memory_mb,
    (SELECT value_in_use FROM sys.configurations WHERE name = 'backup compression default') as backup_compression,
    (SELECT instant_file_initialization_enabled FROM sys.dm_server_services WHERE filename LIKE '%sqlservr.exe%') as ifi_enabled
FROM SystemInfo s
CROSS JOIN TempDBInfo t
"@
            $reader = $command.ExecuteReader()

            if ($reader.Read()) {
                # Add to detailed analysis
                $detailed.AppendLine("`nServer: $server") | Out-Null
                $detailed.AppendLine("CPU Count: $($reader['cpu_count'])") | Out-Null
                $detailed.AppendLine("NUMA Nodes: $($reader['numa_node_count'])") | Out-Null
                $detailed.AppendLine("Memory Model: $($reader['sql_memory_model_desc'])") | Out-Null
                $detailed.AppendLine("Physical Memory: $([math]::Round($reader['total_memory_gb'], 2)) GB") | Out-Null
                $detailed.AppendLine("Committed Memory: $([math]::Round($reader['committed_target_gb'], 2)) GB") | Out-Null

                # MAXDOP Check
                $recommendedMaxDOP = Get-RecommendedMaxDop -CPUCount $reader['cpu_count'] -NumaNodes $reader['numa_node_count']
                if ($reader['maxdop'] -ne $recommendedMaxDOP) {
                    $recommendations.AppendLine("$server,MAXDOP,$($reader['maxdop']),$recommendedMaxDOP,Change MAXDOP setting to $recommendedMaxDOP") | Out-Null
                }

                # Memory Model Check
                if ($reader['sql_memory_model_desc'] -ne 'LOCK_PAGES') {
                    $recommendations.AppendLine("$server,Memory Settings,$($reader['sql_memory_model_desc']),LOCK_PAGES,Enable Lock Pages in Memory") | Out-Null
                }

                # Cost Threshold Check
                if ($reader['cost_threshold'] -lt 25) {
                    $recommendations.AppendLine("$server,Cost Threshold,$($reader['cost_threshold']),25,Increase Cost Threshold for Parallelism to at least 25") | Out-Null
                }

                # TempDB Configuration
                $recommendedFiles = [Math]::Min($reader['cpu_count'], 8)
                if ($reader['data_files'] -ne $recommendedFiles -or 
                    $reader['distinct_sizes'] -gt 1 -or 
                    $reader['percent_growth_files'] -gt 0) {
                    $tempdbIssues = @()
                    if ($reader['data_files'] -ne $recommendedFiles) { 
                        $tempdbIssues += "Adjust number of files to $recommendedFiles" 
                    }
                    if ($reader['distinct_sizes'] -gt 1) { 
                        $tempdbIssues += "Equalize file sizes" 
                    }
                    if ($reader['percent_growth_files'] -gt 0) { 
                        $tempdbIssues += "Change growth to fixed size instead of percentage" 
                    }
                    $recommendations.AppendLine("$server,TempDB DataFile Configuration,$($reader['data_files']),$recommendedFiles,$($tempdbIssues -join ' | ')") | Out-Null
                }

                # Max Server Memory
                $totalMemoryGB = $reader['total_memory_gb']
                $maxMemoryMB = $reader['max_memory_mb']
                $recommendedMaxMemoryGB = [Math]::Max($totalMemoryGB - 4, $totalMemoryGB * 0.9)
                if ($maxMemoryMB -eq 2147483647 -or $maxMemoryMB/1024 -gt $recommendedMaxMemoryGB) {
                    $recommendations.AppendLine("$server,Max Memory,$($maxMemoryMB/1024) GB,$recommendedMaxMemoryGB GB,Adjust max server memory") | Out-Null
                }

                # Backup Compression
                if (-not $reader['backup_compression']) {
                    $recommendations.AppendLine("$server,Backup Compression,Disabled,Enabled,Enable backup compression default") | Out-Null
                }

                # Instant File Initialization
                if ($reader['ifi_enabled'] -eq 'N') {
                    $recommendations.AppendLine("$server,Instant File Initialization,Disabled,Enabled,Enable Instant File Initialization") | Out-Null
                }
            }
            $reader.Close()

            # Get Database File Information
            $command.CommandText = @"
SELECT 
    DB_NAME(database_id) as DatabaseName,
    name as LogicalFileName,
    type_desc as FileType,
    size/128.0 as CurrentSizeMB,
    CASE 
        WHEN is_percent_growth = 1 THEN CAST(growth AS VARCHAR(10)) + '%'
        ELSE CAST(growth/128.0 AS VARCHAR(10)) + ' MB'
    END as Growth,
    is_percent_growth,
    growth
FROM sys.master_files
ORDER BY database_id, file_id
"@
            $reader = $command.ExecuteReader()

            $detailed.AppendLine("`nDatabase Files:") | Out-Null
            while ($reader.Read()) {
                $detailed.AppendLine("$($reader['DatabaseName']),$($reader['LogicalFileName']),$($reader['FileType']),$($reader['CurrentSizeMB']) MB,$($reader['Growth'])") | Out-Null
                
                if ($reader['is_percent_growth']) {
                    $recommendations.AppendLine("$server,Database File Growth,$($reader['DatabaseName']) - $($reader['LogicalFileName']),Fixed MB,Change from percentage ($($reader['Growth'])) to fixed size growth") | Out-Null
                }
                if ($reader['growth'] -eq 0) {
                    $recommendations.AppendLine("$server,Database File Growth,$($reader['DatabaseName']) - $($reader['LogicalFileName']),Enable Growth,Configure growth settings - currently set to no growth") | Out-Null
                }
            }
            $reader.Close()
            $connection.Close()
        }
        catch {
            Write-Log "Error processing $server : $_" -Level Error -ForegroundColor Red
            $recommendations.AppendLine("$server,Connection Error,N/A,N/A,$_") | Out-Null
        }
    }
    
    $recommendations.ToString() | Out-File $recommendationPath -Encoding UTF8
    $detailed.ToString() | Out-File $detailedPath -Encoding UTF8
    
    Write-Log "Analysis completed." -Level Success -ForegroundColor Green
    Write-Log "Recommendations saved to: $recommendationPath" -Level Success -ForegroundColor Green
    Write-Log "Detailed analysis saved to: $detailedPath" -Level Success -ForegroundColor Green
}
catch {
    Write-Log "Error: $_" -Level Error -ForegroundColor Red
}
