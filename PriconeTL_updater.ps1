$CfgFileLocation = $Env:APPDATA + "\dmmgameplayer5\dmmgame.cnf"
$Global:GithubAPI = "https://api.github.com/repos/ImaterialC/PriconeTL/releases/latest"

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
		[System.String]$VersionFile
	)
	try {
		$LocalVersion = (Get-Content -Raw -Path $VersionFile -ErrorAction Stop).Replace(".","")
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
		$Response = Invoke-WebRequest $GithubAPI
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
		#Catch PermissionDenied error
		if (Test-Path -Path "$PriconnePath\BepInEx" -PathType Container -ErrorAction SilentlyContinue) {
			Remove-Item -Path "$PriconnePath\BepInEx" -Recurse -Erroraction 'Stop'
		}
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


if (Test-Path -Path $CfgFileLocation) {
	$Global:PriconnePath = Get-GamePath -CfgFile $CfgFileLocation
	$VersionFile = $PriconnePath + "\Version.txt"
	$LocalVer = Get-LocalVersion -VersionFile $VersionFile
}
else {
	Write-Error "Cannot find DMM Game config file`nDid you install DMM Game?"
	break
}

Write-Host "`nChecking for update..."
Write-Host "Current Version: $LocalVer"
$LatestVer = Get-LatestRelease
Write-Host "Latest Version: $($LatestVer[0])"

if ($LatestVer[0] -eq $LocalVer) {
	Write-Host "`nYour PriconeTL version is latest!"
}
elseif ($LocalVer -ne "None") {
	Write-Host "`nUpdating TL Mod..."
	Remove-OldMod
	Get-TLMod -LinkZip $LatestVer[1] -ZipPath "$Env:TEMP\Pricone.UI.EN.DMM.zip"
	Write-Host "`nDone!"
}
else {
	Write-Host "`nDownloading and installing TL Mod..."
	Get-TLMod -LinkZip $LatestVer[1] -ZipPath "$Env:TEMP\Pricone.UI.EN.DMM.zip"
	Write-Host "`nDone!"
}

#Self-update Version.txt
$LatestVer[0] | Out-File "$PriconnePath\Version.txt" -NoNewline

$DMMFastLauncher = @(
	"$Env:APPDATA\DMMGamePlayerFastLauncher",
	"$PriconnePath"
)

foreach ($path in $DMMFastLauncher) {
	Write-Verbose "Checking $path\DMMGamePlayerFastLauncher.exe"
	if (Test-Path -Path "$path\DMMGamePlayerFastLauncher.exe" -PathType Leaf -ErrorAction SilentlyContinue) {
		Write-Host "Starting PriconneR game..."
		Start-Process -FilePath "$path\DMMGamePlayerFastLauncher.exe" -WorkingDirectory "$path" -ArgumentList "priconner"
		break
	}
	Write-Verbose "Not Exist!"
}
