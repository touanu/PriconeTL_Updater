# PriconeTL_Updater

[![made-with-powershell](https://img.shields.io/badge/PowerShell-1f425f?logo=Powershell)](https://microsoft.com/PowerShell)

A script to automate [PriconeTL](https://github.com/ImaterialC/PriconeTL) installation

## How to use

### Create shortcut

Right click anywhere on your Windows desktop > New > Shortcut

Location of the item:

```powershell
powershell irm https://bit.ly/3RjFnwE | iex
```

![example](https://cdn.discordapp.com/attachments/815500106396729374/1081231749499068487/image.png)

After that, you can use this shortcut to update PriconeTL.

### Run directly from powershell

Open Powershell and type the following command:

```powershell
irm https://bit.ly/3RjFnwE | iex
```

or download code from [here](https://github.com/touanu/PriconeTL_Updater/archive/main.zip)

## Uninstallation

You can uninstall PriconeTL with [uninstall config](#configuration) or `-Uninstall` command-line argument

**This will also remove everything related to BepInEx!**

## Open game without DMM Game Launcher

Install [fa0311/DMMGamePlayerFastLauncher](https://github.com/fa0311/DMMGamePlayerFastLauncher) or put DMMGamePlayerFastLauncher.exe file in game folder. Script will detect exe file and run game via this FastLauncher

If the script doesn't detect executable file or you have it in different folder, you can [set a custom path in config](#configuration)

## Configuration

Config file is auto-generated and located in `(Your priconner folder)\TLUpdater\config.json`

| Configuration                    | Type   | Description                                                                        |
| -------------------------------- | ------ | ---------------------------------------------------------------------------------- |
| CustomDMMGPFLPath                | String | Custom path for DMMGamePlayerFastLauncher.exe                                      |
| VerifyFilesAfterUpdate           | Bool   | Check if any files are missing or redundant after updating to new version          |
| TLVersion                        | String | Contain version of PriconeTL to check update, auto-generated                       |
| ForceRedownloadWhenUpdate        | Bool   | Redownload latest release instead of only downloading changed translation files    |
| Uninstall                        | Bool   | Remove all PriconeTL and **BepInEx** files                                         |
| VerifyIgnoreFiles                | Array  | Avoid updater check, download or delete those listed files                         |
| DMMGamePlayerFastLauncherSupport | Bool   | Use [DMMGamePlayerFastLauncher](#open-game-without-dmm-game-launcher) to open game |

Default config.json:

```json
{
    "CustomDMMGPFLPath":  "",
    "VerifyFilesAfterUpdate":  true,
    "TLVersion":  "",
    "ForceRedownloadWhenUpdate":  false,
    "Uninstall":  false,
    "VerifyIgnoreFiles":  [
                              "Translation/en/Text/_AutoGeneratedTranslations.txt",
                              "Translation/en/Text/_Postprocessors.txt",
                              "Translation/en/Text/_Preprocessors.txt",
                              "Translation/en/Text/_Substitutions.txt",
                              "Translation/id/Text/_AutoGeneratedTranslations.txt",
                              "Translation/id/Text/_Postprocessors.txt",
                              "Translation/id/Text/_Preprocessors.txt",
                              "Translation/id/Text/_Substitutions.txt"
                          ],
    "DMMGamePlayerFastLauncherSupport":  true
}
```

## Arguments

You can pass those parameters to script via command line
To pass parameters to remote script, [create a scriptblock from the script file and execute that](https://stackoverflow.com/a/63157192):
`& ([scriptblock]::Create((irm https://bit.ly/3RjFnwE))) -ArgumentHere`

| Argument         | Alias | Type | Default | Description                                                    |
| ---------------- | ----- | ---- | ------- | -------------------------------------------------------------- |
| -Uninstall       | -U    | Bool | False   | Remove all PriconeTL and **BepInEx** files                     |
| -ForceRedownload | -FR   | Bool | False   | Uninstall and redownload latest PriconeTL release              |
| -Verify          | -V    | Bool | False   | Only check, download any missing files, delete redundant files |
