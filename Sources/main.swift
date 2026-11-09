import AppKit
import ServiceManagement

let arguments = CommandLine.arguments

func report(_ outcome: Outcome) -> Int32 {
    switch outcome {
    case .ejected(let stopped):
        print("Ejected. Asked to quit: \(stopped.isEmpty ? "nothing" : stopped.joined(separator: ", "))")
        return 0
    case .disconnected:
        print("No longer connected.")
        return 0
    case .blocked(let names, let stopped):
        print("In use by: \(names.joined(separator: ", ")). Asked to quit: \(stopped.isEmpty ? "nothing" : stopped.joined(separator: ", "))")
        return 2
    case .failed(let details, _):
        print("Couldn't eject: \(details)")
        return 1
    }
}

// Lists drives and what is holding them. Nothing is ejected or stopped.
if arguments.contains("--list") {
    for drive in mountedDrives() {
        print("\(drive.name)  physical disk: \(drive.id)")
        for holder in holders(of: drive) {
            print("  \(holder.name) (\(holder.pid)): \(holder.canBeStopped ? "can be stopped" : "blocks eject")")
        }
    }
    exit(0)
}

// CastOff --eject <volume name or disk id> [--wait]
if let index = arguments.firstIndex(of: "--eject") {
    guard index + 1 < arguments.count else {
        print("Usage: CastOff --eject <volume name or disk id> [--wait]")
        exit(64)
    }
    let wanted = arguments[index + 1]
    guard let drive = mountedDrives().first(where: { drive in
        drive.id == wanted || drive.volumes.contains { $0.name == wanted }
    }) else {
        print("No external drive named \(wanted)")
        exit(1)
    }
    if arguments.contains("--wait"), let outcome = ejectWhenFree(drive, isCancelled: { false }) {
        exit(report(outcome))
    }
    exit(report(performEject(drive)))
}

// CastOff --login on|off|status
if let index = arguments.firstIndex(of: "--login"), index + 1 < arguments.count {
    let service = SMAppService.mainApp
    do {
        switch arguments[index + 1] {
        case "on":
            try service.register()
        case "off":
            try service.unregister()
        default:
            break
        }
    } catch {
        print("Error: \(error.localizedDescription)")
        exit(1)
    }
    switch service.status {
    case .enabled:
        print("enabled")
    case .requiresApproval:
        print("requires approval")
    case .notRegistered:
        print("not registered")
    default:
        print("not found")
    }
    exit(0)
}

let application = NSApplication.shared
let delegate = AppDelegate()
application.delegate = delegate
application.setActivationPolicy(.accessory)
application.run()
