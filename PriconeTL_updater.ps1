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
	Write-Host "Requesting admin privilege..."
	Start-Process powershell.exe "-NoProfile -ExecutionPolicy Bypass -Command `"& ([scriptblock]::Create((irm https://bit.ly/3RjFnwE))) -U:`$$Uninstall -FR:`$$ForceRedownload -V:`$$Verify`"; pause" -Verb RunAs
	exit
}
$Global:ProgressPreference = 'SilentlyContinue'

if (!(Get-Module -ListAvailable -Name ThreadJob)) {
	Write-Host "`nInstalling ThreadJob as dependency..."
	Write-Host "^ This will only happen once!"
	Set-PSRepository -Name 'PSGallery' -InstallationPolicy Trusted
	Install-Module -Name ThreadJob -Force
}

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
		Write-Error "Cannot find the game path!`nDid you install Priconne from DMM Game?"
		return
	}
	catch {
		Write-Error $_.Exception
		return
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
			$LocalVersion = Get-Content -Raw -Path "$PriconnePath\Version.txt" -ErrorAction Stop
		}
		Write-Host "Current Version: $LocalVersion"
	}
	catch [System.Management.Automation.ItemNotFoundException] {
		$LocalVersion = "None"
	}
	catch {
		Write-Error $_.Exception
		return
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
		Write-Error $_.Exception
		return
	}

	Write-Host "Latest Version: $Version"
	return $Version, $AssetsLink
}

function Remove-Mod {
	$p = Get-Process "PrincessConnectReDive" -ErrorAction SilentlyContinue

	if ($p) {
		Write-Host "`nPriconne is still running and will be killed to remove old files!`n"
		Timeout /NoBreak 5
		Stop-Process $p
	}
	Write-Host "Removing TL Mod..."
	try {
		$UninstallFile = @(
			"BepInEx",
			"TLUpdater",
			"PriconeTL_Updater.bat",
			"doorstop_config.ini",
			"winhttp.dll",
			"Version.txt",
			"changelog.txt"
		)

		foreach ($file in $UninstallFile) {
			if (Test-Path "$PriconnePath\$file" -PathType Any) {
				Remove-Item -Path "$PriconnePath\$file" -Recurse -Force -ErrorAction Stop
				Write-Verbose "Removing $file"
			}
		}
	}
	catch {
		Write-Error $_.Exception
		return
	}
}

function Get-TLMod {
	Param(
		[System.String]$LinkZip
	)
	try {
		$ZipPath = "$Env:TEMP\PriconeTL.zip"

		Write-Host "Downloading compressed mod files..."
		Write-Verbose "Assets File: $LinkZip`n"
		Invoke-WebRequest $LinkZip -OutFile $ZipPath
		Write-Host "Extracting mod files to game folder..."
		Expand-Archive -Path $ZipPath -DestinationPath $PriconnePath -Force
		Remove-Item -Path $ZipPath
	}
	catch {
		Write-Error $_.Exception
		return
	}
}

function Update-ChangedFiles {
	param(
		[string]$LocalVer
	)

	Write-Host "Updating changed files..."

	try {
		$SHA = Get-SHAVersion $LocalVer

		Write-Verbose "Compare URI: $GithubAPI/compare/$SHA...main"
		$ChangedFiles = Invoke-RestMethod -URI "$GithubAPI/compare/$SHA...main" | Select-Object -ExpandProperty files

		$jobs = @()

		#Escaping brackets from https://stackoverflow.com/questions/55869623/how-to-escape-square-brackets-in-file-paths-with-invoke-webrequests-outfile-pa/55869947#55869947
		foreach ($file in $ChangedFiles) {
			if ($file.filename -match "Translation/.+") {
				switch ($file.status) {
					{ $_ -eq "added" -or $_ -eq "modified" } {
						$Script = {
							param (
								$FileName, $URI
							)
							Get-FileViaTemp -FileName $FileName -GamePath $using:PriconnePath
						}
					}
					"removed" {
						$Script = {
							param(
								$FileName
							)
							Remove-Item -LiteralPath "$using:PriconnePath/BepInEx/$FileName" -Recurse
						}
					}
					"renamed" {
						$Script = {
							param(
								$FileName, $PreName
							)
							try {
								$NewName = Split-Path $FileName -Leaf
								Rename-Item -LiteralPath "$using:PriconnePath/BepInEx/$PreName" -NewName $NewName -ErrorAction Stop
							}
							catch [System.Management.Automation.PSInvalidOperationException] {
								Write-Verbose "Cannot find the needed file! Download it from repo..."
								Get-FileViaTemp -FileName $FileName -GamePath $using:PriconnePath
							}
						}
					}
				}
				Write-Verbose "$($file.status): $($file.filename)"
				$jobs += Start-ThreadJob -InitializationScript $InitScript -ScriptBlock $Script -ArgumentList $file.filename, $file.previous_filename
			}
		}

		Receive-Job -Job $jobs -AutoRemoveJob -Wait
	}
	catch {
		Write-Error $_.Exception
		return
	}
}

function Start-RedownloadMod {
	param(
		[string]$LinkZip
	)

	Write-Verbose "Redownloading TL Mod..."
	Remove-Mod
	Get-TLMod -LinkZip $LinkZip
	$Config.ForceRedownloadWhenUpdate = $false
}

function Start-DMMFastLauncher {
	if ($Config.DMMGamePlayerFastLauncherSupport) {
		$DMMFastLauncher = @(
			$Config.CustomDMMGPFLPath,
			"$Env:APPDATA\DMMGamePlayerFastLauncher",
			"$PriconnePath"
		)
	
		foreach ($path in $DMMFastLauncher) {
			Write-Verbose "Checking $path\DMMGamePlayerFastLauncher.exe"
			if (Test-Path -Path "$path\DMMGamePlayerFastLauncher.exe" -PathType Leaf -ErrorAction SilentlyContinue) {
				Write-Verbose "Found!"
				Write-Host "Starting PriconneR game..."
				Start-Process -FilePath "$path\DMMGamePlayerFastLauncher.exe" -WorkingDirectory "$path" -ArgumentList "priconner"
				return
			}
			Write-Verbose "Not Exist!"
		}
	}
}

function Import-UserConfig {
	param (
		[string]$Path
	)
	$Config = @{
		"DMMGamePlayerFastLauncherSupport" = $true;
		"CustomDMMGPFLPath"                = "";
		"ForceRedownloadWhenUpdate"        = $false;
		"TLVersion"                        = ""; 
		"Uninstall"                        = $false;
		"VerifyFilesAfterUpdate"           = $true;
		"VerifyIgnoreFiles"                = @(
			"Translation/en/Text/_AutoGeneratedTranslations.txt",
			"Translation/en/Text/_Postprocessors.txt",
			"Translation/en/Text/_Preprocessors.txt",
			"Translation/en/Text/_Substitutions.txt",
			"Translation/id/Text/_AutoGeneratedTranslations.txt",
			"Translation/id/Text/_Postprocessors.txt",
			"Translation/id/Text/_Preprocessors.txt",
			"Translation/id/Text/_Substitutions.txt"
		)
	}

	$UserConfig = Get-Content $Path -ErrorAction SilentlyContinue | ConvertFrom-Json
	$Names = ($UserConfig | ConvertTo-Json | ConvertFrom-Json).PSObject.Properties.Name

	foreach ($name in $Names) {
		Write-Verbose "Import Config: $name = $($UserConfig.$name)"
		$Config.$name = $UserConfig.$name
	}

	Write-Verbose "Config: $Config"
	return $Config
}

function Get-SHAVersion {
	param (
		[string]$Version
	)

	$SHAVersion = Invoke-RestMethod -URI "$GithubAPI/git/ref/tags/$Version" | Select-Object -ExpandProperty object | Select-Object -ExpandProperty sha
	
	return $SHAVersion
}

function Compare-TLFiles {
	param (
		[string]$LatestVer
	)

	Write-Host "Verifying..."

	$SHA = Get-SHAVersion $LatestVer
	$RemotePath = "$GithubAPI/git/trees/${SHA}?recursive=0"
	$LocalFiles = @()
	$RemoteFiles = @()
	$jobs = @()
	
	foreach ($file in (Get-ChildItem -Path "$PriconnePath\BepInEx\Translation" -Recurse -File)) {
		$Path = $file.FullName.Replace("$PriconnePath\BepInEx\", "").Replace("\", "/").Replace("``", "")
		if (!($Path -in $Config.VerifyIgnoreFiles)) {
			$LocalFiles += $Path
		}
	}

	$RemList = (Invoke-RestMethod $RemotePath).tree
	foreach ($file in $RemList) {
		if ($file.path.StartsWith("Translation/") -and ($file.type -eq "blob") -and !($file.path -in $Config.VerifyIgnoreFiles)) {
			$RemoteFiles += $file.path
		}
	}
	
	$Compare = Compare-Object -ReferenceObject $LocalFiles -DifferenceObject $RemoteFiles
	if ($Compare) {
		New-Item "$PriconnePath\TLUpdater\CompareFiles.log" -Force | Out-Null
		"`nComparing:" | Out-File "$PriconnePath\TLUpdater\CompareFiles.log"
		$Compare | Out-File "$PriconnePath\TLUpdater\CompareFiles.log" -Append

		foreach ($file in $Compare) {
			switch ($file.SideIndicator) {
				"<=" {
					Write-Verbose "removed: $($file.InputObject)"
					$Script = {
						param(
							[string]$FileName
						)
						Remove-Item -LiteralPath "$using:PriconnePath\BepInEx\$FileName"
					}
				}
				"=>" {
					Write-Verbose "added: $($file.InputObject)"
					$Script = {
						param(
							[string]$FileName
						)
						Get-FileViaTemp -FileName $FileName -GamePath $using:PriconnePath
					}
					
				}
			}
			$jobs += Start-ThreadJob -InitializationScript $InitScript -ScriptBlock $Script -ArgumentList $file.InputObject
		}
		Receive-Job -Job $jobs -AutoRemoveJob -Wait
	}
}

$Global:InitScript = {
	function Get-FileViaTemp {
		param(
			[string]$FileName
			,
			[string]$GamePath
		)

		$SplitedPath = Split-Path "$GamePath\BepInEx\$FileName"
		$URI = "https://raw.githubusercontent.com/ImaterialC/PriconeTL/main/$FileName"

		Invoke-RestMethod -URI $URI -OutFile ($tempFile = New-TemporaryFile)
		if (!(Test-Path $SplitedPath -PathType Container)) {
			New-Item $SplitedPath -ItemType Directory -Force | Out-Null
		}
		Move-Item -LiteralPath $tempFile -Destination "$GamePath\BepInEx\$FileName" -Force
	}
}

$CfgFileLocation = "$Env:APPDATA\dmmgameplayer5\dmmgame.cnf"
$Global:GithubAPI = "https://api.github.com/repos/ImaterialC/PriconeTL"
$Global:PriconnePath = Get-GamePath -CfgFile $CfgFileLocation
$Global:Config = Import-UserConfig -Path "$PriconnePath\TLUpdater\config.json"

if ($Uninstall -or $Config.Uninstall) {
	Remove-Mod
	Write-Host "`nDone!"
	return
}

Write-Host "`nChecking for update..."
$LocalVer = Get-LocalVersion -Path $PriconnePath
$LatestVer = Get-LatestRelease

if ($ForceRedownload) {
	Start-RedownloadMod -LinkZip $LatestVer[1]
	Write-Host "`nDone"
	Start-DMMFastLauncher
	return
}

if ($Verify) {
	Compare-TLFiles $LatestVer[0]
	Write-Host "`nDone"
	Start-DMMFastLauncher
	return
}

if ($LocalVer -ge $LatestVer[0].Replace(".", "") -and $LocalVer -ne "None") {
	Write-Host "`nYour PriconeTL version is latest!"
}

elseif ($LocalVer -le $LatestVer[0]) {
	Write-Host "`nUpdating TL Mod..."
	if (!$Config.ForceRedownloadWhenUpdate -or !$ForceRedownload) {
		Write-Verbose "Comparing your version with latest version..."
		Update-ChangedFiles $LocalVer
		if ($Config.VerifyFilesAfterUpdate) {
			Compare-TLFiles $LatestVer[0]
		}
	}
	else {
		Start-RedownloadMod -LinkZip $LatestVer[1]
	}
	Write-Host "`nDone!"
}
else {
	Write-Host "`nDownloading and installing TL Mod..."
	Get-TLMod -LinkZip $LatestVer[1]
	Write-Host "`nDone!"
}

$Config.TLVersion = $LatestVer[0]
New-Item -Path "$PriconnePath\TLUpdater" -ItemType Directory -ErrorAction SilentlyContinue | Out-Null
$Config | ConvertTo-Json | Out-File "$PriconnePath\TLUpdater\config.json" -Force

Start-DMMFastLauncher