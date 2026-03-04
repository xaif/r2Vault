cask "r2vault" do
  version :latest
  sha256 :no_check

  url "https://github.com/xaif/r2Vault/releases/latest/download/r2Vault.dmg"
  name "R2Vault"
  desc "Native macOS client for Cloudflare R2 storage"
  homepage "https://github.com/xaif/r2Vault"

  depends_on macos: ">= :sequoia"

  app "R2Vault.app"

  postflight do
    system_command "/usr/bin/xattr",
                   args: ["-dr", "com.apple.quarantine", "#{appdir}/R2Vault.app"],
                   sudo: false
  end

  zap trash: [
    "~/Library/Preferences/fiaxe.Fiaxe.plist",
    "~/Library/Caches/fiaxe.Fiaxe",
  ]
end
