import { spawn } from "node:child_process";

const mode = process.argv[2] ?? "echo";
const level = Number(process.argv[3] ?? 0);

if (mode === "echo") {
  process.stdin.setRawMode(true);
  process.stdout.on("resize", () => {
    console.log(`size:${process.stdout.columns}x${process.stdout.rows}`);
  });
  process.stdin.on("data", (data: Buffer) => {
    console.log(`input:${data.toString()}`);
  });
  console.log(`ready:${process.stdout.columns}x${process.stdout.rows}`);
}

if (mode !== "echo") {
  if (mode === "all-stubborn" || level > 0) {
    process.on("SIGTERM", () => {});
    process.on("SIGHUP", () => {});
    process.on("SIGINT", () => {});
  }
  if (level < 2) {
    spawn(process.execPath, [import.meta.filename, mode, String(level + 1)], {
      stdio: ["ignore", "inherit", "inherit"],
      env: process.env,
    });
  }
  if (level === 0) {
    process.stdin.on("data", () => process.exit(0));
  }
  console.log(`process:${level}:${process.pid}`);
  setInterval(() => {}, 1000);
}
