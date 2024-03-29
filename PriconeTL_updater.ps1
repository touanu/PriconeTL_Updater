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
	Write-Information "Requesting admin privilege..."
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
	$CfgFileContent = Get-Content "$Env:APPDATA\dmmgameplayer5\dmmgame.cnf" -ErrorAction SilentlyContinue | ConvertFrom-Json
	if (!$CfgFileContent) {
		Write-Error "Cannot find the game path!`nDid you install Priconne from DMM Game?"
	}

	$PriconneContent = $CfgFileContent.contents | Where-Object productId -eq "priconner"
	$PriconnePath = $PriconneContent.detail.path

	Write-Information "Found priconner in $PriconnePath"
	return $PriconnePath
}

function Get-LocalVersion {
	$RawVersionFile = Get-Content -Raw -Path $VersionFileLocation -ErrorAction SilentlyContinue

	if (!$RawVersionFile) {
		return "None"
	}

	$RegexFind = $RawVersionFile | Select-String '\d{8}\w?'
	$LocalVersion = $RegexFind.Matches.Value
	Write-Information "Current Version: $LocalVersion"

	return $LocalVersion
}

function Get-LatestRelease {
	try {
		$Response = Invoke-RestMethod "$GithubAPI/releases/latest"
		$Version = $Response.tag_name
		$AssetLink = $Response.assets.browser_download_url
		Write-Information "Latest Version: $Version"
	}
	catch {
		Write-Error $_.Exception
		exit
	}

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
			Write-Information "Removing $file"
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

function Save-NewVersion {
	$OldVersionContent = Get-Content $VersionFileLocation
	$NewVersionContent = $OldVersionContent.Replace("Pre-release", $LatestVer).Replace($LocalVer, $LatestVer)
	Set-Content -Path $VersionFileLocation -Value $NewVersionContent
}

function Get-FileFromRepo {
	param (
		[string]$FileName
	)
	$URI = "https://raw.githubusercontent.com/ImaterialC/PriconneRe-TL/master/src/$FileName"
	$Destination = "$PriconnePath/$FileName"

	New-FolderIfNotExist -Path $Destination
	Start-BitsTransfer -Source $URI -Destination $Destination -Asynchronous -ErrorAction Stop | Out-Null
}

function Merge-RepoFiles {
	param (
		[string]$Status,
		[string]$FileName,
		[string]$PreFileName
	)
	Write-Verbose "Status: $Status, FileName: $FileName, PreFileName: $PreFileName"
	$DestinationPath = $PriconnePath + "\" + $FileName.Replace("/","\")

	switch ($Status) {
		{ $_ -eq "added" -or $_ -eq "modified" -or $_ -eq "=>"} {
			Get-FileFromRepo -FileName $FileName
			Write-Information "added: $FileName"
		}
		{ $_ -eq "removed" -or $_ -eq "<="} {
			if (!(Test-Path -LiteralPath $DestinationPath)) {
				Write-Information "not found: $FileName"
				return
			}

			Remove-Item -LiteralPath $DestinationPath -Recurse -ErrorAction Stop
			Write-Information "removed: $FileName"
		}
		"renamed" {
			$PreviousPath = Join-Path -Path $PriconnePath -ChildPath $PreFileName
			if (!(Test-Path $PreviousPath)) {
				Write-Verbose "Cannot find the needed file! Download it from repo..."
				Get-FileFromRepo -FileName $FileName
				Write-Information "added: $FileName"
			}

			New-FolderIfNotExist -Path $DestinationPath
			Move-Item -Path $PreviousPath -Destination $DestinationPath
			Write-Information "renamed: $PreFileName -> $FileName"
		}
	}
}

function Update-ChangedFiles {
	Write-Information "Updating changed files...`n"

	$URI = "$GithubAPI/compare/$LocalVer...$LatestVer"
	Write-Verbose "Compare URI: $URI"
	$ChangedFiles = (Invoke-RestMethod -URI $URI).files

	if ($ChangedFiles.Count -eq 0 -or $ChangedFiles.Count -ge 299) {
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

	return $true
}

function Find-DMMFastLauncherFileName {
	param (
		[string]$Path
	)

	if ($Config.DMMGPFLShortcutFileName) {
		return $Config.DMMGPFLShortcutFileName
	}

	$ShortcutPath = "$Path\data\shortcut"
	Write-Verbose "DMMFL Data path: $ShortcutPath"
	Get-ChildItem $ShortcutPath | ForEach-Object {
		$Shortcut = Get-Content $_.FullName | ConvertFrom-Json
		$IsPriconnerShortcut = $Shortcut.product_id -eq "priconner"

		if (!$IsPriconnerShortcut) {
			continue
		}

		$PriconnerShortcut = (Split-Path $_.FullName -Leaf).Replace(".json","")
		return $PriconnerShortcut
	}
}

function Start-DMMFastLauncher {
	$DMMFastLauncher = @(
		$Config.CustomDMMGPFLPath,
		"$Env:APPDATA\DMMGamePlayerFastLauncher"
	)

	foreach ($path in $DMMFastLauncher) {
		Write-Verbose "Checking $path\DMMGamePlayerFastLauncher.exe"
		$IsDMMGPFLExist = Test-Path -Path "$path\DMMGamePlayerFastLauncher.exe" -PathType Leaf

		if (!$IsDMMGPFLExist) {
			Write-Verbose "Not Exist!"
			continue
		}

		Write-Verbose "Found DMMGamePlayerFastLauncher in $path!"
		$FileName = Find-DMMFastLauncherFileName $path

		if (!$FileName) {
			Write-Error "Priconner shortcut doesn't exist!`nOpen DMMGamePlayerFastLauncher to create a new shortcut"
			return
		}

		Write-Information "Starting PriconneR game..."
		Start-Process -FilePath "$path\DMMGamePlayerFastLauncher.exe" -WorkingDirectory "$path" -ArgumentList "$FileName --type game" -Verb RunAs
		return
	}
}

function Import-UserConfig {
	$Config = @{
		"DMMGamePlayerFastLauncherSupport" = $true
		"DMMGPFLShortcutFileName" 	       = ""
		"CustomDMMGPFLPath"                = ""
		"ForceRedownloadWhenUpdate"        = $false
		"VerifyFilesAfterUpdate"           = $true
		"VerifyIgnoreFiles"                = @(
			"BepInEx/Translation/en/Text/_AutoGeneratedTranslations.txt",
			"BepInEx/Translation/en/Text/_Postprocessors.txt",
			"BepInEx/Translation/en/Text/_Substitutions.txt"
		)
	}

	$ConfigFileExist = Test-Path $UserCfgLocation
	if (!$ConfigFileExist) {
		New-FolderIfNotExist -Path $UserCfgLocation
	}
	else {
		$UserConfig = Get-Content $UserCfgLocation | ConvertFrom-Json
		$Names = $UserConfig.PSOBject.Properties.Name

		foreach ($name in $Names) {
			Write-Verbose "Imported Config: $name = $($UserConfig.$name)"
			$Config.$name = $UserConfig.$name
		}
	}

	$Config | ConvertTo-Json | Out-File $UserCfgLocation -Force
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
		$IsSourceFile = ($_.path -match "^src/.+") -and ($_.type -eq "blob")
		$Path = $_.path.Replace("src/","")
		if ($IsSourceFile -and $Path -notin $Config.VerifyIgnoreFiles) {
			$Path
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
	$LocalVer = Get-LocalVersion
	$LatestVer, $AssetLink = Get-LatestRelease

	if ($ForceRedownload) {
		Remove-Mod
		Get-TLMod -URI $AssetLink
		return
	}
	Write-Information "`nChecking for update..."
	if ($LocalVer -eq "None") {
		Write-Information "`nDownloading and installing TL Mod..."
		Get-TLMod -URI $AssetLink
		return
	}
	if ($LocalVer -eq $LatestVer) {
		Write-Information "`nYour PriconeTL version is latest!"
		return
	}
	if ($Config.ForceRedownloadWhenUpdate) {
		Get-TLMod -URI $AssetLink
		return
	}

	if (!(Update-ChangedFiles)) {
		Write-Information "Redownloading patch..."
		Remove-Mod
		Get-TLMod -URI $AssetLink
	}
	if ($Config.VerifyFilesAfterUpdate) {
		Compare-TLFiles
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
