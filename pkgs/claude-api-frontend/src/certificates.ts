import {
  CertificateCleanupError,
  CertificateCommandError,
  CertificateExpiringError,
  CertificateStateError,
  FrontendError,
} from "./errors.ts";
import { execFile } from "node:child_process";
import { randomUUID, X509Certificate } from "node:crypto";
import {
  chmod,
  mkdir,
  mkdtemp,
  readFile,
  rename,
  rm,
  writeFile,
} from "node:fs/promises";
import { join } from "node:path";
import { promisify } from "node:util";

const execute = promisify(execFile);

export interface CertificateCommand {
  run(arguments_: readonly string[]): Promise<void>;
}

export class OpenSslCommand implements CertificateCommand {
  async run(arguments_: readonly string[]): Promise<void> {
    try {
      await execute("openssl", arguments_, { timeout: 15000 });
    } catch (cause) {
      throw new CertificateCommandError({ cause });
    }
  }
}

export interface CertificateRuntime {
  now(): number;
  newSerial(): string;
  removeTemporary?(directory: string): Promise<void>;
}

async function removeTemporary(directory: string): Promise<void> {
  await rm(directory, { recursive: true, force: true });
}

const nativeRuntime: CertificateRuntime = {
  now: Date.now,
  newSerial: randomUUID,
};

export interface Certificates {
  key: Buffer;
  cert: Buffer;
  ca: Buffer;
}

async function createCertificates(
  stateDirectory: string,
  command: CertificateCommand,
  runtime: CertificateRuntime,
): Promise<Certificates> {
  await mkdir(stateDirectory, { recursive: true, mode: 0o700 });
  await chmod(stateDirectory, 0o700);
  const temporary = await mkdtemp(join(stateDirectory, ".certificates-"));
  const authority = join(stateDirectory, "authority");
  const caFile = join(authority, "ca.pem");
  const issueCertificates = async (): Promise<Certificates> => {
    try {
      await readFile(caFile);
    } catch (error) {
      if (
        !(error instanceof Error) ||
        !("code" in error) ||
        error.code !== "ENOENT"
      ) {
        throw error;
      }
      const pending = join(temporary, "authority");
      await mkdir(pending, { mode: 0o700 });
      await command.run([
        "req",
        "-x509",
        "-newkey",
        "ec",
        "-pkeyopt",
        "ec_paramgen_curve:P-256",
        "-nodes",
        "-days",
        "3650",
        "-subj",
        "/CN=Claude API frontend local CA",
        "-addext",
        "basicConstraints=critical,CA:TRUE",
        "-addext",
        "keyUsage=critical,keyCertSign,cRLSign",
        "-keyout",
        join(pending, "ca.key"),
        "-out",
        join(pending, "ca.pem"),
      ]);
      await chmod(join(pending, "ca.key"), 0o600);
      try {
        await rename(pending, authority);
      } catch (renameError) {
        if (
          !(renameError instanceof Error) ||
          !("code" in renameError) ||
          !["EEXIST", "ENOTEMPTY"].includes(String(renameError.code))
        ) {
          throw renameError;
        }
      }
    }

    const ca = await readFile(caFile);
    await chmod(join(authority, "ca.key"), 0o600);
    const root = new X509Certificate(ca);
    if (Date.parse(root.validTo) < runtime.now() + 366 * 86400000) {
      throw new CertificateExpiringError(root.validTo);
    }

    const keyFile = join(temporary, "leaf.key");
    const requestFile = join(temporary, "leaf.csr");
    const certificateFile = join(temporary, "leaf.pem");
    const extensions = join(temporary, "extensions.cnf");
    await writeFile(
      extensions,
      "basicConstraints=critical,CA:FALSE\nkeyUsage=critical,digitalSignature\nextendedKeyUsage=serverAuth\nsubjectAltName=DNS:api.anthropic.com\n",
      { mode: 0o600 },
    );
    await command.run([
      "req",
      "-new",
      "-newkey",
      "ec",
      "-pkeyopt",
      "ec_paramgen_curve:P-256",
      "-nodes",
      "-subj",
      "/CN=api.anthropic.com",
      "-keyout",
      keyFile,
      "-out",
      requestFile,
    ]);
    await command.run([
      "x509",
      "-req",
      "-in",
      requestFile,
      "-CA",
      caFile,
      "-CAkey",
      join(authority, "ca.key"),
      "-set_serial",
      `0x${runtime.newSerial().replaceAll("-", "")}`,
      "-days",
      "365",
      "-extfile",
      extensions,
      "-out",
      certificateFile,
    ]);

    return {
      key: await readFile(keyFile),
      cert: await readFile(certificateFile),
      ca,
    };
  };
  let outcome: { certificates: Certificates } | { error: unknown };
  try {
    outcome = { certificates: await issueCertificates() };
  } catch (error) {
    outcome = { error };
  }
  let cleanup: { error: unknown } | undefined;
  try {
    if (runtime.removeTemporary === undefined) {
      await removeTemporary(temporary);
    } else {
      await runtime.removeTemporary(temporary);
    }
  } catch (error) {
    cleanup = { error };
  }
  if ("error" in outcome) {
    if (cleanup !== undefined) {
      throw new CertificateCleanupError(outcome.error, cleanup.error);
    }
    throw outcome.error;
  }
  if (cleanup !== undefined) {
    throw cleanup.error;
  }
  return outcome.certificates;
}

export async function certificates(
  stateDirectory: string,
  command: CertificateCommand = new OpenSslCommand(),
  runtime: CertificateRuntime = nativeRuntime,
): Promise<Certificates> {
  try {
    return await createCertificates(stateDirectory, command, runtime);
  } catch (cause) {
    if (cause instanceof FrontendError) {
      throw cause;
    }

    throw new CertificateStateError(stateDirectory, { cause });
  }
}
