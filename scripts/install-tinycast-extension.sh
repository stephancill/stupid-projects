#!/usr/bin/env bash
set -euo pipefail

# Builds extensions/projects-bar and copies it into Tinycast's extensions directory, mirroring what
# Settings → Extensions → Add from folder does (ExtensionCatalog.install): package.json, the built
# command bundles and assets/. The installed manifest's `appPath` preference defaults to this repo's
# built ProjectsBar.app.

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
extension_dir="$repo_dir/extensions/projects-bar"
app_path="$repo_dir/.build/ProjectsBar.app"
tinycast_support="$HOME/Library/Application Support/com.tinycast.app"
destination="$tinycast_support/extensions/projects-bar"

if [[ ! -d "$tinycast_support" ]]; then
  echo "Tinycast data directory not found: $tinycast_support" >&2
  exit 1
fi

if [[ ! -d "$app_path" ]]; then
  "$repo_dir/scripts/build-app.sh"
fi

(cd "$extension_dir" && bun install --frozen-lockfile && bun run build)

rm -rf "$destination"
mkdir -p "$destination"
cp -R "$extension_dir/dist/assets" "$destination/assets"
find "$extension_dir/dist" -maxdepth 1 -name '*.js' -exec cp {} "$destination/" \;
APP_PATH="$app_path" bun -e '
const manifest = await Bun.file(`${process.argv[1]}/package.json`).json();
const appPath = manifest.preferences.find((preference) => preference.name === "appPath");
if (!appPath) throw new Error("appPath preference missing from manifest");
appPath.default = process.env.APP_PATH;
await Bun.write(`${process.argv[2]}/package.json`, JSON.stringify(manifest, null, 2));
' "$extension_dir/dist" "$destination"

echo "Installed $destination"
echo "Tinycast picks up new installs at launch or when Settings → Extensions opens; updated code applies on the next run."
