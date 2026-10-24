# Homebrew cask template. After a release, fill in version and sha256 (make-dmg.sh prints it)
# and open a pull request at Homebrew/homebrew-cask, or keep it in your own tap.
cask "starnotch" do
  version "0.0.0"
  sha256 "REPLACE_WITH_SHA256_OF_THE_DMG"

  url "https://github.com/juliokoelle/starnotch/releases/download/v#{version}/starnotch-#{version}.dmg"
  name "Starnotch"
  desc "Turns the MacBook notch into an island for agents, calendar and music"
  homepage "https://github.com/juliokoelle/starnotch"

  livecheck do
    url :url
    strategy :github_latest
  end

  auto_updates true
  depends_on macos: ">= :sonoma"

  app "Starnotch.app"

  uninstall quit: "app.starnotch.mac"

  zap trash: [
    "~/Library/Application Support/Starnotch",
    "~/Library/Preferences/app.starnotch.mac.plist",
  ]
end
