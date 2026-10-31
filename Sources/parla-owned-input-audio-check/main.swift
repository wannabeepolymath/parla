import Foundation

// Refuse before NSApplication, adapter construction or any native inquiry.
guard CommandLine.arguments.count == 1 else {
    print("input-check not-tested invalid-invocation")
    exit(2)
}
InputCheckWorkbench.enter()
