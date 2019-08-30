# azuredevops
Useful scripts and apps to use with Azure DevOps

## PowerShell

New-TestBatchesFromStatistics.ps1 -BuildDefinition *\<int\>* -Organization *\<string\>* -Project *\<string\>* \[-OutputPath *\<path\>*\] \[-PersonalAccessToken *\<string\>*\] \[-BatchSize \<*int*\>]

Fetches test statistics from the previous successful build and creates a JSON output file that can be used to split tests evenly among *BatchSize* test phases (exercise left to the user).

Demonstrates REST access to the Azure DevOps API using PowerShell. Authentication is by default using the $env:SYSTEM_ACCESSTOKEN method, or via PAT specified as a parameter to the script.

Parameters:
BuildDefinition - The id of the build definition that will be examined by the script.
Organization - The name of your organization, e.g. "Microsoft"
Project - Your project name in Azure DevOps
OutputPath - The path to where the script will save the JSON. By default, this is $PSScriptRoot\TestStatistics.json
PersonalAccessToken - Optional PAT used to authenticate to Azure DevOps API
BatchSize - The number of batches to split the test cases into. Default is 3.
