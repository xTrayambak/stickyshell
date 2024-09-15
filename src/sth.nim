import std/[os, logging]
import colored_logger, toml_serialization
import ./stickyshell

proc getConfig: StickyshellOpts {.inline.} =
  if isAdmin():
    if fileExists("/etc/stickyshell.conf"):
      return Toml.decode(readFile("/etc/stickyshell.conf"), StickyshellOpts)
    else: default(StickyshellOpts)
  else:
    if fileExists(getCurrentDir() / "stickyshell.conf"):
      return Toml.decode(readFile(getCurrentDir() / "stickyshell.conf"), StickyshellOpts)
    else: default(StickyshellOpts)

proc main {.inline, noReturn.} =
  addHandler(newColoredLogger())

  var sth = newStickyshell(getConfig())
  sth.run()

when isMainModule: main()
