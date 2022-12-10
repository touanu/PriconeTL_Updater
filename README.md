# PriconeTL_Updater

[![made-with-powershell](https://img.shields.io/badge/PowerShell-1f425f?logo=Powershell)](https://microsoft.com/PowerShell)
A script to automate [PriconeTL](https://github.com/ImaterialC/PriconeTL) installation

## How to use

Simply open Powershell and type the following command:
`iwr -useb https://bit.ly/3RjFnwE|iex`
or download code from [here](https://github.com/touanu/PriconeTL_Updater/archive/main.zip)

If PermissionDenied error is occured, run your powershell as administrator

## Open game without DMM Game Launcher

Install [fa0311/DMMGamePlayerFastLauncher](https://github.com/fa0311/DMMGamePlayerFastLauncher) or put  DMMGamePlayerFastLauncher.exe file in game folder. Script will detect exe file and run game via this FastLauncher

## Configuration

Config file is located in `(Your priconner folder)\TLUpdater\config.json`

Default config.json:

```json
{
    "DMMGamePlayerFastLauncherSupport":  true,
    "CustomDMMGPFLPath":  "",
    "TLVersion":  "",
    "ForceRedownloadWhenUpdate":  false,
    "CustomDMMGPFLArguments":  ""
}
```
