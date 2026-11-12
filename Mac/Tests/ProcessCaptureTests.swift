import Foundation

@main struct Tests {
    static func main() {
        let failed = BoundedProcess.capture("/bin/sh", ["-c", "printf 'script failed' >&2; exit 7"], timeout: 2)
        assert(failed?.status == 7 && failed?.timedOut == false)
        assert(String(data: failed!.data, encoding: .utf8) == "script failed")
        let large = BoundedProcess.capture("/usr/bin/python3", ["-c", "import sys; sys.stdout.write('a'*262144); sys.stderr.write('b'*262144)"], timeout: 5)
        assert(large?.status == 0 && large?.data.count == 524288)
        let start = Date()
        let timeout = BoundedProcess.capture("/usr/bin/python3", ["-c", "import time; time.sleep(30)"], timeout: 0.1)
        assert(timeout?.timedOut == true && Date().timeIntervalSince(start) < 3)
        let inheritedStart = Date()
        let inherited = BoundedProcess.capture("/bin/sh", ["-c", "(sleep 3) & sleep 3"], timeout: 0.15, hardTimeout: true)
        assert(inherited?.timedOut == true && Date().timeIntervalSince(inheritedStart) < 1)
        assert(BoundedProcess.activeCount == 0)
        let output = BoundedProcess.run("/bin/sh", ["-c", "printf good; printf ignored >&2"], timeout: 2)
        assert(output == Data("good".utf8))
        print("PASS bounded capture: error details, full pipes, timeout, process cleanup and output compatibility")
    }
}
