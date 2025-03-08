# database-guardian

You can run this script by following below steps

1. Download the file SQLServer_Recommendations.ps1 from SQLServer Folder
2. Copy it to desired folder on a Test Server which can access all the other SQLServers (Open the required SQLServer ports if there is a firewall in-between)
3. Create a text file servers.txt in the same folder
4. Add the required server details to servers.txt
5. Run the script using PowerShell as an administrator
   
Eg: .\SQLServer_Recommendations.ps1 -InputFile "servers.txt" -SQLUsername "user" -SQLPassword "password"
