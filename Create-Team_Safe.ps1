################################### GET-HELP #############################################
<#
.SYNOPSIS
 	This script will create a new safe based on input from the user or a .csv file.
 
.EXAMPLE
 	.\Create-Team_Safe.ps1 -bulk $false
	.\Create-Team_Safe.ps1 -bulk $true -csvPath "C:\temp\onboard.csv"
 
.INPUTS  
	-bulk $true/$false
	-csvPath <Path to .csv containing users to create safes for>
	
.OUTPUTS
	None
	
.NOTES
	AUTHOR:  
	Randy Brown

	VERSION HISTORY:
	1.0 04/10/2019 - Initial release
	1.1 04/17/2019 - Bug fixes and workflow improvements
#>
##########################################################################################

param (
	[bool]$bulk = $false,
	[string]$csvPath
)

######################## IMPORT MODULES/ASSEMBLY LOADING #################################



######################### GLOBAL VARIABLE DECLARATIONS ###################################

$baseURL = "https://components.cyberarkdemo.com"
$PVWAURI = "PasswordVault"

$ldapDIR = "ActiveDirectory"
$adminGroup = "Vault Admins"

$cpmUser = "PasswordManager"
$versionRetention = 5

### CCP Account Info ###
$appID = ""
$safe = ""
$object = ""

$finalURL = $baseURL + "/" + $PVWAURI

########################## START FUNCTIONS ###############################################

Function EPVLogin($user, $pass) {
	$data = @{
		username=$user
		password=$pass
		useRadiusAuthentication=$false
	}

	$loginData = $data | ConvertTo-Json

	Try {
		Write-Host "Logging into EPV as $user..." -NoNewLine
		
		$ret = Invoke-RestMethod -Uri "$finalURL/WebServices/auth/Cyberark/CyberArkAuthenticationService.svc/Logon" -Method Post -Body $loginData -ContentType 'application/json'		
		
		Write-Host "Success!" -ForegroundColor Green
	} Catch {
		ErrorHandler "Login was not Successful" $_.Exception.Message $_ $false
	}
	return $ret
}

Function EPVLogoff {
	Try {
		Write-Host "Logging off..." -NoNewline		
		
		Invoke-RestMethod -Uri "$finalURL/WebServices/auth/Cyberark/CyberArkAuthenticationService.svc/Logoff" -Method POST -Headers $header -ContentType 'application/json' | Out-Null
		
		Write-Host "Logged off!" -ForegroundColor Green
	} Catch {
		ErrorHandler "Log off was not Success!ful" $_.Exception.Message $_ $false
	}
}

Function Get-APIAccount {
	Write-Host "Getting API account from the Vault..."
	
	$ret = Invoke-RestMethod -Uri "$baseURI/AIMWebService/api/Accounts?AppID=$appID&Safe=$safe&Object=$object" -Method GET -ContentType 'application/json'
	
	return $ret
}

Function New-Safe($safeName, $description) {
	$safeExists = $false
	
	$existingSafes = Invoke-RestMethod -Uri "$finalURL/WebServices/PIMServices.svc/Safes?query=$safeName" -Method Get -Headers $header -ContentType 'application/json'
	
	ForEach ($sName in $existingSafes.SearchSafesResult.SafeName) {
		If ($sName.ToLower() -eq $safeName.ToLower()) {
			$safeExists = $true
		}
	}
	
	If (!($safeExists)) {		
		$data = @{
			safe = @{
				SafeName=$safeName
				Description=$description
				OLACEnabled=$false
				ManagingCPM=$cpmUser
				NumberOfVersionsRetention=$versionRetention
			}
		}		
		$data = $data | ConvertTo-Json
		
		Try {
			Write-Host "Safe $safeName does not exist creating it..." -NoNewline
			$ret = Invoke-RestMethod -Uri "$finalURL/WebServices/PIMServices.svc/Safes" -Method Post -Body $data -Headers $header -ContentType 'application/json'
		
			If ($ret) {
				Write-Host "Success!" -ForegroundColor Green
			} Else {
				Write-Host "Safe $safeName was not created" -ForegroundColor Red
			}
		} Catch {
			ErrorHandler "Something went wrong, $safeName was not created" $_.Exception.Message $_ $true
		}
	} Else {
		Write-Host "Safe $safeName exists skipping creation" -ForegroundColor Yellow
	}
}

Function Add-SafeMember($safeToCreate, $owner, $permsType, $ldapDIR, $existingUser) {
	$userExists = $false
	
	Write-Host "Parsing safe members..." -NoNewline
	ForEach ($user in $existingUser.members.UserName) {
		If ($user.ToLower() -like $owner.ToLower()) {
			$userExists = $true
			break
		}
	}

	If (!($userExists)) {
		Write-Host "Done!" -ForegroundColor Green
		$body = (Get-SafePermissions $owner $permsType $ldapDIR)
		
		Try {
			Write-Host "Adding $owner as member of $safeToCreate..." -NoNewline
			
			Invoke-RestMethod -Uri "$finalURL/WebServices/PIMServices.svc/Safes/$safeToCreate/Members" -Method Post -Body $body -Headers $header -ContentType 'application/json' | Out-Null
			
			Write-Host "Success!" -ForegroundColor Green
		} Catch {			
			ErrorHandler "Something went wrong, $owner was not added as a member of $safeToCreate..." $_.Exception.Message $_ $true
		}
	} Else {
		Write-Host "User $owner is already a member..." -ForegroundColor Yellow
	}
}

Function Get-SafeMembers {
	Try {
		Write-Host "Getting members of $safeToCreate..." -NoNewline
		$existingUser = Invoke-RestMethod -Uri "$finalURL/WebServices/PIMServices.svc/Safes/$safeToCreate/Members" -Method Get -Headers $header -ContentType 'application/json'
		Write-Host "Success!" -ForegroundColor Green
		return $existingUser
	} Catch {
		ErrorHandler "Something went wrong, unable to get memebrs of $safe..." $_.Exception.Message $_ $true
	}
}

Function Remove-SafeMemeber($safe, $safeMember, $existingUser) {
	$userExists = $false
	
	Write-Host "Parsing safe members..." -NoNewline
	ForEach ($user in $existingUser.members.UserName) {
		If ($user.ToLower() -like $safeMember.ToLower()) {
			$userExists = $true
			break
		}			
	}

	If (!($safeMember -eq $safe) -and $userExists) {
		Try {
			Write-Host "Done!" -ForegroundColor Green
			Write-Host "Removing $safeMember from $safe..." -NoNewline
			
			Invoke-RestMethod -Uri "$finalURL/WebServices/PIMServices.svc/Safes/$safe/Members/$safeMember" -Method Delete -ContentType 'application/json' -Headers $header | Out-Null
			
			Write-Host "Success!" -ForegroundColor Green
		} Catch {
			ErrorHandler "Something went wrong, $safeMember was not removed from $safe." $_.Exception.Message $_ $true
		}
	} Else {
		Write-Host "$safeMember not a member of $safe" -ForegroundColor Yellow
	}
}

Function Get-SafePermissions($owner, $type, $DIR) {
	Switch ($type.ToLower()) {
		"all" { $PERMISSIONS = @{
				member = @{
					MemberName="$owner"
					SearchIn="$DIR"
					MembershipExpirationDate=""
					Permissions = @(
						@{Key="UseAccounts"
						Value=$true}
						@{Key="RetrieveAccounts"
						Value=$true}
						@{Key="ListAccounts"
						Value=$true}
						@{Key="AddAccounts"
						Value=$true}
						@{Key="UpdateAccountContent"
						Value=$true}
						@{Key="UpdateAccountProperties"
						Value=$true}
						@{Key="InitiateCPMAccountManagementOperations"
						Value=$true}
						@{Key="SpecifyNextAccountContent"
						Value=$true}
						@{Key="RenameAccounts"
						Value=$true}
						@{Key="DeleteAccounts"
						Value=$true}
						@{Key="UnlockAccounts"
						Value=$true}
						@{Key="ManageSafe"
						Value=$false}
						@{Key="ManageSafeMembers"
						Value=$false}
						@{Key="BackupSafe"
						Value=$true}
						@{Key="ViewAuditLog"
						Value=$true}
						@{Key="ViewSafeMembers"
						Value=$true}
						@{Key="RequestsAuthorizationLevel"
						Value=0}
						@{Key="AccessWithoutConfirmation"
						Value=$false}
						@{Key="CreateFolders"
						Value=$true}
						@{Key="DeleteFolders"
						Value=$true}
						@{Key="MoveAccountsAndFolders"
						Value=$true}
					)
				}
			}
			$PERMISSIONS = $PERMISSIONS | ConvertTo-Json -Depth 3
			return $PERMISSIONS; break }
		"admin" { $PERMISSIONS = @{
				member = @{
					MemberName="$owner"
					SearchIn="$DIR"
					MembershipExpirationDate=""
					Permissions = @(
						@{Key="UseAccounts"
						Value=$false}
						@{Key="RetrieveAccounts"
						Value=$false}
						@{Key="ListAccounts"
						Value=$true}
						@{Key="AddAccounts"
						Value=$true}
						@{Key="UpdateAccountContent"
						Value=$false}
						@{Key="UpdateAccountProperties"
						Value=$true}
						@{Key="InitiateCPMAccountManagementOperations"
						Value=$true}
						@{Key="SpecifyNextAccountContent"
						Value=$false}
						@{Key="RenameAccounts"
						Value=$false}
						@{Key="DeleteAccounts"
						Value=$true}
						@{Key="UnlockAccounts"
						Value=$true}
						@{Key="ManageSafe"
						Value=$true}
						@{Key="ManageSafeMembers"
						Value=$true}
						@{Key="BackupSafe"
						Value=$true}
						@{Key="ViewAuditLog"
						Value=$true}
						@{Key="ViewSafeMembers"
						Value=$true}
						@{Key="RequestsAuthorizationLevel"
						Value=0}
						@{Key="AccessWithoutConfirmation"
						Value=$false}
						@{Key="CreateFolders"
						Value=$true}
						@{Key="DeleteFolders"
						Value=$true}
						@{Key="MoveAccountsAndFolders"
						Value=$true}
					)
				}
			}
			$PERMISSIONS = $PERMISSIONS | ConvertTo-Json -Depth 3
			return $PERMISSIONS; break }
	}
}

Function ErrorHandler($message, $exceptionMessage, $fullMessage, $logoff) {
	Write-Host $message -ForegroundColor Red
	Write-Host "Exception Message:"
	Write-Host $exceptionMessage -ForegroundColor Red
	Write-Host "Full Error Message:"
	Write-Host $fullMessage -ForegroundColor Red
	Write-Host "Stopping script" -ForegroundColor Yellow
	
	If ($logoff) {
		EPVLogoff
	}
	Exit 1
}

Function MAIN($safeToCreate, $safeDescription, $safeOwner, $user, $ldapDIR) {
	Write-Host "---------- Creating $safeToCreate Team Safe ----------"
	
	New-Safe $safeToCreate $safeDescription

	$existingUsers = Get-SafeMembers $safeToCreate

	Add-SafeMember $safeToCreate $safeOwner "all" $ldapDIR $existingUsers
	
	Add-SafeMember $safeToCreate $adminGroup "admin" $ldapDIR $existingUsers
	
	Remove-SafeMemeber $safeToCreate $user $existingUsers
	
	Write-Host "---------- Complete ----------" 
}

########################## END FUNCTIONS #################################################

########################## MAIN SCRIPT BLOCK #############################################

### Uncomment if using CCP ###
<#
$cred = Get-APIAccount
$user = $cred.UserName
$login = EPVLogin $cred.UserName $cred.Content
#>

### Comment if using CCP ###
Write-Host "Please log into EPV"
$user = Read-Host "EPV User Name"
$securePassword = Read-Host "Password" -AsSecureString
$BSTR = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($securePassword)
$unsecurePassword = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto($BSTR)
$login = EPVLogin $user $unsecurePassword
$unsecurePassword = ""


$script:header = New-Object "System.Collections.Generic.Dictionary[[String],[String]]"
$script:header.Add("Authorization", $login.CyberArkLogonResult)

If ($bulk) {
	$csvObject = (Import-Csv $csvPath)
	
	ForEach ($item in $csvObject) {
		$safeToCreate = $item."Team Name / Safe Name"
		$safeOwner = $item."Team AD Group"
		$description = "Team safe for " + $safeToCreate + "."
		
		MAIN $safeToCreate $description $safeOwner $user $ldapDIR
	}
} Else {
	$safeToCreate = Read-Host "What is the name of the Team that needs a safe created"
	$safeOwner = Read-Host "What ad group will provide access to this safe"
	$description = "Team safe for " + $safeToCreate + "."
	
	MAIN $safeToCreate $description $safeOwner $user $ldapDIR
}

EPVLogoff

########################### END SCRIPT ###################################################