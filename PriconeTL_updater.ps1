$CfgFileLocation = $Env:APPDATA + "\dmmgameplayer5\dmmgame.cnf"
$LatestRelease = "https://api.github.com/repos/ImaterialC/PriconeTL/releases/latest"

Clear-Host

function Get-GamePath {
	Param(
		[parameter()][System.String]$CfgFile
	)
	try{
		$CfgFileContent = Get-Content $CfgFile | ConvertFrom-Json
		$DetailContent = $CfgFileContent.contents | Where-Object {$_.productId -eq "priconner"}
		$PriconnePath = $DetailContent.detail.path
	}
	catch{
		Write-Verbose $_.Exception
		Write-Error "Cannot get game path!"
		break
	}
	if($PriconnePath){
		Write-Host "Found priconner in"$PriconnePath
	} else{
		Write-Error "Cannot find the game path! Did you install Priconne from DMM Game?"
		break
	}
	return $PriconnePath
}

function Get-LocalVersion {
	Param (
    [parameter()][System.String]$VersionFile
    )
	
	$LocalVersion = Get-Content -Raw -Path "$VersionFile" -Erroraction 'SilentlyContinue'
	
	if(!($LocalVersion)){
		$LocalVersion = "None"
	}
	
	return $LocalVersion
}

function Get-LatestRelease {
    Param (
    [parameter()][System.String]$URI
    )
    
    try{
        $Response = Invoke-WebRequest -Method "GET" -URI $URI -UseBasicParsing
		$Json = $Response.Content | ConvertFrom-Json
		$Version = $Json | Select-Object -expand name
		$AssetsLink = $Json | Select-Object -ExpandProperty assets | Select-Object -expand browser_download_url
    }
    catch{
        Write-Verbose $_.Exception
        Write-Error "Cannot get latest release info!"
        break
    }

    if($Response.StatusCode -ne 200){
        Write-Error "Status Code wasn't 200"
        break
    }

    return $Version.SubString($Version.Length-10), $AssetsLink
}

function Remove-OldMod {
	Param(
		[parameter()][System.String]$GamePath
	)
	$p = Get-Process "PrincessConnectReDive" -Erroraction 'SilentlyContinue'

	if ($p) {
		Write-Host "`nPriconne is still running and will be killed to remove old files!`n"
		Timeout /NoBreak 5
		Stop-Process $p
	}
	try{
		Remove-Item -Path "$($GamePath)\BepInEx" -Recurse -Erroraction 'Stop'
		Remove-Item -Path "$($GamePath)\PriconeTL_Updater.bat" -Erroraction 'SilentlyContinue'
	}
	catch [System.UnauthorizedAccessException] {
		Write-Host "Requesting admin permissions to delete files..."
		$command = "Remove-Item -Path $($GamePath)\BepInEx -Recurse -Erroraction 'SilentlyContinue'; Remove-Item -Path $($GamePath)\PriconeTL_Updater.bat -Erroraction 'SilentlyContinue'"
		Start-Process powershell -Verb runAs -WorkingDirectory $GamePath -WindowStyle hidden -ArgumentList "-Command $($command)"
	}
	catch{
		Write-Verbose $_.Exception
		Write-Error "Error(s) occurred while removing old BepInEx folder"
		break
	}
}

function Get-TLMod {
	Param(
	[parameter()][System.String]$LinkZip,
	[parameter()][System.String]$ZipPath,
	[parameter()][System.String]$ExtractPath
	)
	try{
		Write-Host "Downloading compressed mod files..."
		Write-Host "Assets File:"$LinkZip"`n"
		Invoke-WebRequest $LinkZip -OutFile $ZipPath
		Write-Host "Extracting mod files to game folder..."
		Expand-Archive -Path $ZipPath -DestinationPath $ExtractPath -Force
		Remove-Item -Path $ZipPath
	}
	catch{
        Write-Verbose $_.Exception
        Write-Error "An error was occurred while trying to install!"
        break
	}
}

if(Test-Path -Path $CfgFileLocation){
	$PriconnePath = Get-GamePath -CfgFile $CfgFileLocation
	$VersionFile = $PriconnePath + "\Version.txt"
	$LocalVer = Get-LocalVersion -VersionFile $VersionFile
} else {
	Write-Error "Cannot find DMM Game config file`nDid you install DMM Game?"
	break
}

Write-Host "`nChecking for update..."
Write-Host "Current Version:"$LocalVer
$LatestVer = Get-LatestRelease -URI $LatestRelease
Write-Host "Latest Version:"$LatestVer[0]

if($LatestVer[0] -eq $LocalVer){
	Write-Host "`nYour PriconeTL version is latest!"
	break
} elseif((Test-Path -Path $PriconnePath\BepInEx\Translation) -or ($LocalVer -ne "None")) {
	Write-Host "`nUpdating TL Mod..."
	Remove-OldMod -GamePath $PriconnePath
} else{
	Write-Host "`nDownloading and installing TL Mod..."
}

Get-TLMod -LinkZip $LatestVer[1] -ZipPath "$Env:TEMP\Pricone.UI.EN.DMM.zip" -ExtractPath $PriconnePath

Write-Host "Done!`n"
