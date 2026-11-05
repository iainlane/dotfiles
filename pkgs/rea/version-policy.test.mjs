import assert from "node:assert/strict";
import { pathToFileURL } from "node:url";

const root = process.argv[2];
const load = (path) =>
  import(pathToFileURL(`${root}/lib/node_modules/rea-agents/dist/${path}`));
const { admitFirmwareVersion } = await load("firmware/FirmwareVersion.js");
for (const [tool, banner, version] of [
  ["binwalk", "binwalk 4.0.0", "4.0.0"],
  ["unblob", "27.0.0", "27.0.0"],
]) {
  assert.equal(admitFirmwareVersion(tool, banner).version, version);
}
assert.equal(admitFirmwareVersion("binwalk", "invalid").status, "unresolved");
const { admitWakaruVersion } = await load(
  "javascript/recovery/WakaruVersion.js",
);
assert.equal(admitWakaruVersion("wakaru 2.0.0").version, "2.0.0");
assert.equal(admitWakaruVersion("invalid").status, "unsupported");
const { parseWiresharkVersion } = await load("pcap/PcapConfiguration.js");
assert.equal(
  parseWiresharkVersion("TShark (Wireshark) 5.0.0", "tshark"),
  "TShark (Wireshark) 5.0.0",
);
assert.equal(parseWiresharkVersion("invalid", "tshark"), null);
const {
  ghidraReleaseAccepted,
  ghidraReleaseCompatibility,
  unverifiedGhidraBuildLimitation,
} = await load("ghidra/GhidraReleasePolicy.js");
for (const [raw, major, minor, patch, status] of [
  ["12.1.4", 12, 1, 4, "verified"],
  ["12.2", 12, 2, 0, "compatible"],
  ["13.0.1", 13, 0, 1, "compatible"],
  ["11.4", 11, 4, 0, "compatible"],
]) {
  assert.equal(ghidraReleaseAccepted(raw), true);
  assert.deepEqual(ghidraReleaseCompatibility(raw), {
    status,
    version: { major, minor, patch, suffix: "" },
    raw,
  });
}
for (const raw of [null, undefined, "", "invalid"]) {
  assert.equal(ghidraReleaseAccepted(raw), false);
  assert.deepEqual(ghidraReleaseCompatibility(raw), {
    status: "unresolved",
    raw: raw ?? null,
  });
}
assert.equal(
  unverifiedGhidraBuildLimitation("12.2"),
  "This session uses Ghidra 12.2. The bridge is verified against 12.1.4; the observed version is reported and output validation remains enabled.",
);
