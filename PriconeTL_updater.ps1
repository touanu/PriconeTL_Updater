$CfgFileLocation = "$Env:APPDATA\dmmgameplayer5\dmmgame.cnf"
$Global:GithubAPI = "https://api.github.com/repos/ImaterialC/PriconeTL"

Clear-Host

function Get-GamePath {
	Param(
		[System.String]$CfgFile
	)
	try {
		$CfgFileContent = Get-Content $CfgFile -ErrorAction Stop | ConvertFrom-Json
		$DetailContent = $CfgFileContent.contents | Where-Object { $_.productId -eq "priconner" }
		$PriconnePath = $DetailContent.detail.path
	}
	catch [System.Management.Automation.ItemNotFoundException] {
		Write-Error "Cannot find the game path!`n Did you install Priconne from DMM Game?"
		break
	}
	catch {
		Write-Verbose $_.Exception
		Write-Error "Cannot get game path!"
		break
	}

	Write-Host "Found priconner in $PriconnePath"
	return $PriconnePath
}

function Get-LocalVersion {
	Param (
		[System.String]$Path
	)
	try {
		if ($Config.TLVersion) {
			$LocalVersion = $Config.TLVersion
		}
		else {
			$LocalVersion = Get-Date -Date (Get-Item "$Path\BepInEx\Translation" -ErrorAction Stop).LastWriteTime -Format "yyyyMMdd"
		}
	}
	catch [System.Management.Automation.ItemNotFoundException] {
		$LocalVersion = "None"
	}
	catch {
		Write-Verbose $_.Exception
		Write-Error "Error(s) occurred while trying to get local version!"
		break
	}
	
	return $LocalVersion
}

function Get-LatestRelease {
	try {
		$Response = Invoke-WebRequest "$GithubAPI/releases/latest"
		$Json = $Response.Content | ConvertFrom-Json
		$Version = $Json | Select-Object -ExpandProperty tag_name
		$AssetsLink = $Json | Select-Object -ExpandProperty assets | Select-Object -ExpandProperty browser_download_url
	}
	catch {
		Write-Verbose $_.Exception
		Write-Error "Cannot get latest release info!"
		break
	}

	if ($Response.StatusCode -ne 200) {
		Write-Error "Status Code wasn't 200"
		break
	}

	return $Version, $AssetsLink
}

function Remove-OldMod {
	$p = Get-Process "PrincessConnectReDive" -Erroraction 'SilentlyContinue'

	if ($p) {
		Write-Host "`nPriconne is still running and will be killed to remove old files!`n"
		Timeout /NoBreak 5
		Stop-Process $p
	}
	try {
		Remove-Item -Path "$PriconnePath\BepInEx" -Recurse -Erroraction 'Stop'
		Remove-Item -Path "$PriconnePath\PriconeTL_Updater.bat" -Erroraction 'SilentlyContinue'
	}
	catch [System.UnauthorizedAccessException] {
		Write-Host "Requesting admin permissions to delete files..."
		$command = "Remove-Item -Path $PriconnePath\BepInEx -Recurse -Erroraction 'SilentlyContinue'; Remove-Item -Path $PriconnePath\PriconeTL_Updater.bat -Erroraction 'SilentlyContinue'"
		Start-Process powershell -Verb runAs -WorkingDirectory $PriconnePath -WindowStyle hidden -ArgumentList "-Command $command"
	}
	catch {
		Write-Verbose $_.Exception
		Write-Error "Error(s) occurred while removing old BepInEx folder!"
		break
	}
}

function Get-TLMod {
	Param(
		[System.String]$LinkZip,
		[System.String]$ZipPath
	)
	try {
		Write-Host "Downloading compressed mod files..."
		Write-Verbose "Assets File: $LinkZip`n"
		Invoke-WebRequest $LinkZip -OutFile $ZipPath
		Write-Host "Extracting mod files to game folder..."
		Expand-Archive -Path $ZipPath -DestinationPath $PriconnePath -Force
		Remove-Item -Path $ZipPath
	}
	catch {
		Write-Verbose $_.Exception
		Write-Error "Error(s) occurred while installing mod!"
		break
	}
}

function Update-ChangedFiles {
	param(
		[string]$LocalVer
	)

	Write-Verbose "Compare URI: $GithubAPI/compare/$LocalVer...main"
	$ChangedFiles = Invoke-RestMethod -URI "$GithubAPI/compare/$LocalVer...main" | Select-Object -ExpandProperty files

	foreach ($file in $ChangedFiles) {
		if ($file.filename -match "Translation/.+") {
			Write-Verbose "`n$($file.status): $($file.filename)"
			switch ($file.status) {
				{ $_ -eq "added" -or $_ -eq "modified" } {
					#Escaping brackets from https://stackoverflow.com/questions/55869623/how-to-escape-square-brackets-in-file-paths-with-invoke-webrequests-outfile-pa/55869947#55869947
					Invoke-RestMethod -URI $file.raw_url -OutFile "$PriconnePath/BepInEx/$([WildcardPattern]::Escape($file.filename))"
					Write-Verbose "RawURL: $($file.raw_url)"
				}
				"removed" {
					Remove-Item -LiteralPath "$PriconnePath/BepInEx/$($file.filename)"
				}
			}
		}
	}
}

function Import-UserConfig {
	param (
		[Parameter(Mandatory, Position = 1)]
		[string]
		$Path
	)
	$Config = @{
		"DMMGamePlayerFastLauncherSupport" = $true;
		"CustomDMMGPFLPath"                = "";
		"CustomDMMGPFLArguments"           = "";
		"ForceRedownloadWhenUpdate"        = $false;
		"TLVersion"                        = ""; 
	}

	$UserConfig = Get-Content $Path -Erroraction SilentlyContinue | ConvertFrom-Json
	$Names = ($UserConfig | ConvertTo-Json | ConvertFrom-Json).PSObject.Properties.Name

	foreach ($name in $Names) {
		Write-Verbose "Import Config: $name = $($UserConfig.$name)"
		$Config.$name = $UserConfig.$name
	}

	Write-Verbose "Config: $Config"
	return $Config
}

if (Test-Path -Path $CfgFileLocation) {
	$Global:PriconnePath = Get-GamePath -CfgFile $CfgFileLocation
}
else {
	Write-Error "Cannot find DMM Game config file`nDid you install DMM Game?"
	break
}

$Global:Config = Import-UserConfig -Path "$PriconnePath\TLUpdater\config.json"

Write-Host "`nChecking for update..."
$LocalVer = Get-LocalVersion -Path $PriconnePath
Write-Host "Current Version: $LocalVer"
$LatestVer = Get-LatestRelease
Write-Host "Latest Version: $($LatestVer[0])"

if ($LocalVer -ge $LatestVer[0]) {
	Write-Host "`nYour PriconeTL version is latest!"
}
elseif ($LocalVer -ne "None") {
	Write-Host "`nUpdating TL Mod..."
	if (!$Config.ForceRedownloadWhenUpdate) {
		Write-Verbose "Comparing your version with latest version..."
		Update-ChangedFiles $LocalVer
	}
	else {
		Write-Verbose "Redownloading TL Mod..."
		Remove-OldMod
		Get-TLMod -LinkZip $LatestVer[1] -ZipPath "$Env:TEMP\PriconeUIENDMM.zip"
	}
	Write-Host "`nDone!"
}
else {
	Write-Host "`nDownloading and installing TL Mod..."
	Get-TLMod -LinkZip $LatestVer[1] -ZipPath "$Env:TEMP\PriconeUIENDMM.zip"
	Write-Host "`nDone!"
}

$Config.TLVersion = $LatestVer[0]
New-Item -Path "$PriconnePath\TLUpdater" -ItemType "directory" -ErrorAction SilentlyContinue
$Config | ConvertTo-Json | Out-File "$PriconnePath\TLUpdater\config.json" -Force

if ($Config.DMMGamePlayerFastLauncherSupport) {
	$DMMFastLauncher = @(
		"$Env:APPDATA\DMMGamePlayerFastLauncher",
		"$PriconnePath",
		$Config.CustomDMMGPFLPath
	)

	foreach ($path in $DMMFastLauncher) {
		Write-Verbose "Checking $path\DMMGamePlayerFastLauncher.exe"
		if (Test-Path -Path "$path\DMMGamePlayerFastLauncher.exe" -PathType Leaf -ErrorAction SilentlyContinue) {
			Write-Verbose "Found!"
			if ($Config.CustomDMMGPFLArguments) {
				$EscapedArguments = $Config.CustomDMMGPFLArguments.Replace("\u0027","`'")
				Write-Verbose "Custom Arguments: $($Config.CustomDMMGPFLArguments)"
			}
			Write-Host "Starting PriconneR game..."
			Start-Process -FilePath "$path\DMMGamePlayerFastLauncher.exe" -WorkingDirectory "$path" -ArgumentList "priconner $EscapedArguments"
			break
		}
		Write-Verbose "Not Exist!"
	}
}