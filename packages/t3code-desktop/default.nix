# The electron app half of t3code. The derivation has two outputs, `out` the
# `t3` server/CLI and `desktop` the app; this gives the latter its own package
# so it can sit in home.packages with the right mainProgram.
{
  symlinkJoin,
  t3code,
}:
symlinkJoin {
  name = "t3code-desktop-${t3code.version}";
  paths = [t3code.desktop];
  meta = t3code.meta // {mainProgram = "t3code-desktop";};
}
