import Foundation

/// Opens the new version once this process has gone, so two recorders never
/// hold the input at once.
///
/// A small `sh` process does it, started before the swap: if it cannot be
/// started, nothing is replaced. It only ever opens the app. It never touches
/// the bundle, because after this process quits macOS would no longer hold the
/// app responsible for a change to it, and App Management could refuse one.
///
/// What it adds to `SelfUpdater.relaunch`, which waited a minute and gave up
/// without a word:
///   - This process quits only with nothing in flight (`UpdateCommit`), so one
///     that is still there ten seconds on is stuck in its exit. It is ended.
///   - With a probation marker (`UpdateRollback`), it watches the new copy. A
///     copy that ends while the marker is still there never became healthy, so
///     it is opened again, up to three times in all: a version that cannot
///     stay up then reaches its own rollback without anyone clicking.
enum UpdateRelauncher {

    /// $1: PID to wait for. $2: the app to open. $3: the probation marker, or
    /// empty for none. $4: the opener, `/usr/bin/open` outside of tests.
    static let script = """
        pid="$1"; app="$2"; marker="$3"; opener="$4"
        i=0
        while kill -0 "$pid" 2>/dev/null; do
            i=$((i + 1))
            [ "$i" -eq 50 ] && kill -KILL "$pid" 2>/dev/null
            [ "$i" -gt 150 ] && exit 1
            sleep 0.2
        done
        tries=0
        while [ "$tries" -lt 3 ]; do
            tries=$((tries + 1))
            if [ -z "$marker" ]; then
                "$opener" "$app" && exit 0
                sleep 1
                continue
            fi
            "$opener" -W "$app" &
            waiter=$!
            while kill -0 "$waiter" 2>/dev/null; do
                if [ ! -e "$marker" ]; then
                    kill "$waiter" 2>/dev/null
                    exit 0
                fi
                sleep 0.2
            done
            [ -e "$marker" ] || exit 0
            sleep 1
        done
        exit 1
        """

    /// Starts the helper. It does nothing until `pid` has gone, and `cancel`
    /// on the result stops it before then.
    static func prepare(toOpen app: URL, after pid: Int32 = ProcessInfo.processInfo.processIdentifier,
                        marker: URL?, opener: String = "/usr/bin/open") throws -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", script, "sh", String(pid), app.path, marker?.path ?? "", opener]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        return process
    }
}
