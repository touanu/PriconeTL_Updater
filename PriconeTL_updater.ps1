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

$Global:ProgressPreference = 'SilentlyContinue'
$Global:InformationPreference = 'Continue'
If (!([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole] "Administrator")) {
	Write-Output "Requesting admin privilege..."
	$arguments = "-U:`$$Uninstall -FR:`$$ForceRedownload -V:`$$Verify"
	if ($PSCommandPath) {
		Write-Verbose "Using local script"
		$Command = "$PSCommandPath $arguments"
	}
	else {
		Write-Verbose "Using remote script"
		$Command = "& ([scriptblock]::Create((irm https://raw.githubusercontent.com/touanu/PriconeTL_Updater/main/PriconeTL_updater.ps1))) $arguments"
	}
	Start-Process powershell.exe "-NoProfile -ExecutionPolicy Bypass -Command `"$Command`"; pause" -Verb RunAs
	exit
}

function Get-GamePath {
	try {
		$CfgFileContent = Get-Content "$Env:APPDATA\dmmgameplayer5\dmmgame.cnf" -ErrorAction Stop | ConvertFrom-Json
		$PriconneContent = $CfgFileContent.contents | Where-Object productId -eq "priconner"
		$PriconnePath = $PriconneContent.detail.path
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
		$RawVersionFile = Get-Content -Raw -Path $VersionFileLocation -ErrorAction Stop
		$RegexFind = $RawVersionFile | Select-String '\d{8}\w?'
		$LocalVersion =  $RegexFind.Matches.Value
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
		$Version = $Response.tag_name
		$AssetLink = $Response.assets.browser_download_url
	}
	catch {
		Write-Error $_.Exception
		exit
	}

	Write-Information "Latest Version: $Version"
	return $Version, $AssetLink
}

function Remove-Mod {
	param(
		[switch]$RemoveConfig = $false
	)

	$UninstallFile = [System.Collections.ArrayList]@(
		"$PriconnePath\BepInEx\core",
		"$PriconnePath\BepInEx\plugins",
		"$PriconnePath\BepInEx\Translation",
		"$PriconnePath\dotnet",
		"$PriconnePath\.doorstop_version"
		"$PriconnePath\doorstop_config.ini",
		"$PriconnePath\winhttp.dll",
		"$PriconnePath\changelog.txt"
	)

	if ($RemoveConfig) {
		$ConfigFile = @(
			"$PriconnePath\BepInEx",
			"$PriconnePath\TLUpdater",
			"$Env:APPDATA\BepInEx"
		)
		$UninstallFile.AddRange($ConfigFile) | Out-Null
	}

	$p = Get-Process "PrincessConnectReDive" -ErrorAction SilentlyContinue
	if ($p) {
		Write-Information "`nScript cannot delete mod files while PriconneR is running.`n"
		$null = Read-Host -Prompt "Please close Priconne and press Enter to continue"
	}

	foreach ($file in $UninstallFile) {
		if (Test-Path "$file" -PathType Any) {
			Remove-Item -Path "$file" -Recurse -Force
			Write-Output "Removing $file"
		}
	}
}

function New-FolderIfNotExist {
	param (
		[string]$Path
	)

	$IsFolder = $Path.EndsWith("\") -or $Path.EndsWith("/")
	if (!$IsFolder) {
		$Path = Split-Path $Path
	}

	if (!(Test-Path $Path)) {
		New-Item -Path $Path -ItemType Directory -Force | Out-Null
	}
}

function Expand-ZipEntry {
	param (
		[System.IO.FileInfo]$ZipFile,
		[switch]$ExcludeIni
	)
	Add-Type -Assembly System.IO.Compression.FileSystem
	$zip = [IO.Compression.ZipFile]::OpenRead($ZipFile)
	$entries = $zip.Entries
	if ($ExcludeIni) {
		$entries = $entries | Where-Object {$_.FullName -notmatch ".+AutoTranslatorConfig\.ini$" -or $_.FullName -notmatch ".+BepInEx\.cfg$"}
	}

	$entries | . { process {
		$IsFolder = ($_.Name.Length -eq 0) -and ($_.FullName.EndsWith("/") -or $_.FullName.EndsWith("\"))
		$ExtractPath = $PriconnePath + "\" + $_.FullName
		if (!$IsFolder) {
			New-FolderIfNotExist -Path $ExtractPath
			[IO.Compression.ZipFileExtensions]::ExtractToFile($_, $ExtractPath, $true)
		}
	}}
	$zip.Dispose()
}

function Get-TLMod {
	param (
		[uri]$URI
	)

	try {
		Write-Information "`nDownloading compressed mod files..."
		Invoke-RestMethod -Uri $URI -OutFile ($tempFile = New-TemporaryFile)

		Write-Information "`nExtracting mod files to game folder..."
		if (Test-Path "$PriconnePath\BepInEx\config\*") {
			Expand-ZipEntry -ZipFile $tempFile -ExcludeConfig
		}
		else {
			Expand-ZipEntry -ZipFile $tempFile
		}

		Remove-Item -Path $tempFile
	}
	catch {
		Write-Error $_.Exception
		return
	}
}

function Get-FileViaTemp {
	param(
		[string]$FileName
	)

	$URI = "https://raw.githubusercontent.com/ImaterialC/PriconneRe-TL/master/src/$FileName"
	Start-BitsTransfer -Source $URI -Destination ($tempFile = New-TemporaryFile) -Asynchronous -ErrorAction Stop | Out-Null
	New-FolderIfNotExist "$PriconnePath\$FileName"
	Move-Item -LiteralPath $tempFile -Destination "$PriconnePath\$FileName" -Force
}

function Save-NewVersion {
	$OldVersionContent = Get-Content $VersionFileLocation
	$NewVersionContent = $OldVersionContent.Replace("Pre-release", $LatestVer).Replace($LocalVer, $LatestVer)
	Set-Content -Path $VersionFileLocation -Value $NewVersionContent
}

function Merge-RepoFiles {
	param (
		[string]$Status,
		[string]$FileName,
		[string]$PreFileName
	)
	switch ($Status) {
		{ $_ -eq "added" -or $_ -eq "modified" -or $_ -eq "=>"} {
			Get-FileViaTemp -FileName $FileName
			Write-Output "added: $FileName"
		}
		{ $_ -eq "removed" -or $_ -eq "<="} {
			try {
				Remove-Item -LiteralPath "$PriconnePath/$FileName" -Recurse -ErrorAction Stop
				Write-Output "removed: $FileName"
			}
			catch [System.Management.Automation.ItemNotFoundException] {
				Write-Output "not found: $FileName"
			}
		}
		"renamed" {
			try {
				$NewName = Split-Path $FileName -Leaf
				Rename-Item -LiteralPath "$PriconnePath/$PreFileName" -NewName $NewName -ErrorAction Stop
				Write-Output "renamed: $PreFileName -> $NewName"
			}
			catch [System.Management.Automation.PSInvalidOperationException] {
				Write-Verbose "Cannot find the needed file! Download it from repo..."
				Get-FileViaTemp -FileName $FileName
				Write-Output "added: $FileName"
			}
		}
	}
}

function Update-ChangedFiles {
	Write-Information "Updating changed files...`n"

	$URI = "$GithubAPI/compare/$LocalVer...$LatestVer"
	Write-Verbose "Compare URI: $URI"
	$ChangedFiles = (Invoke-RestMethod -URI $URI).files

	if ($ChangedFiles.Count -eq 0) {
		return $false
	}

	$ChangedFiles | . { process {
		if ($_.previous_filename) {
			$PreviousFilename = $_.previous_filename.Replace("src/", "")
		}
		$FileName = $_.filename.Replace("src/", "")
		Merge-RepoFiles -Status $_.status -FileName $FileName -PreFileName $PreviousFilename
	}}

	Get-BitsTransfer | Complete-BitsTransfer
	Save-NewVersion
}

function Start-DMMFastLauncher {
	$DMMFastLauncher = @(
		$Config.CustomDMMGPFLPath,
		"$Env:APPDATA\DMMGamePlayerFastLauncher",
		$PriconnePath
	)

	foreach ($path in $DMMFastLauncher) {
		Write-Verbose "Checking $path\DMMGamePlayerFastLauncher.exe"
		if (Test-Path -Path "$path\DMMGamePlayerFastLauncher.exe" -PathType Leaf) {
			Write-Verbose "Found DMMGamePlayerFastLauncher in $path!"
			Write-Information "Starting PriconneR game..."
			Start-Process -FilePath "$path\DMMGamePlayerFastLauncher.exe" -WorkingDirectory "$path" -ArgumentList "priconner"
			return
		}
		Write-Verbose "Not Exist!"
	}
}

function Import-UserConfig {
	$Config = @{
		"DMMGamePlayerFastLauncherSupport" = $true
		"CustomDMMGPFLPath"                = ""
		"ForceRedownloadWhenUpdate"        = $false
		"VerifyFilesAfterUpdate"           = $true
		"VerifyIgnoreFiles"                = @(
			"Translation/en/Text/_AutoGeneratedTranslations.txt",
			"Translation/en/Text/_Postprocessors.txt",
			"Translation/en/Text/_Substitutions.txt"
		)
	}

	$ConfigFileExist = Test-Path "$PriconnePath\TLUpdater\config.json"
	if (!$ConfigFileExist) {
		New-FolderIfNotExist -Path $UserCfgLocation
		$Config | ConvertTo-Json | Out-File $UserCfgLocation -Force
		return $Config
	}

	$UserConfig = Get-Content $UserCfgLocation | ConvertFrom-Json
	$Names = $UserConfig.PSOBject.Properties.Name

	foreach ($name in $Names) {
		Write-Verbose "Imported Config: $name = $($UserConfig.$name)"
		$Config.$name = $UserConfig.$name
	}

	return $Config
}

function Get-LocalFileList {
	$LocalPaths = Get-ChildItem -Recurse -File -Path @(
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

	$LocalFiles = $LocalPaths | . { process {
		$Path = $_.FullName.Replace("$PriconnePath\", "").Replace("\", "/")
		if ($Path -notin $Config.VerifyIgnoreFiles) {
			$Path
		}
	}}
	
	return $LocalFiles
}

function Get-GithubFileList {
	$SHA = (Invoke-RestMethod -URI "$GithubAPI/git/ref/tags/$LatestVer").object.sha
	$RemotePaths = (Invoke-RestMethod "$GithubAPI/git/trees/${SHA}?recursive=0").tree

	$RemoteFiles = $RemotePaths | . { process {
		if (($_.path -match "^src/.+") -and ($_.type -eq "blob") -and ($_.path -notin $Config.VerifyIgnoreFiles)) {
			$_.path.Replace("src/","")
		}
	}}

	return $RemoteFiles
}

function Compare-TLFiles {
	Write-Information "Verifying..."

	$LocalFiles = Get-LocalFileList
	$RemoteFiles = Get-GithubFileList

	$CompareResult = Compare-Object -ReferenceObject $LocalFiles -DifferenceObject $RemoteFiles
	if ($CompareResult.Count -eq 0) {
		return
	}

	$CompareResult | . { process {
		Merge-RepoFiles -Status $_.SideIndicator -FileName $_.InputObject
	}}
	Get-BitsTransfer | Complete-BitsTransfer
}

function Start-CheckForUpdate {
	Write-Output "`nChecking for update..."
	$LocalVer = Get-LocalVersion
	$LatestVer, $AssetLink = Get-LatestRelease

	if ($ForceRedownload) {
		Remove-Mod
		Get-TLMod -URI $AssetLink
		return
	}

	if ($LocalVer -eq "None") {
		Write-Output "`nDownloading and installing TL Mod..."
		Get-TLMod -URI $AssetLink
	}
	elseif ($LocalVer -ne $LatestVer) {
		if ($Config.ForceRedownloadWhenUpdate) {
			Get-TLMod -URI $AssetLink
			return
		}

		if (!(Update-ChangedFiles)) {
			Write-Information "Nothing changed between two versions!`nFalling back to redownload patch..."
			Remove-Mod
			Get-TLMod -URI $AssetLink
		}

		if ($Config.VerifyFilesAfterUpdate) {
			Compare-TLFiles
		}
	}
 	else {
		Write-Output "`nYour PriconeTL version is latest!"
	}
}

$LogFile = "$Env:TEMP\TLUpdater-Logs\$(Get-Date -Format 'yyyy-MM-dd_HH-mm-ss').log"
New-FolderIfNotExist -Path $LogFile
Start-Transcript -Path $LogFile | Out-Null

$GithubAPI = "https://api.github.com/repos/ImaterialC/PriconneRe-TL"
$PriconnePath = Get-GamePath
$UserCfgLocation = "$PriconnePath\TLUpdater\config.json"
$VersionFileLocation = "$PriconnePath\BepInEx\Translation\en\Text\Version.txt"
$Config = Import-UserConfig

if ($Uninstall) {
	Remove-Mod -RemoveConfig
	Stop-Transcript
	return
}
if ($Verify) {
	Compare-TLFiles
}
else {
	Start-CheckForUpdate
}

if ($Config.DMMGamePlayerFastLauncherSupport) {
	Start-DMMFastLauncher
}

Stop-Transcript
