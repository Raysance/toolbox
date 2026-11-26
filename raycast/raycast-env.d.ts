/// <reference types="@raycast/api">

/* 🚧 🚧 🚧
 * This file is auto-generated from the extension's manifest.
 * Do not modify manually. Instead, update the `package.json` file.
 * 🚧 🚧 🚧 */

/* eslint-disable @typescript-eslint/ban-types */

type ExtensionPreferences = {
  /** Connection - Direct or proxy connection. Changes apply the next time an InboxCode command runs. */
  "connectionMode": "direct" | "system" | "socks5" | "http",
  /** Proxy Host - Used only for SOCKS5 or HTTP proxy connections. */
  "proxyHost": string,
  /** Proxy Port - Used only for SOCKS5 or HTTP proxy connections. */
  "proxyPort": string
}

/** Preferences accessible in all the extension's commands */
declare type Preferences = ExtensionPreferences

declare namespace Preferences {
  /** Preferences accessible in the `codes` command */
  export type Codes = ExtensionPreferences & {}
  /** Preferences accessible in the `accounts` command */
  export type Accounts = ExtensionPreferences & {}
}

declare namespace Arguments {
  /** Arguments passed to the `codes` command */
  export type Codes = {}
  /** Arguments passed to the `accounts` command */
  export type Accounts = {}
}

