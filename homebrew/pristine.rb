# Put this file in a separate GitHub repository named "homebrew-tap", at:
#   Casks/pristine.rb
# Then people can install with:
#   brew install --cask pcmac24x7/tap/pristine
#
# After each release, update `version` and `sha256` (scripts/release.sh prints the checksum).

cask "pristine" do
  version "1.0.0"
  sha256 "REPLACE_WITH_SHA256_PRINTED_BY_RELEASE_SCRIPT"

  url "https://github.com/PcMac24x7/pristine/releases/download/v#{version}/Pristine-#{version}.zip"
  name "Pristine"
  desc "Reset browsers, find large files, remove unused apps and monitor activity"
  homepage "https://github.com/PcMac24x7/pristine"

  livecheck do
    url :url
    strategy :github_latest
  end

  depends_on macos: ">= :sonoma"

  app "Pristine.app"

  # Homebrew no longer clears the download quarantine flag for you. Without this step,
  # Gatekeeper blocks any release that has not been notarized. If you notarize your
  # releases, you can delete this block.
  postflight do
    system_command "/usr/bin/xattr",
                   args: ["-dr", "com.apple.quarantine", "#{appdir}/Pristine.app"]
  end

  # Replace with your app's bundle identifier (Xcode > target > General > Bundle Identifier).
  zap trash: [
    "~/Library/Preferences/YOUR.BUNDLE.IDENTIFIER.plist",
    "~/Library/Saved Application State/YOUR.BUNDLE.IDENTIFIER.savedState",
  ]

  caveats <<~EOS
    Pristine needs Full Disk Access to clear Safari and other browsers' data:
      System Settings > Privacy & Security > Full Disk Access > turn on "Pristine"
    Then quit and reopen the app.
  EOS
end
