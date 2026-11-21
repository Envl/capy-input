import AppKit

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

guard CommandLine.arguments.count == 2 else {
    fail("Usage: stop-mac-build.swift <app path>")
}

let buildURL = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true).resolvingSymlinksInPath()
guard let bundleID = Bundle(url: buildURL)?.bundleIdentifier else {
    fail("Cannot read the bundle identifier of \(buildURL.path).")
}

let runningBuilds = NSWorkspace.shared.runningApplications.filter { app in
    // A rebuilt bundle may have a different ID from the process launched at this path.
    app.bundleIdentifier == bundleID || app.bundleURL?.resolvingSymlinksInPath().path == buildURL.path
}
for app in runningBuilds where !app.isTerminated {
    _ = app.terminate()
}

let deadline = Date().addingTimeInterval(5)
while !runningBuilds.allSatisfy(\.isTerminated), Date() < deadline {
    RunLoop.main.run(until: min(deadline, Date().addingTimeInterval(0.1)))
}
guard runningBuilds.allSatisfy(\.isTerminated) else {
    fail("Close the running capy-companion before launching this build.")
}
