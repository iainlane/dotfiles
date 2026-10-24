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
