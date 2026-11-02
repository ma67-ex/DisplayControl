# Draft cask. Not published. Fill in the url and sha256 from a real release.
cask "displaycontrol" do
  version "1.0.0"
  sha256 "REPLACE_WITH_SHA256_OF_DisplayControl.zip"

  url "https://github.com/OWNER/DisplayControl/releases/download/v#{version}/DisplayControl.zip"
  name "DisplayControl"
  desc "Menu bar app to control external monitor brightness, contrast, volume and input"
  homepage "https://github.com/OWNER/DisplayControl"

  depends_on macos: ">= :ventura"

  app "DisplayControl.app"
  binary "#{appdir}/DisplayControl.app/Contents/Resources/bin/displaycontrol"

  zap trash: "~/Library/Application Support/DisplayControl"
end
