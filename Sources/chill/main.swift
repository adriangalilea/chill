import ChillKit
import Foundation

// chill: the app and the CLI are ONE binary. No arguments = the app (what
// Finder and the login item launch, so a double click is never a silent
// death); anything else is a verb. `--demo` anywhere forks every
// content-bearing root to a -demo sibling and swaps the daemon for an
// in-process one.

let usage = """
    chill: fan control for the Mac, with Apple in charge by default.

    chill forces a fan only while all three hold: an intent (a curve or a
    boost), presence (someone watching within the last 10 s) and no veto
    (lid closed, sleep, thermal pressure, no die reading). Any other state
    is Apple's curve.

      chill                          the app (menu bar + canvas)
      chill status [--json]          who holds the fans and why, in one line
      chill curve list               the curves in ~/.local/state/chill/curves
      chill curve show <name>        its points
      chill curve use <name> [--watch]   intent = this curve; --watch holds presence (Ctrl-C hands back)
      chill boost [minutes] [--watch]    max rpm for N minutes (default 5), ends by itself
      chill system                   intent = Apple's curve
      chill daemon install           register chilld (SMAppService) and the login item
      chill daemon uninstall         auto over XPC, read back, then unregister
      chill daemon status            registration, pid, signature check
      chill log [-f]                 /Library/Logs/chill/chilld.log
      chill --demo ...               the demo world, never chilld

    `use` and `boost` need presence: with no app running and no --watch they
    refuse with exit 2 instead of forcing a fan nobody is watching.
    """

let rawArgs = Array(CommandLine.arguments.dropFirst())
let demo = rawArgs.contains("--demo")
let args = rawArgs.filter { $0 != "--demo" }

switch args.first {
case nil:
    App.run(demo: demo)
case "status":
    Client.status(json: args.contains("--json"), demo: demo)
case "curve":
    Client.curve(Array(args.dropFirst()), demo: demo)
case "boost":
    Client.boost(Array(args.dropFirst()), demo: demo)
case "system":
    Client.system(demo: demo)
case "daemon":
    DaemonControl.run(Array(args.dropFirst()))
case "log":
    Client.log(follow: args.contains("-f"))
case "help", "-h", "--help":
    print(usage)
default:
    Client.die("unknown verb '\(args[0])'; see chill help")
}
