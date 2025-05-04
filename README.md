# database-guardian

## SQLServer Module

This tool provides automated analysis and recommendations for SQL Server configurations of **multiple servers** and providing the output in a user-friendly way, helping maintain optimal performance and security.

### Prerequisites
- PowerShell 5.1 or higher
- SQL Server authentication credentials
- Network access to target SQL Servers
- Required ports open (default: 1433)


### Current Limitations
- Works on Windows SQLServers

### Usage Steps

1. Download Installation Files
   - Obtain `SQLServer_Recommendations.ps1` from `/SQLServer` folder
   - Place in desired location on your management server

2. Configure Server List
   - Create `servers.txt` in the same directory as the script
   - Add target server names (one per line)
   - Create a folder with name Output

Example servers.txt:
```
sqlserver01.domain.com
sqlserver02.domain.com
```
3. Network Requirements
   - Ensure management server can reach all SQL Server instances
   - Verify SQL Server port is open (1433 is default, require 1434 for 
   - Check firewall rules if necessary

4. SQLServer login requirements
  
   - View Server State permission
   - View Any Definition permission

Example SQL Commands to Grant Permissions for a SQL login:
```
-- Grant required permissions
GRANT VIEW SERVER STATE TO [monitoring_user]
GRANT VIEW ANY DEFINITION TO [monitoring_user]
```
5. Execute Analysis
   - Open PowerShell as Administrator
   - Navigate to script directory
   - Run the following command:
For SQL login

```
$cred = Get-Credential
.\SQLServer_Recommendations.ps1 -InputFile "servers.txt" -SQLCredential $cred
```
For Windows login

```
.\SQLServer_Recommendations.ps1 -InputFile    "servers.txt" -WindowsAuth
```

6. Output Folder will contain 2 files ServerRecommendations and DetailedAnalysis. Attached the Sample Outputs.

Need help? Contact [email](kedaryarlapati@gmail.com)
