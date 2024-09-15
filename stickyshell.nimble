# Package

version       = "0.1.0"
author        = "xTrayambak"
description   = "A sticky shell to trap skids in"
license       = "GPL-2.0-or-later"
srcDir        = "src"
bin           = @["sth"]


# Dependencies

requires "nim >= 2.0.0"
requires "colored_logger >= 0.1.0"
requires "jsony >= 1.1.5"
requires "toml_serialization >= 0.2.12"
