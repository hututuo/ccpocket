import { stdin, stdout } from "node:process";
import { FileMutationAuthStore } from "./file-mutation-auth.js";

export interface FileAccessStatus {
  passwordConfigured: boolean;
  biometricDeviceCount: number;
}

export async function setFileAccessPassword(
  options: {
    password?: string;
    store?: FileMutationAuthStore;
  } = {},
): Promise<void> {
  const store = options.store ?? new FileMutationAuthStore();
  const password =
    options.password ??
    (await readHiddenPassword("New file-access password: "));
  const confirmation =
    options.password ??
    (await readHiddenPassword("Confirm file-access password: "));
  if (password !== confirmation) {
    throw new Error("Passwords do not match");
  }
  await store.setPassword(password);
}

export async function readFileAccessStatus(
  store = new FileMutationAuthStore(),
): Promise<FileAccessStatus> {
  const state = await store.status();
  // The public status intentionally discloses no verifier or device identity.
  return {
    passwordConfigured: state.passwordConfigured,
    biometricDeviceCount: await store.enrolledDeviceCount(),
  };
}

export async function readPasswordFromStdin(): Promise<string> {
  if (stdin.isTTY) {
    throw new Error(
      "--password-stdin expects a redirected standard input stream",
    );
  }
  let value = "";
  for await (const chunk of stdin) {
    value += chunk.toString();
    if (value.length > 1024) {
      throw new Error("Password input is too large");
    }
  }
  return value.replace(/[\r\n]+$/u, "");
}

async function readHiddenPassword(prompt: string): Promise<string> {
  if (!stdin.isTTY || !stdout.isTTY || !stdin.setRawMode) {
    throw new Error(
      "An interactive terminal is required; use --password-stdin for automation",
    );
  }
  stdout.write(prompt);
  stdin.setRawMode(true);
  stdin.resume();
  return new Promise<string>((resolve, reject) => {
    let value = "";
    const cleanup = (): void => {
      stdin.off("data", onData);
      stdin.setRawMode?.(false);
      stdin.pause();
      stdout.write("\n");
    };
    const onData = (chunk: Buffer | string): void => {
      const text = chunk.toString("utf8");
      for (const character of text) {
        if (character === "\u0003") {
          cleanup();
          reject(new Error("Password entry cancelled"));
          return;
        }
        if (character === "\r" || character === "\n") {
          cleanup();
          resolve(value);
          return;
        }
        if (character === "\u007f" || character === "\b") {
          value = value.slice(0, -1);
          continue;
        }
        if (character >= " " && value.length < 256) value += character;
      }
    };
    stdin.on("data", onData);
  });
}
