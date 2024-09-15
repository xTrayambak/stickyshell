## sth - the sticky shell
## This code is licensed under the GNU GPL License Version 3.

import std/[logging, net, os, posix, random, strutils, times]
from std/nativesockets import setBlocking
import jsony
import ./[meta]

type
  StickyshellFatal* = object of Defect
    ## Raised when Stickyshell cannot recover from an error.
  
  BindFailed* = object of StickyshellFatal
  PollFailed* = object of StickyshellFatal

  MetricsIndex* = object
    attempts*: seq[Attempt]

  Attempt* = object
    ip*: string
    transmissions*: uint = 0
    startedAt*, endedAt*: float

  Metrics* = object
    transferred*: uint = 0     ## Bytes
    attempts*: seq[Attempt]    ## All login attempts made this session
                               ## Once the length of this sequence exceeds `MaxAttemptLogSize`, the first element will be eliminated, but not before being saved to disk.
  
  StickyshellOpts* = object
    port*: uint = 22
    delay*: uint = 8000 ## Seconds.
    maxLineLength*: uint = 250
    maxConcurrentClients*: uint = 100
    customMessages*: seq[string] = @[]

  Client* = object
    socket*: Socket ## Client socket
    sendNext*: float ## in UNIX time
    address*: string

  Stickyshell* = object
    socket*: Socket         ## Server socket
    clients*: seq[Client]   ## All currently connected and trapped bots
    metrics*: Metrics       ## For the time that this process has been alive
    opts*: StickyshellOpts  ## Configuration
    running*: bool = true   ## Are we running?

    timeout: int = -1
    destroyQueue: seq[int]

proc `&=`*(index: var MetricsIndex, attempt: Attempt) =
  index.attempts &= attempt

proc `=destroy`*(sth: Stickyshell) =
  if sth.socket != nil:
    debug "sth: destroying server socket"
    sth.socket.close()

proc generateLine*(
  sth: Stickyshell
): string =
  if sth.opts.customMessages.len < 1:
    let length = int(3 + rand( 4'u ..< sth.opts.maxLineLength) mod (sth.opts.maxLineLength - 2))
    var content = newString(length)

    for i in 0 ..< length - 2:
      content[i] = cast[char](int(32 + rand(97 .. 122) mod 95))

    debug "sth: generated line: `" & content & '`'

    content[length - 2] = '\r'
    content[length - 1] = '\n'

    if content.startsWith("SSH-"):
      debug "sth: line starts with protocol version specifier on complete random chance; discarding first character"
      content[0] = 'X'

    content
  else:
    let msg = sample(sth.opts.customMessages)
    debug "sth: chose message `" & msg & '`'

    msg & "\r\n"

proc sendBanner*(
  sth: var Stickyshell,
  num: int,
  client: Client
) =
  let line = sth.generateLine()

  inc sth.metrics.attempts[num].transmissions

  while true:
    try:
      client.socket.send(line, flags = {})
      sth.metrics.transferred += line.len.uint
      break
    except OSError:
      sth.metrics.attempts[num].endedAt = epochTime()

      info "sth: client ($1) seems to have disconnected. Transferred $2x times before they left. It took them $3 seconds to leave." % [
        client.address,
        $(sth.metrics.attempts[num].transmissions - 1),
        $(sth.metrics.attempts[num].endedAt - sth.metrics.attempts[num].startedAt)
      ]
      sth.destroyQueue &= num
      break

proc clientJoined*(
  sth: var Stickyshell,
  sock: Socket,
  address: string
) {.inline.} =
  info "sth: got new connection from: " & address
  sth.clients &=
    Client(
      socket: sock,
      address: address,
      sendNext: epochTime() + sth.opts.delay.float
    )

  sth.metrics.attempts &=
    Attempt(
      ip: address,
      startedAt: epochTime()
    )

proc readMetricsIndex*: MetricsIndex =
  if isAdmin():
    discard existsOrCreateDir("/var/lib/stickyshell")
    let path = "/var/lib/stickyshell/metrics.json"

    if fileExists(path):
      return readFile(
        path
      ).fromJson(MetricsIndex)
    else:
      info "sth: metrics file was not created, this is probably the first run."
  else:
    let path = getCurrentDir() / "metrics.json"
    if fileExists(path):
      return readFile(
        path
      ).fromJson(MetricsIndex)
    else:
      info "sth: metrics file was not created, this is probably the first run."

proc writeMetricsIndex*(index: MetricsIndex) =
  if isAdmin():
    discard existsOrCreateDir("/var/lib/stickyshell")

    writeFile(
      "/var/lib/stickyshell/metrics.json", toJson index
    )
  else:
    writeFile(
      getCurrentDir() / "metrics.json",
      toJson index
    )

proc dumpMetrics*(sth: var Stickyshell, num: int) =
  ## Dump metrics to metrics file and remove the entry.
  let metrics = sth.metrics.attempts[num]
  var index = readMetricsIndex()
  index &= metrics

  writeMetricsIndex(index)
  sth.metrics.attempts.del(num)

proc poll*(
  sth: var Stickyshell
) =
  # process all clients that need to be sent a message
  let
    prevMetrics = deepCopy(sth.metrics)
    currEpoch = epochTime()

  for dst in sth.destroyQueue:
    debug "sth: removing client " & $dst
    sth.dumpMetrics(dst)
    sth.clients.del(dst)

  sth.destroyQueue.reset()

  var updatedClients = 0'u64

  for i, client in sth.clients:
    if client.sendNext <= currEpoch:
      debug "sth: client $1 ($2) needs to be sent a new banner line" % [$i, client.address]
      sth.clients[i].sendNext = currEpoch + sth.opts.delay.float
      sth.sendBanner(i, client)
      inc updatedClients
    else:
      sth.timeout = client.sendNext.int - currEpoch.int
      break
  
  # wait for next event
  var fds: TPollfd
  fds.fd = sth.socket.getFd().cint
  fds.events = POLLIN
  fds.revents = 0.cshort
  let res = poll(addr fds, Tnfds(sth.clients.len.uint < sth.opts.maxConcurrentClients), sth.timeout)

  if res == -1:
    case errno
    of EINTR:
      debug "sth: poll() was interrupted by a signal!"
      return
    else:
      error "sth: poll() failed: " & $strerror(errno)
      raise newException(PollFailed, $strerror(errno))

  # look out for any new incoming connections
  if bool(fds.revents and POLLIN):
    var 
      sock: Socket
      address: string

    sth.socket.acceptAddr(sock, address)
    sth.clientJoined(sock, address)

  # let transferredBytesDelta = sth.metrics.transferred - prevMetrics.transferred
  #[ debug "sth: completed tick over $1 clients, updating $2 of them in total, tranferring $3 $4 in total" % [
    $sth.clients.len, $updatedClients, $transferredBytesDelta, (if transferredBytesDelta == 1: "byte" else: "bytes")
  ] ]#

proc run*(
  sth: var Stickyshell
) {.inline, noReturn.} =
  info "sth: the sticky shell " & Version
  info "sth: entering main loop, listening on port " & $sth.opts.port

  while sth.running:
    sth.poll()

  info "sth: exiting as main loop has ended"
  quit(0)

proc newStickyshell*(
  opts: sink StickyshellOpts = default(StickyshellOpts)
): Stickyshell {.inline.} =
  randomize()

  var sth: Stickyshell
  sth.running = true
  sth.socket = newSocket(Domain.AF_INET, SockType.SOCK_STREAM)
  sth.opts = move(opts)

  when not defined(release):
    sth.opts.port = 8080'u
    sth.opts.delay = 1'u

  sth.socket.setSockOpt(OptReuseAddr, true)
  sth.socket.setSockOpt(OptReusePort, true)
  
  try:
    sth.socket.bindAddr(Port(
      sth.opts.port
    ))
  except OSError as exc:
    error "sth: failed to bind to port $1: $2" % [$sth.opts.port, exc.msg]
    raise newException(BindFailed, exc.msg)

  discard sth.socket.getFd().listen(sth.opts.maxConcurrentClients.cint)

  sth
