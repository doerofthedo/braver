# Braver

One command to debloat Brave on a Windows PC: machine-wide policies for every user, plus profile settings for every Brave profile of every Windows user.

Braver is a wrapper around [BraveDebloater](https://github.com/osfv/BraveDebloater). It downloads a pinned, tested BraveDebloater commit, adds a few extra profile settings, finds all Brave profiles on the PC, and runs BraveDebloater for each of them with a fixed selection. Each run shows a preview and asks before it changes anything.

## Quick start

Open PowerShell with **Run as administrator** and run:

```powershell
irm https://raw.githubusercontent.com/doerofthedo/braver/main/braver.ps1 | iex
```

If PowerShell is not elevated, Braver offers to reopen itself as administrator.

Preview only (nothing is written; works without administrator rights, but then it can only read your own profiles):

```powershell
& ([scriptblock]::Create((irm https://raw.githubusercontent.com/doerofthedo/braver/main/braver.ps1))) -PreviewOnly
```

Then restart Brave and open `brave://policy` to check the result.

## What it does

1. Checks for Windows and administrator rights.
2. Downloads BraveDebloater at the pinned commit to `%LOCALAPPDATA%\Braver\tool` and adds Braver's extra features to its copy of `config/policies.json`.
3. Finds the Brave profiles of every Windows user on the PC, including users who are signed out.
4. If Brave is open, asks whether to close it, wait, or skip the profile settings. Policies are applied either way.
5. Shows a preview, asks for confirmation, then applies.

Every apply run writes a backup to `%LOCALAPPDATA%\Braver\backups` and a log to `%LOCALAPPDATA%\Braver\logs`.

## What gets changed

### Policies (machine-wide, locked)

Written to `HKLM\Software\Policies\BraveSoftware\Brave`. They cover every Windows user and every Brave profile, including profiles created later. They show as greyed out in `brave://settings`.

BraveDebloater's `Standard` preset:

| Feature | Effect |
| --- | --- |
| `Rewards` | Removes Brave Rewards, BAT prompts and rewards ads. |
| `Wallet` | Removes Brave Wallet and Web3 entry points. |
| `VPN` | Removes Brave VPN buttons and subscription prompts. |
| `LeoAI` | Disables the Leo AI chat. |
| `News` | Removes Brave News. |
| `Talk` | Removes Brave Talk. |
| `Playlist` | Disables Brave Playlist (the "Add to Playlist" button and sidebar panel). Normal video playback is not affected. |
| `EmailAliases` | Disables Brave Email Aliases. |
| `Speedreader` | Disables Speedreader. |
| `Wayback` | Stops Wayback Machine prompts on missing pages. |
| `BraveTelemetry` | Disables P3A analytics, the stats ping and Web Discovery. |

Plus these BraveDebloater features from its `High` and `Extreme` presets:

| Feature | Effect |
| --- | --- |
| `ChromiumTelemetry` | Turns off Chromium diagnostic reports and URL-keyed data collection. |
| `SearchSuggestions` | Stops sending what you type in the address bar to the search engine. Suggestions from history, bookmarks and open tabs still work. |
| `RemoteSpellcheck` | Turns off enhanced (online) spell check. Local spell check keeps working. |
| `Promotions` | Turns off promotional tabs and feature announcements. |
| `MediaRecommendations` | Turns off media recommendations. |
| `ShoppingList` | Turns off shopping and price tracking. |
| `QRCodeGenerator` | Removes "Create QR code for this page". |
| `GoogleSearchSidePanel` | Turns off the Google search side panel. |

Deliberately left out: Translate, Autofill, network prediction, background mode, Browser Labs, new tab cards, payment method queries, and the privacy protections that Brave already turns on (De-AMP, debouncing, Global Privacy Control, query filtering, language reduction). Selecting the latter would only lock them on.

### Profile settings (per profile, not locked)

Written into each profile's `Preferences` file. Brave must be closed. Users can change these back in `brave://settings`.

| Feature | Setting | Source |
| --- | --- | --- |
| `NewTabBackgrounds` | Hides sponsored new tab images. | BraveDebloater |
| `News`, `Rewards`, `Wallet` | Hides their toolbar buttons where the setting already exists. | BraveDebloater |
| `SidePanelButton` | `brave.show_side_panel_button = false`: hides the side panel toolbar button. | Braver |
| `BookmarksBar` | `brave.show_bookmarks_button = true` and `bookmark_bar.show_on_all_tabs = true`: shows the bookmarks button and the bookmarks bar on all tabs. | Braver |

New profiles created later do not get the profile settings. Run Braver again after adding a profile.

## Braver's extra features

`SidePanelButton` and `BookmarksBar` are not part of BraveDebloater. Braver adds them to its downloaded copy of BraveDebloater's manifest before running it, so BraveDebloater's own preview, backup and restore cover them too. They are profile settings with no policy and no preset, so BraveDebloater only runs them when Braver names them.

They are profile preferences, not policies, on purpose:

- `BookmarkBarEnabled` would lock the bookmarks bar, and there is no policy for the side panel button.
- They were checked against a Brave 157 Windows profile: none of the three is listed under the `PreferenceMACs` key, so Brave does not treat an edit as tampering and reset it.

Not managed: the default search engine and startup pages. Their policies (`DefaultSearchProvider*`, `RestoreOnStartup*`) only apply on Windows PCs joined to Active Directory or Azure AD, or enrolled in Chrome Enterprise Core, and their profile preferences are MAC-protected, so Brave resets them when they are edited directly.

## Options

| Option | Effect |
| --- | --- |
| `-PreviewOnly` | Show what would change and stop. |
| `-Yes` | No questions. Applies without confirmation. If Brave is open, the profile settings are skipped. |
| `-UpstreamRef <ref>` | Use another BraveDebloater branch, tag or commit instead of the pinned one. |
| `-UpstreamRepository <owner/repo>` | Download BraveDebloater from another repository. Default: `osfv/BraveDebloater`. |
| `-LocalToolPath <folder>` | Use a local BraveDebloater folder instead of downloading. It is copied, not changed. |

Pass options with the script block form shown under Quick start, or run a saved copy: `.\braver.ps1 -PreviewOnly`.

## Undo

At the end of each apply, Braver prints a ready-to-paste undo command, for example:

```powershell
& 'C:\Users\<you>\AppData\Local\Braver\tool\Invoke-BraveDebloat.ps1' -UndoFromBackup C:\Users\<you>\AppData\Local\Braver\backups\BraveDebloater-20261112-214100-999.json -ProfileRoot 'C:\Users\<you>\AppData\Local\BraveSoftware\Brave-Browser\User Data' -Apply
```

Close Brave, open PowerShell with **Run as administrator**, and paste it. The command is also in the run's log in `%LOCALAPPDATA%\Braver\logs`. It uses the BraveDebloater copy in `%LOCALAPPDATA%\Braver\tool`, so keep that folder.

## Updating the pinned BraveDebloater

The pin is `$pinnedUpstreamRef` in `braver.ps1`. To move it:

1. Run the tests against the new commit: `powershell -File tests\Test-Braver.ps1 -UpstreamPath <BraveDebloater checkout>`.
2. Preview on a real PC with `-PreviewOnly -LocalToolPath <BraveDebloater checkout>`.
3. Update the pin and its comment.

## Tests

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File tests\Test-Braver.ps1
```

The tests download the pinned commit (or use `-UpstreamPath`), merge the overlay into a temporary copy, check that the merged manifest equals upstream's apart from Braver's entries, and run BraveDebloater against a temporary profile. They never write policies or touch real profiles. The apply step is skipped while Brave is running.

## Credits

All policy work, backups and restores are done by [BraveDebloater](https://github.com/osfv/BraveDebloater) by osfv (MIT).
