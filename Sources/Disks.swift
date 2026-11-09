import Darwin
import Foundation

enum StopList {
    // Background services that macOS restarts on demand and that hold no user work.
    // photolibraryd is left out on purpose: it can be busy on behalf of Photos.
    static let names: Set<String> = [
        "managedcorespotlightd",
        "corespotlightd",
        "mdworker",
        "mdworker_shared",
        "photoanalysisd",
        "mediaanalysisd",
    ]
}

struct Volume {
    let name: String
    let path: String
}

/// One physical disk and the volumes mounted from it. Ejecting a drive ejects all of them.
struct Drive {
    let id: String
    let volumes: [Volume]

    var name: String {
        volumes.map(\.name).joined(separator: ", ")
    }

    var isGone: Bool {
        volumes.allSatisfy { !FileManager.default.fileExists(atPath: $0.path) }
    }
}

struct Holder: Hashable {
    let pid: pid_t
    let name: String
    let uid: uid_t

    var canBeStopped: Bool {
        StopList.names.contains(name) && uid == getuid()
    }
}

enum Outcome {
    case ejected(stopped: [String])
    case disconnected
    case blocked(by: [String], stopped: [String])
    case failed(String, stopped: [String])
}

func run(_ executable: String, _ arguments: [String]) -> (status: Int32, output: String) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = pipe
    do {
        try process.run()
    } catch {
        return (-1, error.localizedDescription)
    }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return (process.terminationStatus, String(decoding: data, as: UTF8.self))
}

private func externalVolumes() -> [Volume] {
    let keys: [URLResourceKey] = [.volumeNameKey, .volumeIsInternalKey, .volumeIsLocalKey]
    let urls = FileManager.default.mountedVolumeURLs(
        includingResourceValuesForKeys: keys,
        options: [.skipHiddenVolumes]
    ) ?? []

    return urls.compactMap { url -> Volume? in
        guard url.path.hasPrefix("/Volumes/"),
              let values = try? url.resourceValues(forKeys: Set(keys)),
              values.volumeIsInternal != true,
              values.volumeIsLocal != false
        else { return nil }
        return Volume(name: values.volumeName ?? url.lastPathComponent, path: url.path)
    }
}

private func wholeDisk(of identifier: String) -> String? {
    guard let range = identifier.range(of: "^disk[0-9]+", options: .regularExpression) else { return nil }
    return String(identifier[range])
}

// APFS volumes live on a synthesized disk, so find the physical disk behind it.
private func physicalDisk(for path: String) -> String {
    let result = run("/usr/sbin/diskutil", ["info", "-plist", path])
    guard result.status == 0,
          let data = result.output.data(using: .utf8),
          let plist = try? PropertyListSerialization.propertyList(from: data, format: nil),
          let info = plist as? [String: Any]
    else { return path }

    if let stores = info["APFSPhysicalStores"] as? [[String: Any]],
       let store = stores.first?["APFSPhysicalStore"] as? String,
       let disk = wholeDisk(of: store) {
        return disk
    }
    return info["ParentWholeDisk"] as? String ?? path
}

func mountedDrives() -> [Drive] {
    var volumesByDisk: [String: [Volume]] = [:]
    for volume in externalVolumes() {
        volumesByDisk[physicalDisk(for: volume.path), default: []].append(volume)
    }
    return volumesByDisk
        .map { disk, volumes in
            Drive(id: disk, volumes: volumes.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending })
        }
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
}

func holders(of drive: Drive) -> [Holder] {
    var found = Set<Holder>()
    for volume in drive.volumes {
        found.formUnion(holders(ofPath: volume.path))
    }
    return Array(found)
}

private func holders(ofPath path: String) -> Set<Holder> {
    let output = run("/usr/sbin/lsof", ["-n", "-P", "+c", "0", "-F", "pcu", "--", path]).output
    var found = Set<Holder>()
    var pid: pid_t?
    var name: String?
    var uid: uid_t?

    func flush() {
        if let pid = pid, let name = name, let uid = uid {
            found.insert(Holder(pid: pid, name: name, uid: uid))
        }
    }

    for line in output.split(separator: "\n") {
        guard let tag = line.first else { continue }
        let value = String(line.dropFirst())
        switch tag {
        case "p":
            flush()
            pid = pid_t(value)
            name = nil
            uid = nil
        case "c":
            name = value
        case "u":
            uid = uid_t(value)
        default:
            break
        }
    }
    flush()
    return found
}

private func stop(_ services: [Holder]) {
    for service in services {
        kill(service.pid, SIGTERM)
    }
    let deadline = Date().addingTimeInterval(5)
    while Date() < deadline, services.contains(where: { kill($0.pid, 0) == 0 }) {
        usleep(100_000)
    }
}

/// Tries a normal eject and, if only services on the stop list hold the drive, asks them to quit.
func performEject(_ drive: Drive) -> Outcome {
    let attempts = 4
    var lastError = ""
    var stopped = Set<String>()

    for attempt in 1...attempts {
        let result = run("/usr/sbin/diskutil", ["eject", drive.id])
        if result.status == 0 || drive.isGone {
            return .ejected(stopped: stopped.sorted())
        }
        lastError = result.output.trimmingCharacters(in: .whitespacesAndNewlines)

        let current = holders(of: drive)
        let blockers = current.filter { !$0.canBeStopped }
        if !blockers.isEmpty {
            return .blocked(by: Set(blockers.map(\.name)).sorted(), stopped: stopped.sorted())
        }
        if attempt == attempts { break }

        if current.isEmpty {
            usleep(800_000)
        } else {
            // macOS can relaunch these quickly, so the next eject follows right away.
            stop(current)
            stopped.formUnion(current.map(\.name))
        }
    }
    return .failed(lastError, stopped: stopped.sorted())
}

/// Keeps checking the drive and ejects it once nothing outside the stop list is using it.
/// Returns nil if cancelled.
func ejectWhenFree(_ drive: Drive, isCancelled: () -> Bool) -> Outcome? {
    let shortestWait = 5.0
    let longestWait = 60.0
    var wait = shortestWait
    var stopped = Set<String>()

    while !isCancelled() {
        if drive.isGone {
            return .disconnected
        }

        if holders(of: drive).allSatisfy(\.canBeStopped) {
            switch performEject(drive) {
            case .ejected(let names):
                return .ejected(stopped: stopped.union(names).sorted())
            case .disconnected:
                return .disconnected
            case .blocked(_, let names), .failed(_, let names):
                stopped.formUnion(names)
                // Don't keep stopping services at full speed if the eject keeps failing.
                wait = min(wait * 2, longestWait)
            }
        } else {
            wait = shortestWait
        }

        let resume = Date().addingTimeInterval(wait)
        while Date() < resume, !isCancelled() {
            usleep(250_000)
        }
    }
    return nil
}
