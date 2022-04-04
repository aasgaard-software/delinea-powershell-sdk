﻿###########################################################################################
# Delinea Platform PowerShell module
#
# Author   : Fabrice Viguier
# Contact  : support AT Delinea.com
# Release  : 21/02/2022
# Copyright: (c) 2022 Delinea Corporation. Licensed under the Apache License, Version 2.0 (the "License"); you may not use this file except in compliance with the License.
#            You may obtain a copy of the License at http://www.apache.org/licenses/LICENSE-2.0 Unless required by applicable law or agreed to in writing, software
#            distributed under the License is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
#            See the License for the specific language governing permissions and limitations under the License.
###########################################################################################

<#
.SYNOPSIS
This Cmdlet is creating a secure connection with a Delinea XPM Platform tenant specified by its Identity Services Url.

.DESCRIPTION
This Cmdlet support different methods of authentication to connect to a XPM Platform Identity Service tenant. 
The methods available are:
- Interactive authentication using Multi-Factor Authentication.
    This connection is made by specifying a User name and answering any challenge prompted. The User could be using simple password authentication if exempted from MFA, or have to choose from a list of mechanism available for him. This method is subject to Delinea Portal policy in effect for this particular User.

- Pre-authorised authentication using OAuth2 Client authentication.
    This connection is made by specifying an OAuth2 Service name and scope, as well as the Secret for a Service User authorised to obtain an OAuth2 token. An OAuth2 Client App must be configured on the Delinea Identity Platform to allow OAUth2 Client authentication.

.PARAMETER Url
Specify the URL to use for the connection (e.g. tenant.identity.delinea.app).

.PARAMETER User
Specify the User login to use for the connection (e.g. admin@tenant.delinea.app).

.PARAMETER Secret
Specify the OAuth2 Secret to use for the ClientID.

.PARAMETER Client
Specify the OAuth2 Client Application ID to use to obtain a Bearer Token.

.PARAMETER Scope
Specify the OAuth2 Scope Name to claim a Bearer Token for.

.INPUTS

.OUTPUTS
[Object]PlatformConnection
This object is returned as a Global variable in the PS Session in case of succesful connection to XPM PLatform.

.EXAMPLE
PS C:\> Connect-XPMPlatform -Url tenant.identity.delinea.app -User admin@tenant.delinea.app

#>
function Connect-XPMPlatform {
	param (
		[Parameter(Mandatory = $false, Position = 0, HelpMessage = "Specify the Tenant URL to use for the connection (e.g. tenant.identity.delinea.app).")]
		[Parameter(ParameterSetName = "Interactive")]
		[Parameter(ParameterSetName = "OAuth2")]
		[System.String]$Url,
		
		[Parameter(Mandatory = $true, ParameterSetName = "Interactive", HelpMessage = "Specify the User login to use for the connection (e.g. admin@tenant.delinea.app).")]
		[System.String]$User,
		
		[Parameter(Mandatory = $true, ParameterSetName = "OAuth2", HelpMessage = "Specify the OAuth2 Client ID to use to obtain a Bearer Token.")]
        [System.String]$Client,

		[Parameter(Mandatory = $true, ParameterSetName = "OAuth2", HelpMessage = "Specify the OAuth2 Scope Name to claim a Bearer Token for.")]
        [System.String]$Scope,

		[Parameter(Mandatory = $true, ParameterSetName = "OAuth2", HelpMessage = "Specify the OAuth2 Secret to use for the ClientID.")]
        [System.String]$Secret,

		[Parameter(Mandatory = $false, ParameterSetName = "Base64", HelpMessage = "Encode Base64 Secret to use for OAuth2.")]
        [Switch]$EncodeSecret,

		[Parameter(Mandatory = $false, ParameterSetName = "Base64", HelpMessage = "Decode Base64 Secret to use for Oauth2.")]
        [Switch]$DecodeSecret
	)
	
	try {	
		# Set Security Protocol for RestAPI (must use TLS 1.2)
		[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

        # Delete any existing connexion cache
        if($Global:PlatformConnection.exist) {
            $Global:PlatformConnection = $null
        }

		if (-not [System.String]::IsNullOrEmpty($Client)) {
            # Get Bearer Token from OAuth2 Client App
			$BearerToken = Delinea.Platform.PowerShell.OAuth2.GetBearerToken -Url $Url -Client $Client -Secret $Secret -Scope $Scope

            # Validate Bearer Token and obtain Session details
			$Uri = ("https://{0}/Security/Whoami" -f $Url)
			$ContentType = "application/json" 
			$Header = @{ "X-CENTRIFY-NATIVE-CLIENT" = "1"; "Authorization" = ("Bearer {0}" -f $BearerToken) }
			
			# Format Json query
			$Json = @{} | ConvertTo-Json
			
			# Connect using bearer token
			$WebResponse = Invoke-WebRequest -UseBasicParsing -Method Post -SessionVariable WebSession -Uri $Uri -Body $Json -ContentType $ContentType -Headers $Header
            $WebResponseResult = $WebResponse.Content | ConvertFrom-Json
            if ($WebResponseResult.Success) {
				# Get Connection details
				$Connection = $WebResponseResult.Result
				
				# Force URL into PodFqdn to retain URL when performing MachineCertificate authentication
				$Connection | Add-Member -MemberType NoteProperty -Name CustomerId -Value $Connection.TenantId
				$Connection | Add-Member -MemberType NoteProperty -Name PodFqdn -Value $Url
				
				# Add session to the Connection
				$Connection | Add-Member -MemberType NoteProperty -Name Session -Value $WebSession

				# Set Connection as global
				$Global:PlatformConnection = $Connection
				
				# Return information values to confirm connection success
				return ($Connection | Select-Object -Property CustomerId, User, PodFqdn | Format-List)
            }
            else {
                Throw "Invalid Bearer Token."
            }
        }
        elseif ($EncodeSecret.IsPresent) {
            # Get Confidential Client name and password
            $Client = Read-Host "Confidential Client name"
            $SecureString = Read-Host "Password" -AsSecureString
            $Password = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto([System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($SecureString))
            # Return Base64 encoded secret
            return ("Secret: {0}" -f (Delinea.Platform.PowerShell.OAuth2.ConvertToSecret -Client $Client -Password $Password))
        }		
        elseif ($DecodeSecret.IsPresent) {
            # Get Base64 secret to decode
            $Secret = Read-Host "Secret"
            # Return Confidential Client name and password
            return (Delinea.Platform.PowerShell.OAuth2.ConvertFromSecret -Secret $Secret)
        }		
        else {
			# Setup variable for interactive connection using MFA
			$Uri = ("https://{0}/Security/StartAuthentication" -f $Url)
			$ContentType = "application/json" 
			$Header = @{ "X-CENTRIFY-NATIVE-CLIENT" = "true" }
			Write-Host ("Connecting to XPM PLatform Identity Services (https://{0}) as {1}`n" -f $Url, $User)
			
			# Format Json query
			$Auth = @{}
			$Auth.User = $User
            $Auth.Version = "1.0"
			$Json = $Auth | ConvertTo-Json
			
			# Initiate connection
			$InitialResponse = Invoke-WebRequest -UseBasicParsing -Method Post -SessionVariable WebSession -Uri $Uri -Body $Json -ContentType $ContentType -Headers $Header

    		# Getting Authentication challenges from initial Response
            $InitialResponseResult = $InitialResponse.Content | ConvertFrom-Json
		    if ($InitialResponseResult.Success) {
                # Go through all challenges
                foreach ($Challenge in $InitialResponseResult.Result.Challenges) {
                    # Go through all available mechanisms
                    if ($Challenge.Mechanisms.Count -gt 1) {
                        Write-Host "`n[Available mechanisms]"
                        # More than one mechanism available
                        $MechanismIndex = 1
                        foreach ($Mechanism in $Challenge.Mechanisms) {
                            # Show Mechanism
                            Write-Host ("{0} - {1}" -f $MechanismIndex++, $Mechanism.PromptSelectMech)
                        }
                        
                        # Prompt for Mechanism selection
                        $Selection = Read-Host -Prompt "Please select a mechanism [1]"
                        # Default selection
                        if ([System.String]::IsNullOrEmpty($Selection)) {
                            # Default selection is 1
                            $Selection = 1
                        }
                        # Validate selection
                        if ($Selection -gt $Challenge.Mechanisms.Count) {
                            # Selection must be in range
                            Throw "Invalid selection. Authentication challenge aborted." 
                        }
                    }
                    elseif($Challenge.Mechanisms.Count -eq 1) {
                        # Force selection to unique mechanism
                        $Selection = 1
                    }
                    else {
                        # Unknown error
                        Throw "Invalid number of mechanisms received. Authentication challenge aborted."
                    }

                    # Select chosen Mechanism and prepare answer
                    $ChosenMechanism = $Challenge.Mechanisms[$Selection - 1]

			        # Format Json query
			        $Auth = @{}
			        $Auth.TenantId = $InitialResponseResult.Result.TenantId
			        $Auth.SessionId = $InitialResponseResult.Result.SessionId
                    $Auth.MechanismId = $ChosenMechanism.MechanismId
                    
                    # Decide for Prompt or Out-of-bounds Auth
                    switch($ChosenMechanism.AnswerType) {
                        "Text" {
                            # Prompt User for answer
                            $Auth.Action = "Answer"
                            # Prompt for User answer using SecureString to mask typing
                            $SecureString = Read-Host $ChosenMechanism.PromptMechChosen -AsSecureString
                            $Auth.Answer = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto([System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($SecureString))
                        }
                        
                        "StartTextOob" {
                            # Out-of-bounds Authentication (User need to take action other than through typed answer)
                            $Auth.Action = "StartOOB"
                            # Notify User for further actions
                            Write-Host $ChosenMechanism.PromptMechChosen
                        }
                    }
	                $Json = $Auth | ConvertTo-Json
                    
                    # Send Challenge answer
			        $Uri = ("https://{0}/Security/AdvanceAuthentication" -f $Url)
			        $ContentType = "application/json" 
			        $Header = @{ "X-Centrify-NATIVE-CLIENT" = "true" }
			
			        # Send answer
			        $WebResponse = Invoke-WebRequest -UseBasicParsing -Method Post -SessionVariable WebSession -Uri $Uri -Body $Json -ContentType $ContentType -Headers $Header
            		
                    # Get Response
                    $WebResponseResult = $WebResponse.Content | ConvertFrom-Json
                    if ($WebResponseResult.Success) {
                        # Evaluate Summary response
                        if($WebResponseResult.Result.Summary -eq "OobPending") {
                            $Answer = Read-Host "Enter code or press <enter> to finish authentication"
                            # Send Poll message to Delinea Identity Platform after pressing enter key
			                $Uri = ("https://{0}/Security/AdvanceAuthentication" -f $Url)
			                $ContentType = "application/json" 
			                $Header = @{ "X-Centrify-NATIVE-CLIENT" = "true" }
			
			                # Format Json query
			                $Auth = @{}
                            $Auth.TenantId = $InitialResponseResult.Result.TenantId
			                $Auth.SessionId = $InitialResponseResult.Result.SessionId
                            $Auth.MechanismId = $ChosenMechanism.MechanismId
                            
                            # Either send entered code or poll service for answer
                            if ([System.String]::IsNullOrEmpty($Answer)) {
                                $Auth.Action = "Poll"
                            }
                            else {
                                $Auth.Action = "Answer"
                                $Auth.Answer = $Answer
                            }
			                $Json = $Auth | ConvertTo-Json
			
                            # Send Poll message or Answer
			                $WebResponse = Invoke-WebRequest -UseBasicParsing -Method Post -SessionVariable WebSession -Uri $Uri -Body $Json -ContentType $ContentType -Headers $Header
                            $WebResponseResult = $WebResponse.Content | ConvertFrom-Json
                            if ($WebResponseResult.Result.Summary -ne "LoginSuccess") {
                                Throw "Failed to receive challenge answer or answer is incorrect. Authentication challenge aborted."
                            }
                        }

                        # If summary return LoginSuccess at any step, we can proceed with session
                        if ($WebResponseResult.Result.Summary -eq "LoginSuccess") {
                            # Get Session Token from successfull login
                            $Global:PlatformConnection = $WebResponseResult.Result
				
			                # Return information values to confirm connection success
			                return ($Global:PlatformConnection | Select-Object -Property PodFqdn, User, Summary | Format-List)
                        }
		            }
		            else {
                        # Unsuccesful connection
			            Throw $WebResponseResult.Message
		            }
                }
		    }
		    else {
			    # Unsuccesful connection
			    Throw $InitialResponseResult.Message
		    }
		}
	}
	catch {
		Throw $_.Exception
	}
}