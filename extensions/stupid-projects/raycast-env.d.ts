/// <reference types="@raycast/api">

/* 🚧 🚧 🚧
 * This file is auto-generated from the extension's manifest.
 * Do not modify manually. Instead, update the `package.json` file.
 * 🚧 🚧 🚧 */

/* eslint-disable @typescript-eslint/ban-types */

type ExtensionPreferences = {
  /** stupid projects app - Path to StupidProjects.app, e.g. <repo>/.build/StupidProjects.app. A leading ~ is expanded. */
  "appPath": string
}

/** Preferences accessible in all the extension's commands */
declare type Preferences = ExtensionPreferences

declare namespace Preferences {
  /** Preferences accessible in the `open-project` command */
  export type OpenProject = ExtensionPreferences & {}
  /** Preferences accessible in the `new-project` command */
  export type NewProject = ExtensionPreferences & {
  /** Projects Folder - Existing folder that new projects are created in. A leading ~ is expanded. */
  "projectsFolder": string
}
}

declare namespace Arguments {
  /** Arguments passed to the `open-project` command */
  export type OpenProject = {}
  /** Arguments passed to the `new-project` command */
  export type NewProject = {
  /** Project name */
  "name": string
}
}

