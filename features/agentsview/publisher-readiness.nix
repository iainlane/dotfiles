{
  optional,
  certificatePresent,
  passwordPresent,
  keyPresent ? false,
  serverPresent ? true,
}: {
  enrol = !optional || (certificatePresent && passwordPresent);
  activate = serverPresent && certificatePresent && passwordPresent && keyPresent;
}
