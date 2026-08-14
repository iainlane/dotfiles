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

  return status == errSecItemNotFound;
}
