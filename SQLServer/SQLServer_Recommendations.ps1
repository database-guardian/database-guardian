# Parameters for remote connection
param(
    [Parameter(Mandatory=$true)]
    [string]$InputFile,
    
    [Parameter(Mandatory=$false)]
    [string]$SQLUsername,
    
    [Parameter(Mandatory=$false)]
    [string]$SQLPassword,

    [Parameter(Mandatory=$false)]
    [switch]$WindowsAuth
)

# Function to calculate recommended MAXDOP
function Get-RecommendedMaxDop {
    param (
        [int]$CPUCount,
        [int]$NumaNodes
    )
    
    if ($NumaNodes -eq 1) {
        if ($CPUCount -le 8) {
            return $CPUCount
        }
        else {
            return 8
        }
    }
    else {
        $LogicalProcessorsPerNuma = [math]::Ceiling($CPUCount / $NumaNodes)
        if ($LogicalProcessorsPerNuma -le 16) {
            return $LogicalProcessorsPerNuma
        }
        else {
            $halfProcessors = [math]::Floor($LogicalProcessorsPerNuma / 2)
            return [math]::Min($halfProcessors, 16)
        }
    }
}

# Function to analyze SQL Server

function Get-SQLServerAnalysis {
    param (
        [string]$ServerName,
        [string]$Username,
        [string]$Password,
        [bool]$UseWindowsAuth,
        [System.Text.StringBuilder]$output
    )
    
    $connection = $null
    
    try {
        # Create single connection for this server
        if ($UseWindowsAuth) {
            $connectionString = "Server=$ServerName;Integrated Security=SSPI;"
        } else {
            $connectionString = "Server=$ServerName;User ID=$Username;Password=$Password;"
        }
        
        $connection = New-Object System.Data.SqlClient.SqlConnection($connectionString)
        $connection.Open()
        Write-Host "Successfully connected to $ServerName" -ForegroundColor Green

        # Create single command object to be reused
        $command = New-Object System.Data.SqlClient.SqlCommand("", $connection)

        # MAXDOP Information using existing connection
        Write-Host "`nGathering Server Configuration Information..." -ForegroundColor Cyan
        $command.CommandText = @"
        SELECT
            cpu_count,
            hyperthread_ratio,
            softnuma_configuration_desc,
            socket_count,
            numa_node_count,
            (SELECT value_in_use FROM sys.configurations WHERE name = 'max degree of parallelism') as CurrentMAXDOP
        FROM sys.dm_os_sys_info
"@
        $reader = $command.ExecuteReader()
        
        if ($reader.Read()) {
            # Process MAXDOP info
            $cpuCount = $reader['cpu_count']
            $numaNodes = $reader['numa_node_count']
            $currentMaxDOP = $reader['CurrentMAXDOP']
            $recommendedMaxDOP = Get-RecommendedMaxDop -CPUCount $cpuCount -NumaNodes $numaNodes

            # Add MAXDOP info to output
            $maxDopLine = "{0},{1},{2},{3},{4},{5},{6},{7},{8}" -f `
                $ServerName,
                $cpuCount,
                $reader['hyperthread_ratio'],
                $reader['socket_count'],
                $numaNodes,
                $reader['softnuma_configuration_desc'],
                $currentMaxDOP,
                $recommendedMaxDOP,
                $(if ($currentMaxDOP -ne $recommendedMaxDOP) { 
                    "RECOMMENDATION: Modify MAXDOP to $recommendedMaxDOP" 
                } else { 
                    "No change needed" 
                })

            $output.AppendLine($maxDopLine) | Out-Null
        }
        $reader.Close()

        # Add spacing between sections
        $output.AppendLine("") | Out-Null
        $output.AppendLine("") | Out-Null
        $output.AppendLine("Database File Information") | Out-Null
        $output.AppendLine("Server Name,Database Name,File Name,File Type,Size (MB),Growth Setting,Max Size,Recommendation") | Out-Null

        # Database File Information using same connection and command object
        Write-Host "Gathering Database File Information..." -ForegroundColor Cyan
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
            CASE
                WHEN max_size = -1 THEN 'Unlimited'
                WHEN max_size = 268435456 AND type_desc = 'LOG' THEN '2 TB'
                WHEN max_size = 0 THEN 'No Growth'
                ELSE CAST(CAST(max_size * 8.0 / 1024 AS DECIMAL(18,2)) AS VARCHAR(20)) + ' MB'
            END as MaxSize,
            is_percent_growth as IsPercentGrowth,
            growth
        FROM sys.master_files
        ORDER BY database_id, file_id;
"@
        $reader = $command.ExecuteReader()
        
        while ($reader.Read()) {
            # Process database file info using same connection
            $recommendation = @()
            if ($reader['IsPercentGrowth']) {
                $recommendation += "RECOMMENDATION: Change from percentage growth to fixed size"
            }
            if ($reader['growth'] -eq 0) {
                $recommendation += "RECOMMENDATION: Configure growth settings - current setting allows no growth"
            }

            $fileLine = "{0},{1},{2},{3},{4},{5},{6},{7}" -f `
                $ServerName,
                $reader['DatabaseName'],
                $reader['LogicalFileName'],
                $reader['FileType'],
                [math]::Round($reader['CurrentSizeMB'], 2),
                $reader['Growth'],
                $reader['MaxSize'],
                $(if ($recommendation.Count -gt 0) { 
                    $recommendation -join "; " 
                } else { 
                    "Settings OK" 
                })

            $output.AppendLine($fileLine) | Out-Null
        }
        $reader.Close()
    }
    catch {
        Write-Host "Error analyzing SQL Server $ServerName : $_" -ForegroundColor Red
    }
    finally {
        # Always close the connection in finally block
        if ($connection -and $connection.State -eq 'Open') {
            $connection.Close()
            $connection.Dispose()
        }
    }
}

try {
    Write-Host "Analysis started at $(Get-Date)" -ForegroundColor Cyan

    # Load SQL Client Assembly
    Add-Type -AssemblyName System.Data

    # Verify input file exists
    if (-not (Test-Path $InputFile)) {
        throw "Input file not found: $InputFile"
    }
    
    # Create timestamp for the output file
    $timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
    $csvPath = "SQLServerAnalysis_$timestamp.csv"
    
    # Create StringBuilder for building CSV content
    $output = New-Object System.Text.StringBuilder
    
    # Add MAXDOP section header
    $output.AppendLine("MAXDOP Configuration") | Out-Null
    $output.AppendLine("Server Name,CPU Count,Hyperthread Ratio,Socket Count,NUMA Node Count,Soft-NUMA Configuration,Current MAXDOP,Recommended MAXDOP,MAXDOP Recommendation") | Out-Null

    # Read servers from file
    $servers = Get-Content $InputFile | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
    $totalServers = $servers.Count
    
    Write-Host "Found $totalServers servers in input file" -ForegroundColor Yellow
    
    # Create arrays to store results
    $maxDopResults = New-Object System.Collections.ArrayList
    $dbFileResults = New-Object System.Collections.ArrayList
    
    # Process each server
    foreach ($server in $servers) {
        Write-Host "`n============================================="
        Write-Host "Processing Server: $server"
        Write-Host "============================================="
        
        try {
            $connectionString = if ($WindowsAuth) {
                "Server=$server;Integrated Security=SSPI;"
            } else {
                "Server=$server;User ID=$SQLUsername;Password=$SQLPassword;"
            }
            
            $connection = New-Object System.Data.SqlClient.SqlConnection($connectionString)
            $connection.Open()
            Write-Host "Successfully connected to $server" -ForegroundColor Green

            # Get MAXDOP Information
            Write-Host "`nGathering Server Configuration Information..." -ForegroundColor Cyan
            $maxDopQuery = @"
            SELECT
                cpu_count,
                hyperthread_ratio,
                softnuma_configuration_desc,
                socket_count,
                numa_node_count,
                (SELECT value_in_use FROM sys.configurations WHERE name = 'max degree of parallelism') as CurrentMAXDOP
            FROM sys.dm_os_sys_info
"@
            $command = New-Object System.Data.SqlClient.SqlCommand($maxDopQuery, $connection)
            $reader = $command.ExecuteReader()

            if ($reader.Read()) {
                $cpuCount = $reader['cpu_count']
                $numaNodes = $reader['numa_node_count']
                $currentMaxDOP = $reader['CurrentMAXDOP']
                $recommendedMaxDOP = Get-RecommendedMaxDop -CPUCount $cpuCount -NumaNodes $numaNodes

                # Add MAXDOP info to CSV
                $maxDopLine = "{0},{1},{2},{3},{4},{5},{6},{7},{8}" -f `
                    $server,
                    $cpuCount,
                    $reader['hyperthread_ratio'],
                    $reader['socket_count'],
                    $numaNodes,
                    $reader['softnuma_configuration_desc'],
                    $currentMaxDOP,
                    $recommendedMaxDOP,
                    $(if ($currentMaxDOP -ne $recommendedMaxDOP) { "RECOMMENDATION: Modify MAXDOP to $recommendedMaxDOP" } else { "No change needed" })

                $output.AppendLine($maxDopLine) | Out-Null
            }
            $reader.Close()

            # Add spacing between sections
            $output.AppendLine("") | Out-Null
            $output.AppendLine("") | Out-Null
        # Memory Configuration Information
        Write-Host "Gathering Memory Configuration Information..." -ForegroundColor Cyan
        $command.CommandText = @"
        SELECT
            sql_memory_model_desc,
            physical_memory_kb/1024.0/1024.0 as physical_memory_gb,
            committed_target_kb/1024.0/1024.0 as committed_target_gb
        FROM sys.dm_os_sys_info
"@
        $reader = $command.ExecuteReader()

        # Add Memory section header
        $output.AppendLine("Memory Configuration") | Out-Null
        $output.AppendLine("Server Name,Memory Model,Physical Memory (GB),Target Memory (GB),Recommendation") | Out-Null

        if ($reader.Read()) {
            $memoryLine = "{0},{1},{2:N2},{3:N2},{4}" -f `
                $server,
                $reader['sql_memory_model_desc'],
                $reader['physical_memory_gb'],
                $reader['committed_target_gb'],
                $(if ($reader['sql_memory_model_desc'] -ne 'LOCK_PAGES') {
                    "RECOMMENDATION: Enable Lock Pages in Memory to prevent SQL Server buffer pool from being paged out"
                } else {
                    "Lock Pages in Memory is properly configured"
                })

            $output.AppendLine($memoryLine) | Out-Null
        }
        $reader.Close()

        # Add spacing between Memory and Database File sections
        $output.AppendLine("") | Out-Null
        $output.AppendLine("") | Out-Null

            # Add Database Files section header
            $output.AppendLine("Database File Information") | Out-Null
            $output.AppendLine("Server Name,Database Name,File Name,File Type,Size (MB),Growth Setting,Max Size,Recommendation") | Out-Null
	   
            # Get Database File Information
            Write-Host "Gathering Database File Information..." -ForegroundColor Cyan
            $fileQuery = @"
            SELECT 
                DB_NAME(database_id) as DatabaseName,
                name as LogicalFileName,
                type_desc as FileType,
                size/128.0 as CurrentSizeMB,
                CASE 
                    WHEN is_percent_growth = 1 THEN CAST(growth AS VARCHAR(10)) + '%'
                    ELSE CAST(growth/128.0 AS VARCHAR(10)) + ' MB'
                END as Growth,
                CASE
                    WHEN max_size = -1 THEN 'Unlimited'
                    WHEN max_size = 268435456 AND type_desc = 'LOG' THEN '2 TB'
                    WHEN max_size = 0 THEN 'No Growth'
                    ELSE CAST(CAST(max_size * 8.0 / 1024 AS DECIMAL(18,2)) AS VARCHAR(20)) + ' MB'
                END as MaxSize,
                is_percent_growth as IsPercentGrowth,
                growth
            FROM sys.master_files
            ORDER BY database_id, file_id;
"@
            $command.CommandText = $fileQuery
            $reader = $command.ExecuteReader()

            while ($reader.Read()) {
                $recommendation = @()
                if ($reader['IsPercentGrowth']) {
                    $recommendation += "RECOMMENDATION: Change from percentage growth to fixed size"
                }
                if ($reader['growth'] -eq 0) {
                    $recommendation += "RECOMMENDATION: Configure growth settings - current setting allows no growth"
                }

                # Add database file info to CSV
                $fileLine = "{0},{1},{2},{3},{4},{5},{6},{7}" -f `
                    $server,
                    $reader['DatabaseName'],
                    $reader['LogicalFileName'],
                    $reader['FileType'],
                    [math]::Round($reader['CurrentSizeMB'], 2),
                    $reader['Growth'],
                    $reader['MaxSize'],
                    $(if ($recommendation.Count -gt 0) { $recommendation -join "; " } else { "Settings OK" })

                $output.AppendLine($fileLine) | Out-Null
            }
            $reader.Close()
            $connection.Close()

        }
        catch {
            Write-Host "Error processing server $server : $_" -ForegroundColor Red
        }
    }
    
    # Write all content to file
    $output.ToString() | Out-File $csvPath -Encoding UTF8
    
    Write-Host "`nAnalysis completed at $(Get-Date)" -ForegroundColor Cyan
    Write-Host "Results have been saved to: $csvPath" -ForegroundColor Green
}
catch {
    Write-Host "Error: $_" -ForegroundColor Red
}
