import Foundation
import OwnedOCRFixture

// Reject arguments before driver construction, AppKit or the owned fixture.
guard CommandLine.arguments.count == 1 else {
    print("owned-ocr not-tested invalid-invocation")
    exit(2)
}
OwnedOCRQualification.enter()
