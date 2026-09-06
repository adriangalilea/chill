import ChillKit
import Foundation

// chill: the app and the CLI are ONE binary. No arguments = the app (what
// Finder and the login item launch, so a double click is never a silent
// death); anything else is a verb. `--demo` anywhere forks every
// content-bearing root to a -demo sibling and swaps the daemon for an
// in-process one.

let rawArgs = Array(CommandLine.arguments.dropFirst())
let demo = Demo(on: rawArgs.contains("--demo"))
let args = rawArgs.filter { $0 != "--demo" }

let usage = """
    chill: fan control for the Mac, with Apple in charge by default.

    chill forces a fan only while all three hold: an intent (a curve or a
    boost), presence (someone watching within the last \(Int(Wire.presenceWindow.seconds)) s) and no veto
    (lid closed, sleep, thermal pressure, no die reading). Any other state
    is Apple's curve.

      chill                          the app (menu bar + canvas)
      chill status [--json]          who holds the fans and why, in one line (--json: the State document)
      chill curve list               the curves in \(demo.curves.path)
      chill curve show <name>        its points
      chill curve use <name> [--watch] [--take]   intent = this curve
      chill boost [minutes] [--watch] [--take]    max rpm for N minutes (default \(Wire.boostMinutes)), ends by itself
      chill system                   intent = Apple's curve; reclaims a fan someone else forced
      chill daemon install           register chilld (SMAppService) and the login item
      chill daemon uninstall         Apple's curve over XPC, read back, then unregister
      chill daemon status            registration, pid, signature check
      chill log [-f]                 \(Wire.logFile) (-f follows)
      chill --demo ...               the demo world: -demo roots, an in-process daemon, never chilld

    `use` and `boost` set the intent; a fan is forced only while someone
    watches. --watch makes this process the watcher, at 1 Hz until Ctrl-C
    hands the fans back; without it they need chill.app watching and exit
    2 otherwise. One watcher at a time: --take (with --watch) overrides.
    """

switch args.first {
case nil:
    // The process's own main thread, before any run loop exists.
    MainActor.assumeIsolated { App.run(demo: demo) }
case "status":
    Verbs.status(json: args.contains("--json"), demo: demo)
case "curve":
    Verbs.curve(Array(args.dropFirst()), demo: demo)
case "boost":
    Verbs.boost(Array(args.dropFirst()), demo: demo)
case "system":
    Verbs.system(demo: demo)
case "daemon":
    DaemonControl.run(Array(args.dropFirst()), demo: demo)
case "log":
    Verbs.log(follow: args.contains("-f"), demo: demo)
case "help", "-h", "--help":
    print(usage)
default:
    Verbs.die("unknown verb '\(args[0])'; see chill help")
}
