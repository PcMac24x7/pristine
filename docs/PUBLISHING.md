# Publishing guide (for the maintainer)

Everything here runs on your Mac, in the folder that contains your `.xcodeproj`.

## 1. One-time setup

1. **Your GitHub username (`PcMac24x7`) and the repository name (`pristine`) are already filled in** everywhere. If you choose a different repository name, search the files for `pristine` and update the URLs.
2. **Share the Xcode scheme** so `release.sh` can find it: Product > Scheme > Manage Schemes, tick **Shared** next to your scheme, then commit the new `xcshareddata` folder.
3. **Check the product name.** The installer expects the app to be called `Pristine.app`. Set the target's **Display Name** (General tab) and **Product Name** (Build Settings) to `Pristine`. `release.sh` also renames the app for you if the product name differs.
4. **Pick a bundle identifier you want to keep** (target > General > Bundle Identifier), for example `com.pcmac24x7.pristine`. It currently comes from your personal team. Changing it later makes macOS treat the app as a new one, so users would have to grant Full Disk Access again.
5. **Install the GitHub CLI** (recommended): `brew install gh`, then `gh auth login`.

## 2. Create the repository and push

**First, make sure Terminal is in the right folder.** Terminal opens in your home folder, and running `git add .` there tries to add your whole Mac user folder. Move into the folder that contains your `.xcodeproj` and check:

```bash
cd "$HOME/Documents/Browser Reset"    # adjust to wherever your project folder is
ls *.xcodeproj                         # must list your project; if it doesn't, you are in the wrong folder
```

Then create the repository, starting **private** so you can look at it before anyone else can:

```bash
git init -b main
git add .
git status --short | head -30          # only your project files should be listed
git commit -m "Initial release"
gh repo create pristine --private --source=. --push
```

Open https://github.com/PcMac24x7/pristine and check that it contains only your project. Then make it public: Settings > General > Danger Zone > Change visibility.

No GitHub CLI? Create an empty **private** repository named `pristine` on github.com, then:

```bash
git remote add origin https://github.com/PcMac24x7/pristine.git
git push -u origin main
```

## 3. Publish a release

```bash
./scripts/release.sh 1.0.0 --publish
```

This builds a universal app (Apple silicon and Intel), packages it as `Pristine-1.0.0.zip` with a `.sha256` file, and creates the GitHub release. Without `--publish` it only builds into `dist/`, so you can test first.

### Signing options

| | Cost | What users see |
|---|---|---|
| **Developer ID + notarization** | Apple Developer Program, $99 per year | Opens with no warnings, and Full Disk Access survives updates. Set `TEAM_ID`, `SIGN_IDENTITY` and `NOTARY_PROFILE` (see the top of `release.sh`). |
| **Ad-hoc (default)** | Free | Works with the Terminal installer, because `curl` downloads are not quarantined. Anyone who downloads the zip in a browser sees a Gatekeeper warning, and Full Disk Access must be re-granted after each update. |

## 4. Test like a new user

On a Mac (or user account) that has never had the app:

```bash
curl -fsSL https://raw.githubusercontent.com/PcMac24x7/pristine/main/install.sh | bash
open -a "Pristine"
```

Check that the app opens, grant Full Disk Access, and run a reset on a test browser profile.

## 5. Optional: Homebrew

1. Create a second public repository named **`homebrew-tap`**.
2. Copy `homebrew/pristine.rb` into it as `Casks/pristine.rb`.
3. Fill in `version`, `sha256` (printed by `release.sh`) and your bundle identifier in the `zap` section.
4. Users then run:
   ```bash
   brew install --cask PcMac24x7/tap/pristine
   ```

Homebrew's main catalog no longer accepts apps that fail Gatekeeper, so this has to be your own tap unless you notarize.

## 6. Shipping an update

1. Commit and push your changes.
2. Run `./scripts/release.sh 1.1.0 --publish`.
3. If you use Homebrew, update `version` and `sha256` in the cask.

Anyone who runs the install command again gets the newest version, and the app is replaced in place.
