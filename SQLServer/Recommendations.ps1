# Parameters for remote connection
param(
    [Parameter(Mandatory=$true)]
    [string]$InputFile,
    
    [Parameter(Mandatory=$false)]
    [string]$SQLUsername,
    
    [Parameter(Mandatory=$false)]
    [string]$SQLPassword,

    [Parameter(Mandatory=$false)]
    [switch]$WindowsAuth = $false
)

# Function to test SQL Connection
function Test-SQLConnection {
    param (
        [string]$ServerName,
        [string]$Username,
        [string]$Password,
        [bool]$UseWindowsAuth
    )
    
    try {
        if ($UseWindowsAuth) {
            $connectionString = "Server=$ServerName;Integrated Security=SSPI;Connect Timeout=5;"
        } else {
            $connectionString = "Server=$ServerName;User ID=$Username;Password=$Password;Connect Timeout=5;"
        }
        $connection = New-Object System.Data.SqlClient.SqlConnection($connectionString)
        $connection.Open()
        $connection.Close()
        return $true
    }
    catch {
        Write-Host "Cannot connect to SQL Server $ServerName. Error: $_" -ForegroundColor Red
        return $false
    }
}

# Function to calculate recommended MAXDOP
function Get-RecommendedMaxDop {
    param (
        [int]$CPUCount,
        [int]$NumaNodes
    )
    
    # Single NUMA node scenarios
    if ($NumaNodes -eq 1) {
        if ($CPUCount -le 8) {
            return $CPUCount
        }
        else {
            return 8
        }
    }
    # Multiple NUMA node scenarios
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

# Function to get MaxDOP Information
function Get-MAXDOPInfo {
    param (
        [string]$ServerName,
        [string]$Username,
        [string]$Password
    )
    
    try {
        # Modified connection string to include port 1433 for RDS
        $connectionString = "Server=$ServerName,1433;User ID=$Username;Password=$Password;"
        $connection = New-Object System.Data.SqlClient.SqlConnection($connectionString)
        $connection.Open()

        # Query to get CPU and NUMA information
        $query = @"
        SELECT
            cpu_count,
            hyperthread_ratio,
            softnuma_configuration,
            softnuma_configuration_desc,
            socket_count,
            numa_node_count,
            (SELECT value_in_use FROM sys.configurations WHERE name = 'max degree of parallelism') as CurrentMAXDOP
        FROM 
            sys.dm_os_sys_info
"@

        $command = New-Object System.Data.SqlClient.SqlCommand($query, $connection)
        $reader = $command.ExecuteReader()
        
        if ($reader.Read()) {
            $cpuCount = $reader['cpu_count']
            $numaNodes = $reader['numa_node_count']
            $currentMaxDOP = $reader['CurrentMAXDOP']
            $recommendedMaxDOP = Get-RecommendedMaxDop -CPUCount $cpuCount -NumaNodes $numaNodes

            Write-Host "`nServer Configuration for $ServerName" -ForegroundColor Green
            Write-Host "----------------------------------------"
            Write-Host "CPU Count: $cpuCount"
            Write-Host "Hyperthread Ratio: $($reader['hyperthread_ratio'])"
            Write-Host "Socket Count: $($reader['socket_count'])"
            Write-Host "NUMA Node Count: $numaNodes"
            Write-Host "Soft-NUMA Configuration: $($reader['softnuma_configuration_desc'])"
            Write-Host "Current MAXDOP Setting: $currentMaxDOP"
            Write-Host "----------------------------------------"
            Write-Host "RECOMMENDATION:" -ForegroundColor Yellow
            Write-Host "Recommended MAXDOP Setting: $recommendedMaxDOP" -ForegroundColor Yellow
            
            if ($currentMaxDOP -ne $recommendedMaxDOP) {
                                Write-Host "`nRecommendation:" -ForegroundColor Red
                Write-Host "Modify the maxdop parameter in the parametergroup attached to this RDS Instance." -ForegroundColor Cyan
                Write-Host "Before modifying verify if there is a wait type of CXPACKET that is affecting your load." -ForegroundColor Yellow
                Write-Host "`nTo check CXPACKET waits, run this query:" -ForegroundColor Blue
                Write-Host @"
SELECT wait_type, wait_time_ms, wait_time_ms/1000.0 as wait_time_seconds
FROM sys.dm_os_wait_stats 
WHERE wait_type = 'CXPACKET'
ORDER BY wait_time_ms DESC;
"@
            }
            else {
                Write-Host "`nCurrent MAXDOP setting matches the recommendation." -ForegroundColor Green
            }
        }
        
        $reader.Close()
        $connection.Close()
    }
    catch {
        Write-Host "Error getting SQL Server information for $ServerName : $_" -ForegroundColor Red
    }
}


function Get-DatabaseFileInfo {
    param (
        [string]$ServerName,
        [string]$Username,
        [string]$Password
    )
    
    try {
        $connectionString = "Server=$ServerName,1433;User ID=$Username;Password=$Password;"
        $connection = New-Object System.Data.SqlClient.SqlConnection($connectionString)
        $connection.Open()

        $query = @"
        SELECT 
            DB_NAME(database_id) as DatabaseName,
            name as LogicalFileName,
            physical_name as PhysicalFileName,
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
            is_percent_growth as IsPercentGrowth
        FROM sys.master_files
        ORDER BY database_id, file_id;
"@

        $command = New-Object System.Data.SqlClient.SqlCommand($query, $connection)
        $reader = $command.ExecuteReader()
        
        Write-Host "`nDatabase File Information for $ServerName" -ForegroundColor Cyan
        Write-Host "==========================================="
        
        $currentDB = ""
        
        $format = "{0,-20} {1,-10} {2,-12} {3,-15} {4,-15}"
        
        while ($reader.Read()) {
            $dbName = $reader['DatabaseName']
            
            if ($dbName -ne $currentDB) {
                Write-Host "`nDatabase: $dbName" -ForegroundColor Green
                Write-Host "----------------------------------------"
                Write-Host ($format -f "File Name", "Type", "Size(MB)", "Growth", "Max Size")
                Write-Host "----------------------------------------"
                $currentDB = $dbName
            }
            
            Write-Host ($format -f 
                $reader['LogicalFileName'],
                $reader['FileType'],
                [math]::Round($reader['CurrentSizeMB'], 2),
                $reader['Growth'],
                $reader['MaxSize'])
            
            if ($reader['IsPercentGrowth']) {
                Write-Host "  Recommendation: Percentage growth setting detected!" -ForegroundColor Red
            }
            if ($reader['Growth'] -eq '0 MB') {
                Write-Host "  Recommendation: No growth allowed!" -ForegroundColor Red
            }
        }
        
        # Check for databases with different file sizes
        $reader.Close()
        $query2 = @"
        SELECT 
            DB_NAME(database_id) as DatabaseName,
            COUNT(DISTINCT size) as DistinctFileSizes
        FROM sys.master_files
        WHERE type_desc = 'ROWS'
        GROUP BY database_id
        HAVING COUNT(DISTINCT size) > 1;
"@

        $command.CommandText = $query2
        $reader = $command.ExecuteReader()
        
        Write-Host "`nRecommendation: Non-uniform file sizes detected" -ForegroundColor Red
        Write-Host "----------------------------------------"
        $hasUnevenFiles = $false
        
        while ($reader.Read()) {
            Write-Host "$($reader['DatabaseName'])" -ForegroundColor Yellow
            $hasUnevenFiles = $true
        }
        
        if (-not $hasUnevenFiles) {
            Write-Host "No databases found with uneven file sizes." -ForegroundColor Green
        }
        
        $reader.Close()
        $connection.Close()
    }
    catch {
        Write-Host "Error getting database file information for $ServerName : $_" -ForegroundColor Red
    }
}

    
# Main execution
try {
    # Load SQL Client Assembly
    Add-Type -AssemblyName System.Data

    # Verify input file exists
    if (-not (Test-Path $InputFile)) {
        throw "Input file not found: $InputFile"
    }
    
    # Read servers from file
    $servers = Get-Content $InputFile | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
    $totalServers = $servers.Count
    
    Write-Host "Found $totalServers servers in input file" -ForegroundColor Yellow
    
    # Process each server
    foreach ($server in $servers) {
        if (Test-SQLConnection -ServerName $server -Username $SQLUsername -Password $SQLPassword) {
            Get-MAXDOPInfo -ServerName $server -Username $SQLUsername -Password $SQLPassword
	    Get-DatabaseFileInfo -ServerName $server -Username $SQLUsername -Password $SQLPassword
        }
    }
}
catch {
    Write-Host "Error: $_" -ForegroundColor Red
}
