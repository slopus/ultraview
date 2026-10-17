#if canImport(os)
import os
#endif

/// Signpost intervals for Instruments: each pass and its steps, text layout,
/// drawing, and the main thread's applying of commits. Record them with the
/// os_signpost instrument (subsystem `dev.ultraview`). They cost almost
/// nothing while no instrument records them, and nothing on platforms
/// without `os`.
enum Signposts {
    #if canImport(os)
    static let pipeline = OSSignposter(subsystem: "dev.ultraview", category: "Pipeline")
    static let mainThread = OSSignposter(subsystem: "dev.ultraview", category: "MainThread")
    #endif

    /// Runs `body` inside an interval of the pipeline's background work.
    static func interval<Result>(_ name: StaticString, _ body: () throws -> Result) rethrows -> Result {
        #if canImport(os)
        try pipeline.withIntervalSignpost(name, id: pipeline.makeSignpostID(), around: body)
        #else
        try body()
        #endif
    }

    /// Runs `body` inside an interval of main-thread work.
    static func mainInterval<Result>(_ name: StaticString, _ body: () throws -> Result) rethrows -> Result {
        #if canImport(os)
        try mainThread.withIntervalSignpost(name, id: mainThread.makeSignpostID(), around: body)
        #else
        try body()
        #endif
    }
}
