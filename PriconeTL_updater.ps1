param (
	[Alias("U")][parameter()]
	[switch]$Uninstall = $false
	,
	[Alias("FR")][parameter()]
	[switch]$ForceRedownload = $false
	,
	[Alias("V")][parameter()]
	[switch]$Verify = $false
)

If (!([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole] "Administrator")) {
	Write-Output "Requesting admin privilege..."
	$arguments = "-U:`$$Uninstall -FR:`$$ForceRedownload -V:`$$Verify"
	if ($PSCommandPath) {
		Write-Verbose "Using local script"
		$Command = "$PSCommandPath $arguments"
	}
	else {
		Write-Verbose "Using remote script"
		$Command = "& ([scriptblock]::Create((irm https://bit.ly/3RjFnwE))) $arguments"
	}
	Start-Process powershell.exe "-NoProfile -ExecutionPolicy Bypass -Command `"$Command`"; pause" -Verb RunAs
	exit
}
$Global:ProgressPreference = 'SilentlyContinue'
$Global:InformationPreference = 'Continue'

if (!(Get-Module -ListAvailable -Name ThreadJob)) {
	Write-Output "`nInstalling ThreadJob as dependency..."
	Write-Output "^ This will only happen once!"
	Set-PSRepository -Name 'PSGallery' -InstallationPolicy Trusted
	Install-Module -Name ThreadJob -Force
}

function Get-GamePath {
	try {
		$CfgFileContent = Get-Content "$Env:APPDATA\dmmgameplayer5\dmmgame.cnf" -ErrorAction Stop | ConvertFrom-Json
		$PriconnePath = ($CfgFileContent.contents | Where-Object productId -eq "priconner").detail.path
	}
	catch [System.Management.Automation.ItemNotFoundException] {
		Write-Error "Cannot find the game path!`nDid you install Priconne from DMM Game?"
		exit
	}
	catch {
		Write-Error $_.Exception
		exit
	}

	Write-Information "Found priconner in $PriconnePath"
	return $PriconnePath
}

function Get-LocalVersion {
	try {
		$RawVersionFile = Get-Content -Raw -Path "$PriconnePath\BepInEx\Translation\en\Text\Version.txt" -ErrorAction Stop
		$LocalVersion = $RawVersionFile | Select-String '\d{8}' | Select-Object -ExpandProperty Matches | Select-Object -ExpandProperty Value
		Write-Information "Current Version: $LocalVersion"
	}
	catch [System.Management.Automation.ItemNotFoundException] {
		$LocalVersion = "None"
	}
	catch {
		Write-Error $_.Exception
		exit
	}

	return $LocalVersion
}

function Get-LatestRelease {
	try {
		$Response = Invoke-RestMethod "$GithubAPI/releases/latest"
		$Version = $Response | Select-Object -ExpandProperty tag_name
		$AssetsLink = $Response | Select-Object -ExpandProperty assets | Select-Object -ExpandProperty browser_download_url
	}
	catch {
		Write-Error $_.Exception
		exit
	}

	Write-Information "Latest Version: $Version"
	return $Version, $AssetsLink
}

function Remove-Mod {
	param(
		[switch]$RemoveConfig = $false
	)
	
	$p = Get-Process "PrincessConnectReDive" -ErrorAction SilentlyContinue

	if ($p) {
		Write-Information "`nScript cannot delete mod files while PriconneR is running.`n"
		$null = Read-Host -Prompt "Please close Priconne and press Enter to continue"
	}
	$UninstallFile = @(
		"$PriconnePath\BepInEx",
		"$PriconnePath\dotnet",
		"$PriconnePath\TLUpdater",
		"$PriconnePath\.doorstop_version"
		"$PriconnePath\doorstop_config.ini",
		"$PriconnePath\winhttp.dll",
		"$PriconnePath\Version.txt",
		"$PriconnePath\changelog.txt"
	)

	if ($RemoveConfig) {
		$Exclusion = @()
		Write-Information "`nRemoving TL Mod completely..."
	}
	else {
		$Exclusion = "config", "TLUpdater"
		Write-Information "`nRemoving old TL Mod..."
	}

	Get-ChildItem -Path $UninstallFile -Exclude $Exclusion -Recurse | Remove-Item -Force -Recurse
}

function Get-TLMod {
	try {
		$ZipPath = "$Env:TEMP\PriconeTL.zip"

		Write-Information "`nDownloading compressed mod files..."
		Write-Verbose "Assets File: $AssetLink`n"

		Invoke-WebRequest $AssetLink -OutFile $ZipPath

		Write-Information "`nExtracting mod files to game folder..."
		Expand-Archive -Path $ZipPath -DestinationPath $PriconnePath -Force
		Remove-Item -Path $ZipPath
	}
	catch {
		Write-Error $_.Exception
		return
	}
}

function Update-ChangedFiles {
	Write-Information "Updating changed files...`n"

	Write-Verbose "Compare URI: $GithubAPI/compare/$LocalVer...$LatestVer"
	$ChangedFiles = Invoke-RestMethod -URI "$GithubAPI/compare/$LocalVer...$LatestVer" | Select-Object -ExpandProperty files

	$jobs = $ChangedFiles | . { process {
		$file = $_
		if ($file.filename -match "^src/.+") {
			$filename = $file.filename.Replace("src/","")
			switch ($file.status) {
				{ $_ -eq "added" -or $_ -eq "modified" } {
					$Script = {
						Get-FileViaTemp -FileName $args[0] -GamePath $using:PriconnePath
						Write-Output "$($args[1]): $($args[0])"
					}
					$Arguments = @($filename, $file.status)
				}
				"removed" {
					$Script = {
						try {
							Remove-Item -LiteralPath "$using:PriconnePath/$args" -Recurse -ErrorAction Stop
							Write-Output "removed: $args"
						}
						catch [System.Management.Automation.ItemNotFoundException] {
							Write-Output "not found: $args"
						}
					}
					$Arguments = $filename
				}
				"renamed" {
					$previous_filename = $file.previous_filename.Replace("src/", "")
					$Script = {
						try {
							$NewName = Split-Path $args[0] -Leaf
							Rename-Item -LiteralPath "$using:PriconnePath/$($args[1])" -NewName $NewName -ErrorAction Stop
							Write-Output "renamed: $($args[0])"
						}
						catch [System.Management.Automation.PSInvalidOperationException] {
							Write-Verbose "Cannot find the needed file! Download it from repo..."
							Get-FileViaTemp -FileName $args[0] -GamePath $using:PriconnePath
							Write-Output "added: $($args[0])"
						}
					}
					$Arguments = @($filename, $previous_filename)
				}
			}
			Start-ThreadJob -InitializationScript $InitScript -ScriptBlock $Script -ArgumentList $Arguments
		}
	}}

	if (@($jobs).count -ne 0) {
		Receive-Job -Job $jobs -AutoRemoveJob -Wait
	}
	else {
		Write-Information "Nothing changed between two versions!`nFalling back to redownload patch..."
		Remove-Mod
		Get-TLMod
	}

	$Version = "$PriconnePath\BepInEx\Translation\en\Text\Version.txt"
	Set-Content -Path $Version -Value (Get-Content $Version).Replace($LocalVer, $LatestVer)
}

function Start-DMMFastLauncher {
	if ($Config.DMMGamePlayerFastLauncherSupport) {
		$DMMFastLauncher = @(
			$Config.CustomDMMGPFLPath,
			"$Env:APPDATA\DMMGamePlayerFastLauncher",
			$PriconnePath
		)
	
		foreach ($path in $DMMFastLauncher) {
			Write-Verbose "Checking $path\DMMGamePlayerFastLauncher.exe"
			if (Test-Path -Path "$path\DMMGamePlayerFastLauncher.exe" -PathType Leaf -ErrorAction SilentlyContinue) {
				Write-Information "Found DMMGamePlayerFastLauncher in $path!"
				Write-Information "Starting PriconneR game..."
				Start-Process -FilePath "$path\DMMGamePlayerFastLauncher.exe" -WorkingDirectory "$path" -ArgumentList "priconner"
				return
			}
			Write-Verbose "Not Exist!"
		}
	}
}

function Import-UserConfig {
	$Config = @{
		"DMMGamePlayerFastLauncherSupport" = $true;
		"CustomDMMGPFLPath"                = "";
		"ForceRedownloadWhenUpdate"        = $false;
		"Uninstall"                        = $false;
		"VerifyFilesAfterUpdate"           = $true;
		"VerifyIgnoreFiles"                = @(
			"Translation/en/Text/_AutoGeneratedTranslations.txt",
			"Translation/en/Text/_Postprocessors.txt",
			"Translation/en/Text/_Substitutions.txt",
			"Translation/id/Text/_AutoGeneratedTranslations.txt",
			"Translation/id/Text/_Postprocessors.txt",
			"Translation/id/Text/_Substitutions.txt"
		)
	}

	$UserConfig = Get-Content $UserCfgLocation -ErrorAction SilentlyContinue | ConvertFrom-Json
	$Names = ($UserConfig | ConvertTo-Json | ConvertFrom-Json).PSObject.Properties.Name

	foreach ($name in $Names) {
		Write-Verbose "Import Config: $name = $($UserConfig.$name)"
		$Config.$name = $UserConfig.$name
	}

	Write-Verbose "Config: $Config"
	return $Config
}

function Compare-TLFiles {
	Write-Information "Verifying..."

	$SHA = Invoke-RestMethod -URI "$GithubAPI/git/ref/tags/$LatestVer" | Select-Object -ExpandProperty object | Select-Object -ExpandProperty sha
	$LocalPaths = @(
		"$PriconnePath\BepInEx\Translation",
		"$PriconnePath\BepInEx\config\AutoTranslatorConfig.ini",
		"$PriconnePath\BepInEx\core",
		"$PriconnePath\BepInEx\plugins\XUnity.AutoTranslator",
		"$PriconnePath\BepInEx\plugins\XUnity.ResourceRedirector",
		"$PriconnePath\BepInEx\plugins\FullScreenizer.dll",
		"$PriconnePath\BepInEx\plugins\PriconneTLFixup.dll",
		"$PriconnePath\dotnet",
		"$PriconnePath\.doorstop_version",
		"$PriconnePath\changelog.txt",
		"$PriconnePath\doorstop_config.ini",
		"$PriconnePath\winhttp.dll"
	)

	$LocalFiles = (Get-ChildItem -Path $LocalPaths -Recurse -File) | . { process {
		$Path = $_.FullName.Replace("$PriconnePath\", "").Replace("\", "/")
		if ($Path -notin $Config.VerifyIgnoreFiles) {
			$Path
		}
	}}

	$RemoteFiles = (Invoke-RestMethod "$GithubAPI/git/trees/${SHA}?recursive=0").tree | . { process {
		if (($_.path -match "^src/.+") -and ($_.type -eq "blob") -and ($_.path -notin $Config.VerifyIgnoreFiles)) {
			$_.path.Replace("src/","")
		}
	}}

	$jobs = Compare-Object -ReferenceObject $LocalFiles -DifferenceObject $RemoteFiles | . { process {
		switch ($_.SideIndicator) {
			"<=" {
				$Script = {
					Remove-Item -LiteralPath "$using:PriconnePath\$args"
					Write-Output "removed: $args"
				}
			}
			"=>" {
				$Script = {
					Get-FileViaTemp -FileName $args -GamePath $using:PriconnePath
					Write-Output "added: $args"
				}
			}
		}
		Start-ThreadJob -InitializationScript $InitScript -ScriptBlock $Script -ArgumentList $_.InputObject
	}}
	if (@($jobs).count -ne 0) {
		Receive-Job -Job $jobs -AutoRemoveJob -Wait
	}
}

New-Item -ItemType Directory -Path "$Env:TEMP\TLUpdaterLogs" -ErrorAction SilentlyContinue
$LogFile = "$Env:TEMP\TLUpdater-Logs\$(Get-Date -Format 'yyyy-MM-dd_HH-mm-ss').log"
Start-Transcript -Path $LogFile | Out-Null

$GithubAPI = "https://api.github.com/repos/ImaterialC/PriconneRe-TL"
$PriconnePath = Get-GamePath
$UserCfgLocation = "$PriconnePath\TLUpdater\config.json"
$Config = Import-UserConfig

if ($Uninstall -or $Config.Uninstall) {
	Remove-Mod -RemoveConfig
}
else {
	Write-Output "`nChecking for update..."
	$LocalVer = Get-LocalVersion
	$LatestVer, $AssetLink = Get-LatestRelease

	if ($LocalVer -ge $LatestVer -and $LocalVer -ne "None" -and !$ForceRedownload -and !$Verify) {
		Write-Output "`nYour PriconeTL version is latest!"
	}
	elseif ($LocalVer -le $LatestVer -or $Verify) {
		if (!$Config.ForceRedownloadWhenUpdate -and !$ForceRedownload) {
			$InitScript = {
				function Get-FileViaTemp {
					param(
						[string]$FileName
						,
						[string]$GamePath
					)
		
					$SplitedPath = Split-Path "$GamePath\$FileName"
					$URI = "https://raw.githubusercontent.com/ImaterialC/PriconneRe-TL/master/src/$FileName"
					# Write-Output "URI: $URI"
		
					Invoke-RestMethod -URI $URI -OutFile ($tempFile = New-TemporaryFile)
					if (!(Test-Path $SplitedPath -PathType Container)) {
						New-Item $SplitedPath -ItemType Directory -Force | Out-Null
					}
					Move-Item -LiteralPath $tempFile -Destination "$GamePath\$FileName" -Force
				}
			}
			if (!$Verify) {
				Update-ChangedFiles
			}
			if ($Config.VerifyFilesAfterUpdate -or $Verify) {
				Compare-TLFiles
			}
		}
		else {
			Remove-Mod
			Get-TLMod
		}
		Write-Output "`nDone!"
	}
	else {
		Write-Output "`nDownloading and installing TL Mod..."
		Get-TLMod
		Write-Output "`nDone!"
	}

	New-Item -Path "$PriconnePath\TLUpdater" -ItemType Directory -ErrorAction SilentlyContinue
	$Config | ConvertTo-Json | Out-File $UserCfgLocation -Force
	Start-DMMFastLauncher
}

Write-Output ""
Stop-Transcript
