#include <usbguard/Rule.hpp>

#include <fstream>
#include <stdexcept>
#include <string>
#include <vector>

int main(int argc, char **argv) {
  if (argc != 5) {
    return 2;
  }

  std::ifstream policy(argv[1]);
  if (!policy) {
    throw std::runtime_error("Cannot open USBGuard policy");
  }

  std::vector<std::string> actual;
  for (std::string line; std::getline(policy, line);) {
    actual.push_back(usbguard::Rule::fromString(line).toString());
  }

  usbguard::Rule allow;
  allow.setTarget(usbguard::Rule::Target::Allow);
  allow.setDeviceID(usbguard::USBDeviceID("1235", "8219"));
  allow.setSerial(argv[2]);
  allow.setLabel(argv[3]);
  allow.setHash(argv[4]);

  usbguard::Rule block;
  block.setTarget(usbguard::Rule::Target::Block);
  block.setDeviceID(usbguard::USBDeviceID("1235", "*"));
  block.setSerial("");

  usbguard::Rule reject;
  reject.setTarget(usbguard::Rule::Target::Reject);
  reject.setDeviceID(usbguard::USBDeviceID("*", "*"));

  const std::vector<std::string> expected = {
      allow.toString(), block.toString(), reject.toString()};
  if (actual != expected) {
    throw std::runtime_error("USBGuard parsed different rule values");
  }
}
