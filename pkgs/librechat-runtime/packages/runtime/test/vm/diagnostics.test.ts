import { expect, it } from "vitest";
import { WorkspaceDiagnostics } from "./fixtures/diagnostics.ts";

it("retains the original failure, background and cleanup errors with bounded output", () => {
  const diagnostics = new WorkspaceDiagnostics("tcg");
  diagnostics.stage = "resumed-execution";
  const executable = "/nix/store/fixture-qemu/bin/qemu-system-aarch64";
  diagnostics.capture({
    executable,
    stream: "stderr",
    text: "old".repeat(4000) + "\n",
  });
  diagnostics.capture({
    executable,
    stream: "stderr",
    text: "x".repeat(8190) + "\n",
  });
  diagnostics.capture({ executable, stream: "stderr", text: "last" });
  const error = Object.assign(new TypeError("fetch failed"), {
    stack: undefined,
  });
  const background = Object.assign(new Error("runner stopped"), {
    stack: undefined,
  });
  const cleanup = Object.assign(new Error("cleanup failed"), {
    stack: undefined,
  });
  const report: unknown = JSON.parse(
    diagnostics.report(error, background, [cleanup]),
  );
  expect(report).toStrictEqual({
    event: "librechat-workspace-failure",
    stage: "resumed-execution",
    accelerator: "tcg",
    error: { name: "TypeError", message: "fetch failed" },
    background: { name: "Error", message: "runner stopped" },
    cleanup: [{ name: "Error", message: "cleanup failed" }],
    output: { "qemu-system-aarch64:stderr": "x".repeat(8187) + "\nlast" },
  });
});

it("redacts fixture credentials from response errors and captured service output", async () => {
  const diagnostics = new WorkspaceDiagnostics("hvf");
  diagnostics.stage = "resumed-execution";
  diagnostics.addSecret("fixture-private-value");
  diagnostics.capture({
    executable: "/fixture/redis",
    stream: "stdout",
    text: "fixture-private-value",
  });
  let failure: unknown;
  try {
    await diagnostics.response(
      new Response('{"error":"TypeError","detail":"fixture-private-value"}', {
        status: 500,
      }),
    );
  } catch (error) {
    failure = error;
  }
  expect(failure).toBeInstanceOf(Error);
  const report = diagnostics.report(failure, undefined, []);
  expect({
    containsSecret: report.includes("fixture-private-value"),
    containsStage: report.includes("resumed-execution"),
    containsStatus: report.includes("HTTP 500"),
    containsType: report.includes("TypeError"),
  }).toStrictEqual({
    containsSecret: false,
    containsStage: true,
    containsStatus: true,
    containsType: true,
  });
});

it("redacts credentials that cross the retained output boundary", () => {
  const diagnostics = new WorkspaceDiagnostics("hvf");
  const secret = "credential-private-suffix";
  diagnostics.addSecret(secret);
  diagnostics.capture({
    executable: "/fixture/qemu",
    stream: "stderr",
    text: secret + "\n" + "x".repeat(8188),
  });
  const error = Object.assign(new Error("failed"), { stack: undefined });
  const report: unknown = JSON.parse(diagnostics.report(error, undefined, []));
  expect(report).toStrictEqual({
    event: "librechat-workspace-failure",
    stage: "startup",
    accelerator: "hvf",
    error: { name: "Error", message: "failed" },
    cleanup: [],
    output: { "qemu:stderr": "ed]\n" + "x".repeat(8188) },
  });
});

it.each([
  {
    label: "single-chunk token",
    chunks: [
      "Bearer " + "a".repeat(1400) + "private-suffix\n" + "x".repeat(8000),
    ],
    output: "Bearer [redacted]\n" + "x".repeat(8000),
  },
  {
    label: "split token",
    chunks: [
      "Bea",
      "rer " + "a".repeat(1400) + "private-suffix\n",
      "x".repeat(8000),
    ],
    output: "Bearer [redacted]\n" + "x".repeat(8000),
  },
  {
    label: "oversized token",
    chunks: ["Bearer " + "a".repeat(12000), "private-suffix\nnormal\n"],
    output: "[diagnostic record omitted]\nnormal\n",
  },
  {
    label: "split PEM",
    chunks: [
      "-----BE",
      "GIN PRIVATE KEY-----\n" + "private-value".repeat(1000),
      "\n-----END PRIVATE KEY-----\nnormal\n",
    ],
    output: "[redacted PEM record]\nnormal\n",
  },
])(
  "redacts unregistered credentials before retaining $label records",
  ({ chunks, output }) => {
    const diagnostics = new WorkspaceDiagnostics("hvf");
    for (const text of chunks) {
      diagnostics.capture({
        executable: "/fixture/qemu",
        stream: "stderr",
        text,
      });
    }
    const error = Object.assign(new Error("failed"), { stack: undefined });
    const report: unknown = JSON.parse(
      diagnostics.report(error, undefined, []),
    );
    expect(report).toStrictEqual({
      event: "librechat-workspace-failure",
      stage: "startup",
      accelerator: "hvf",
      error: { name: "Error", message: "failed" },
      cleanup: [],
      output: { "qemu:stderr": output },
    });
  },
);

it("collects failed backend responses without raw, unbounded credential logging", async () => {
  const diagnostics = new WorkspaceDiagnostics("tcg");
  const response = new Response(
    "Authorization: token ghp_private_value\n" + "x".repeat(20000),
    { status: 500 },
  );
  const returned = await diagnostics.backendResponse(
    response,
    new Request("http://guest/control/restore", { method: "POST" }),
  );
  const error = Object.assign(new Error("failed"), { stack: undefined });
  const report: unknown = JSON.parse(diagnostics.report(error, undefined, []));
  expect({
    status: returned.status,
    body: returned.body,
    report,
  }).toStrictEqual({
    status: 500,
    body: null,
    report: {
      event: "librechat-workspace-failure",
      stage: "startup",
      accelerator: "tcg",
      error: { name: "Error", message: "failed" },
      cleanup: [],
      output: {
        "backend:stderr":
          "POST /control/restore: HTTP 500\nAuthorization: [redacted]\n[diagnostic record omitted]\n",
      },
    },
  });
});

it.each([
  {
    label: "single marker",
    chunks: [
      "x".repeat(8192) +
        "-----BEGIN PRIVATE KEY-----\nprivate-key-material\n-----END PRIVATE KEY-----\n",
    ],
  },
  {
    label: "split marker",
    chunks: [
      "x".repeat(8192) + "-----BE",
      "GIN PRIVATE KEY-----\nprivate-key-material\n-----END PRIVATE KEY-----\n",
    ],
  },
])(
  "suppresses PEM material beyond an oversized record prefix with $label",
  ({ chunks }) => {
    const diagnostics = new WorkspaceDiagnostics("hvf");
    for (const text of chunks) {
      diagnostics.capture({
        executable: "/fixture/qemu",
        stream: "stderr",
        text,
      });
    }
    const error = Object.assign(new Error("failed"), { stack: undefined });
    expect(JSON.parse(diagnostics.report(error, undefined, []))).toStrictEqual({
      event: "librechat-workspace-failure",
      stage: "startup",
      accelerator: "hvf",
      error: { name: "Error", message: "failed" },
      cleanup: [],
      output: { "qemu:stderr": "[redacted PEM record]\n" },
    });
  },
);

it("redacts unfinished quoted credentials in pending records", () => {
  const diagnostics = new WorkspaceDiagnostics("hvf");
  diagnostics.capture({
    executable: "/fixture/qemu",
    stream: "stderr",
    text: 'password="first private-suffix',
  });
  const error = Object.assign(new Error("failed"), { stack: undefined });
  expect(JSON.parse(diagnostics.report(error, undefined, []))).toStrictEqual({
    event: "librechat-workspace-failure",
    stage: "startup",
    accelerator: "hvf",
    error: { name: "Error", message: "failed" },
    cleanup: [],
    output: { "qemu:stderr": "password=[redacted]" },
  });
});

it("bounds failed backend-response consumption and cancels excess output", async () => {
  const diagnostics = new WorkspaceDiagnostics("tcg");
  let produced = 0;
  let cancelled = false;
  const response = new Response(
    new ReadableStream<Uint8Array>({
      pull(controller) {
        produced += 1;
        controller.enqueue(new TextEncoder().encode("x".repeat(4096)));
        if (produced === 1000) {
          controller.close();
        }
      },
      cancel() {
        cancelled = true;
      },
    }),
    { status: 500, statusText: "Backend failure" },
  );
  const returned = await diagnostics.backendResponse(
    response,
    new Request("http://guest/control/restore"),
  );
  expect({
    produced,
    cancelled,
    status: returned.status,
    statusText: returned.statusText,
    body: returned.body,
  }).toStrictEqual({
    produced: 5,
    cancelled: true,
    status: 500,
    statusText: "Backend failure",
    body: null,
  });
});

it.each([
  {
    label: "single chunk",
    chunks: ["x\n".repeat(8182) + "fixture-private-value"],
  },
  {
    label: "multiple chunks",
    chunks: ["x\n".repeat(8182), "fixture-private-value"],
  },
])(
  "omits a credential record cut by the backend budget in $label",
  async ({ chunks }) => {
    const diagnostics = new WorkspaceDiagnostics("tcg");
    diagnostics.addSecret("fixture-private-value");
    const response = new Response(
      new ReadableStream<Uint8Array>({
        start(controller) {
          for (const text of chunks) {
            controller.enqueue(new TextEncoder().encode(text));
          }
          controller.close();
        },
      }),
      { status: 500 },
    );
    await diagnostics.backendResponse(
      response,
      new Request("http://guest/control/restore"),
    );
    const report = diagnostics.report(new Error("failed"), undefined, []);
    expect({
      containsFragment: report.includes("fixture-private"),
      omitted: report.includes("[diagnostic record omitted]"),
    }).toStrictEqual({ containsFragment: false, omitted: true });
  },
);

it("redacts a pending quoted credential ending in a dangling escape", () => {
  const diagnostics = new WorkspaceDiagnostics("hvf");
  diagnostics.capture({
    executable: "/fixture/qemu",
    stream: "stderr",
    text: 'password="first private-suffix\\',
  });
  const error = Object.assign(new Error("failed"), { stack: undefined });
  expect(JSON.parse(diagnostics.report(error, undefined, []))).toStrictEqual({
    event: "librechat-workspace-failure",
    stage: "startup",
    accelerator: "hvf",
    error: { name: "Error", message: "failed" },
    cleanup: [],
    output: { "qemu:stderr": "password=[redacted]" },
  });
});

it.each([
  {
    label: "single chunk",
    chunks: [
      "-----BEGIN PRIVATE KEY-----\nfirst-key-material\n-----END PRIVATE KEY----- -----BEGIN PRIVATE KEY-----\nsecond-key-material\n-----END PRIVATE KEY-----\n",
    ],
  },
  {
    label: "split markers",
    chunks: [
      "-----BEGIN PRIVATE KEY-----\nfirst-key-material\n-----EN",
      "D PRIVATE KEY----- -----BE",
      "GIN PRIVATE KEY-----\nsecond-key-material\n-----END PRIVATE KEY-----\n",
    ],
  },
])("keeps PEM marker order in $label", ({ chunks }) => {
  const diagnostics = new WorkspaceDiagnostics("hvf");
  for (const text of chunks) {
    diagnostics.capture({
      executable: "/fixture/qemu",
      stream: "stderr",
      text,
    });
  }
  const error = Object.assign(new Error("failed"), { stack: undefined });
  expect(JSON.parse(diagnostics.report(error, undefined, []))).toStrictEqual({
    event: "librechat-workspace-failure",
    stage: "startup",
    accelerator: "hvf",
    error: { name: "Error", message: "failed" },
    cleanup: [],
    output: { "qemu:stderr": "[redacted PEM record]\n[redacted PEM record]\n" },
  });
});
