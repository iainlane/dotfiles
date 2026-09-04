#include <CoreFoundation/CoreFoundation.h>
#include <Security/Security.h>
#include <stdio.h>

int main(void) {
  const void *keys[] = {
      kSecClass,
      kSecAttrService,
      kSecAttrAccount,
      kSecReturnData,
  };
  const void *values[] = {
      kSecClassGenericPassword,
      CFSTR("prompt-conformance-sandbox-probe.invalid"),
      CFSTR("prompt-conformance-sandbox-probe.invalid"),
      kCFBooleanTrue,
  };
  CFDictionaryRef query = CFDictionaryCreate(
      kCFAllocatorDefault,
      keys,
      values,
      4,
      &kCFTypeDictionaryKeyCallBacks,
      &kCFTypeDictionaryValueCallBacks);
  OSStatus status = SecItemCopyMatching(query, NULL);
  CFRelease(query);
  printf("%d\n", (int)status);

  // The sandbox is meant to deny this call outright. errSecItemNotFound means
  // the Keychain processed this deliberately unmatched query, which is the
  // escape this probe exists to catch, so exit 1 for that status and 0 for
  // every other one.
  return status == errSecItemNotFound;
}
