#!/usr/bin/env bash
set -euo pipefail

# Builds extensions/stupid-projects and copies it into Tinycast's extensions directory, mirroring what
# Settings → Extensions → Add from folder does (ExtensionCatalog.install): package.json, the built
# command bundles and assets/. The installed manifest's `appPath` preference defaults to this repo's
# built StupidProjects.app. `--projects-folder <path>` sets the default folder for New Project (otherwise
# ~/Projects); a value set in Tinycast's settings still takes precedence.
#
# Usage: scripts/install-tinycast-extension.sh [--projects-folder <path>]

projects_folder=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --projects-folder)
      projects_folder="${2:?--projects-folder needs a path}"
      shift 2
      ;;
    *)
      echo "Unknown argument: $1" >&2
      exit 1
      ;;
  esac
done

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
extension_dir="$repo_dir/extensions/stupid-projects"
app_path="$repo_dir/.build/StupidProjects.app"
tinycast_support="$HOME/Library/Application Support/com.abueammar.tinycast"
destination="$tinycast_support/extensions/stupid-projects"

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
# ray externalises dependencies shared by several commands into dist/node_modules.
if [[ -d "$extension_dir/dist/node_modules" ]]; then
  cp -R "$extension_dir/dist/node_modules" "$destination/node_modules"
fi
APP_PATH="$app_path" PROJECTS_FOLDER="$projects_folder" bun -e '
const manifest = await Bun.file(`${process.argv[1]}/package.json`).json();
const appPath = manifest.preferences.find((preference) => preference.name === "appPath");
if (!appPath) throw new Error("appPath preference missing from manifest");
appPath.default = process.env.APP_PATH;
if (process.env.PROJECTS_FOLDER) {
  const command = manifest.commands.find((command) => command.name === "new-project");
  const projectsFolder = command?.preferences?.find((preference) => preference.name === "projectsFolder");
  if (!projectsFolder) throw new Error("projectsFolder preference missing from manifest");
  projectsFolder.default = process.env.PROJECTS_FOLDER;
}
await Bun.write(`${process.argv[2]}/package.json`, JSON.stringify(manifest, null, 2));
' "$extension_dir/dist" "$destination"

echo "Installed $destination"
echo "Tinycast picks up new installs at launch or when Settings → Extensions opens; updated code applies on the next run."
