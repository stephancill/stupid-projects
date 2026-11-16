import { execFile } from "node:child_process";
import { homedir } from "node:os";
import { join } from "node:path";
import { type LaunchProps, closeMainWindow, getPreferenceValues, showHUD } from "@raycast/api";
import { z } from "zod";

// Same rule ProjectsBar enforces: no `/` and no leading `.`, so the name can't escape the projects folder.
const nameSchema = z
  .string()
  .trim()
  .regex(/^[A-Za-z0-9][A-Za-z0-9._-]{0,99}$/, {
    message:
      "Project names may only contain letters, digits, '.', '_' and '-', and must start with a letter or digit",
  });

const expandHome = ({ path }: { path: string }) => path.replace(/^~(?=$|\/)/, homedir());

export default async function Command(props: LaunchProps<{ arguments: Arguments.NewProject }>) {
  const parsed = nameSchema.safeParse(props.arguments.name);
  if (!parsed.success) {
    await showHUD(parsed.error.issues[0]?.message ?? "Invalid project name");
    return;
  }

  const { appPath, projectsFolder } = getPreferenceValues<Preferences.NewProject>();
  const binaryPath = join(expandHome({ path: appPath }), "Contents/MacOS/ProjectsBar");
  const projectPath = join(expandHome({ path: projectsFolder }), parsed.data);

  await closeMainWindow();
  // ProjectsBar creates the folder, then waits for the Scotty CLI, which can take up to 30 seconds.
  const failure = await new Promise<string | undefined>((resolve) => {
    execFile(binaryPath, ["--new-project", projectPath], (error, _stdout, stderr) => {
      resolve(error ? String(stderr).trim() || error.message : undefined);
    });
  });
  if (failure) await showHUD(failure);
}
