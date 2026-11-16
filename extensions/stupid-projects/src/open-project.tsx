import { execFile, execFileSync } from "node:child_process";
import { homedir } from "node:os";
import { join } from "node:path";
import {
  Action,
  ActionPanel,
  Icon,
  List,
  closeMainWindow,
  getPreferenceValues,
  showHUD,
} from "@raycast/api";
import { usePromise } from "@raycast/utils";
import { z } from "zod";

const projectsSchema = z.array(
  z.object({
    path: z.string(),
    name: z.string(),
    active: z.boolean(),
    lastOpenedAt: z.number().optional(),
  }),
);

type Project = z.infer<typeof projectsSchema>[number];

const getBinaryPath = () => {
  const { appPath } = getPreferenceValues<{ appPath: string }>();
  const expanded = appPath.replace(/^~(?=$|\/)/, homedir());
  return join(expanded, "Contents/MacOS/StupidProjects");
};

const listProjects = async () => {
  const stdout = execFileSync(getBinaryPath(), ["--list-json"], { encoding: "utf8" });
  return projectsSchema.parse(JSON.parse(stdout));
};

const openProject = async ({ project }: { project: Project }) => {
  await closeMainWindow();
  // The Scotty CLI can wait up to 30 seconds for Scotty to reply, so this runs asynchronously.
  const failure = await new Promise<string | undefined>((resolve) => {
    execFile(getBinaryPath(), ["--open", project.path], (error, _stdout, stderr) => {
      resolve(error ? String(stderr).trim() || error.message : undefined);
    });
  });
  if (failure) await showHUD(`Failed to open ${project.name}: ${failure}`);
};

const relativeTime = ({ timestamp }: { timestamp: number }) => {
  const seconds = Math.round((Date.now() - timestamp) / 1000);
  if (seconds < 60) return `${seconds}s`;
  const minutes = Math.floor(seconds / 60);
  if (minutes < 60) return `${minutes}m`;
  const hours = Math.floor(minutes / 60);
  if (hours < 24) return `${hours}h`;
  const days = Math.floor(hours / 24);
  if (days < 7) return `${days}d`;
  return `${Math.floor(days / 7)}w`;
};

export default function Command() {
  const { data, isLoading, error } = usePromise(listProjects);

  return (
    <List isLoading={isLoading} searchBarPlaceholder="Search projects">
      {error ? (
        <List.EmptyView
          icon={Icon.Warning}
          title="Failed to load projects"
          description={error.message}
        />
      ) : null}
      {data?.map((project) => (
        <List.Item
          key={project.path}
          icon={project.active ? Icon.CircleFilled : Icon.Circle}
          title={project.name}
          subtitle={project.path.replace(homedir(), "~")}
          keywords={[project.path]}
          accessories={
            project.lastOpenedAt === undefined
              ? []
              : [{ text: relativeTime({ timestamp: project.lastOpenedAt }) }]
          }
          actions={
            <ActionPanel>
              <Action
                title="Open in Scotty"
                icon={Icon.Terminal}
                onAction={() => openProject({ project })}
              />
              <Action.ShowInFinder path={project.path} />
              <Action.CopyToClipboard title="Copy Path" content={project.path} />
            </ActionPanel>
          }
        />
      ))}
    </List>
  );
}
