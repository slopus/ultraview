// Frame-by-frame analysis of a list demo recording.
//
//   swiftc -O Tools/Video/analyze-video.swift -o .context/analyze-video
//   .context/analyze-video <clip.mp4> <clip.json> <output dir>
//
// <clip.json> is the log the demo writes with `-listScenario` (see
// Sources/UltraViewDemo/List/ListVideoScenario.swift). The video comes from
// `-listRecord YES` on a device or `xcrun simctl io <sim> recordVideo`; for a
// simulator video the log carries `host.recordingStarted`, the host clock at
// the start of recording, which the simulator shares with the app.
//
// Every frame is decoded (ffmpeg, grayscale, one row per point and two points
// per column) and compared with the previous one:
//   - vertical displacement of each list region, from the best match of
//     per-band row-luminance profiles, refined to subpixel; its velocity, and
//     the same displacement predicted by the logged presentation offsets;
//   - hitches: frames missing (gaps) or frozen while motion is expected;
//   - jumps: displacement away from both its neighbors and the model;
//   - pops: a one-frame spike in the residual after the best rigid match;
//   - rigidity: top and bottom thirds of a list moving differently;
//   - blank runs: background-only rows inside a list;
//   - header changes: the controls above the lists changing;
//   - the keyboard: its top edge, the composer and the newest row's bottom,
//     each tracked by template matching, and the gaps between them.
// It writes <name>.csv, <name>-summary.json, <name>-summary.md and PNG
// sheets (an overview, flagged frames with their neighbors, the keyboard
// band and a velocity plot) with ffmpeg.
import Foundation
#if canImport(Glibc)
import Glibc
#endif

// MARK: - Input

struct Failure: Error, CustomStringConvertible { let description: String }
let clockStart = Date()
func progress(_ what: String) {
    FileHandle.standardError.write(Data(String(format: "[%6.1fs] %@\n", Date().timeIntervalSince(clockStart), what).utf8))
}

let arguments = CommandLine.arguments
guard arguments.count >= 4 else {
    FileHandle.standardError.write(Data("usage: analyze-video <clip.mp4> <clip.json> <output dir>\n".utf8))
    exit(2)
}
let videoPath = arguments[1], logPath = arguments[2], outDirectory = arguments[3]
let name = URL(fileURLWithPath: videoPath).deletingPathExtension().lastPathComponent
try FileManager.default.createDirectory(atPath: outDirectory, withIntermediateDirectories: true)

/// Runs a command through the shell and returns its standard output. (A
/// file instead of a pipe: Foundation's pipes need a socket pair, which some
/// sandboxes refuse.)
func run(_ command: [String]) throws -> Data {
    func quote(_ text: String) -> String { "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'" }
    let output = NSTemporaryDirectory() + "/analyze-run-\(ProcessInfo.processInfo.processIdentifier).out"
    let line = command.map(quote).joined(separator: " ") + " > " + quote(output) + " 2>/dev/null"
    guard system(line) == 0 else { throw Failure(description: "\(command.first ?? "") failed: \(command.joined(separator: " ").prefix(300))") }
    defer { try? FileManager.default.removeItem(atPath: output) }
    return try Data(contentsOf: URL(fileURLWithPath: output))
}

let log = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: logPath))) as! [String: Any]
func doubles(_ value: Any?) -> [Double] { (value as? [Any])?.compactMap { ($0 as? NSNumber)?.doubleValue } ?? [] }
func number(_ value: Any?) -> Double? { (value as? NSNumber)?.doubleValue }

let screen = doubles(log["screenPoints"])
let widthPoints = screen.count == 2 ? screen[0] : 390, heightPoints = screen.count == 2 ? screen[1] : 844
let W = Int(widthPoints / 2), H = Int(heightPoints)
let scenario = log["scenario"] as? String ?? "", engine = log["engine"] as? String ?? ""
let lists = (log["lists"] as? [[String: Any]] ?? []).map { (frame: doubles($0["frame"]), inverted: ($0["inverted"] as? Bool) ?? false, engine: $0["engine"] as? String ?? "") }
let samples = log["samples"] as? [[String: Any]] ?? []
let events = log["events"] as? [[String: Any]] ?? []
let recorder = log["recorder"] as? [String: Any]
let host = log["host"] as? [String: Any]
let isChat = (log["listScreen"] as? String) == "chat"

// Presentation times of the frames.
let ptsText = String(decoding: try run(["ffprobe", "-v", "error", "-select_streams", "v", "-show_entries", "frame=pts_time", "-of", "csv=p=0", videoPath]), as: UTF8.self)
let pts = ptsText.split(whereSeparator: \.isNewline).compactMap { Double($0.trimmingCharacters(in: CharacterSet(charactersIn: ", "))) }

// Frames as 8-bit luminance, W x H (two points per column, one per row).
let rawPath = NSTemporaryDirectory() + "/analyze-\(name)-\(ProcessInfo.processInfo.processIdentifier).gray"
_ = try run(["ffmpeg", "-v", "error", "-y", "-i", videoPath, "-fps_mode", "passthrough", "-vf", "scale=\(W):\(H):flags=area,format=gray", "-f", "rawvideo", rawPath])
let raw = try Data(contentsOf: URL(fileURLWithPath: rawPath))
try? FileManager.default.removeItem(atPath: rawPath)
let frameBytes = W * H
let frameCount = min(raw.count / frameBytes, pts.count)
guard frameCount > 2 else { throw Failure(description: "too few frames: \(frameCount)") }
progress("decoded \(frameCount) frames at \(W)x\(H)")
let pixels = [UInt8](raw)
@inline(__always) func pixel(_ frame: Int, _ x: Int, _ y: Int) -> Int { Int(pixels[frame * frameBytes + y * W + x]) }

// MARK: - Clock alignment

// App-clock time of each frame. Device recordings use display-link timestamps
// relative to the first appended frame; simulator recordings start at the
// host's recording time and are refined against the model below.
let deviceFrames = (recorder?["frames"] as? [[Any]])?.compactMap { number($0.first) } ?? []
let isDevice = !deviceFrames.isEmpty
var lag = 0.0
// The simulator and its host share the wall clock; the app logs both clocks
// at the start of the scenario.
let base: Double = {
    if isDevice { return deviceFrames[0] }
    guard let recording = number(host?["recordingStartedWall"]), let wall = number(log["startedAtWall"]), let media = number(log["startedAt"]) else { return number(log["startedAt"]) ?? 0 }
    return media + (recording - wall)
}()
func appTime(_ index: Int) -> Double { base + pts[index] + lag }
let nominalInterval = isDevice ? Double((recorder?["interval"] as? Int) ?? 2) / 60 : 1.0 / 60

// MARK: - Model

let sampleTimes = samples.compactMap { number($0["time"]) }
/// Index of the last sample at or before `time`.
func sampleIndex(at time: Double) -> Int? {
    guard let first = sampleTimes.first, time >= first else { return nil }
    var low = 0, high = sampleTimes.count - 1
    while low < high { let mid = (low + high + 1) / 2; if sampleTimes[mid] <= time { low = mid } else { high = mid - 1 } }
    return low
}
/// Presented screen minY of each loaded row, per list, per sample.
let rowSeries: [[[Int: Double]]] = lists.indices.map { list in
    samples.map { sample in
        guard let all = sample["rows"] as? [Any], all.count > list, let rows = all[list] as? [[Any]] else { return [:] }
        var map: [Int: Double] = [:]
        for row in rows { if let index = number(row.first).map(Int.init), let y = number(row.count > 1 ? row[1] : nil) { map[index] = y } }
        return map
    }
}
/// A row's presented minY at `time`, interpolated between the samples around it.
/// While a finger drives the list, its position changes in steps when
/// touches arrive, so it is held; otherwise motion is continuous in time.
func rowPosition(_ list: Int, _ index: Int, at time: Double) -> Double? {
    guard let i = sampleIndex(at: time), i + 1 < sampleTimes.count, let a = rowSeries[list][i][index], let b = rowSeries[list][i + 1][index] else { return nil }
    if trackingSeries[list][i] { return a }
    let span = sampleTimes[i + 1] - sampleTimes[i]
    return a + (b - a) * (span > 0 ? (time - sampleTimes[i]) / span : 0)
}
let trackingSeries: [[Bool]] = lists.indices.map { index in samples.map { (($0["tracking"] as? [Bool]) ?? []).count > index ? ($0["tracking"] as! [Bool])[index] : false } }
func tracking(_ list: Int, at time: Double) -> Bool {
    guard let index = sampleIndex(at: time) else { return false }
    // A touch can arrive between samples; count the neighbors too.
    return trackingSeries[list][max(0, index - 1)...min(sampleTimes.count - 1, index + 1)].contains(true)
}
let flightSeries: [[Bool]] = lists.indices.map { index in samples.map { (($0["flights"] as? [Bool]) ?? []).count > index ? ($0["flights"] as! [Bool])[index] : false } }
func flightActive(_ list: Int, at time: Double) -> Bool {
    guard let index = sampleIndex(at: time) else { return false }
    return flightSeries[list][index]
}
/// Screen-space displacement of the list's rows that the app reported
/// between two times: the median over rows present at both.
func modelDisplacement(_ list: Int, from start: Double, to end: Double) -> Double? {
    guard let i = sampleIndex(at: start) else { return nil }
    var moves: [Double] = []
    for index in rowSeries[list][i].keys {
        if let a = rowPosition(list, index, at: start), let b = rowPosition(list, index, at: end) { moves.append(b - a) }
    }
    guard !moves.isEmpty else { return nil }
    let sorted = moves.sorted(); return sorted[sorted.count / 2]
}
func sampleRect(_ key: String, at time: Double) -> [Double]? {
    guard let index = sampleIndex(at: time) ?? (sampleTimes.isEmpty ? nil : 0) else { return nil }
    let rect = doubles(samples[index][key]); return rect.count == 4 ? rect : nil
}

// MARK: - Profiles and matching

/// Mean luminance of rows `rows` over the columns of each band.
func profiles(_ frame: Int, bands: [Range<Int>], rows: Range<Int>) -> [[Double]] {
    bands.map { band in
        rows.map { y in
            var total = 0
            let row = frame * frameBytes + y * W
            for x in band { total += Int(pixels[row + x]) }
            return Double(total) / Double(band.count)
        }
    }
}

struct Match { var shift = 0.0; var cost = Double.infinity; var baseline = 0.0; var detail = 0.0; var ok = false }

/// Finds `s` such that row y of `b` shows row y - s of `a`, within `rows`.
func match(_ a: [[Double]], _ b: [[Double]], maxShift: Int, minimumOverlap: Int, predicted: Double?) -> Match {
    let count = a.first?.count ?? 0
    var result = Match()
    guard count > minimumOverlap else { return result }
    var mean = 0.0, square = 0.0
    for band in a { for value in band { mean += value; square += value * value } }
    let n = Double(count * a.count); mean /= n
    result.detail = (square / n - mean * mean).squareRoot()
    let limit = min(maxShift, count - minimumOverlap)
    var costs = [Double](repeating: .infinity, count: 2 * limit + 1)
    for s in -limit...limit {
        let start = max(0, s), end = min(count, count + s)
        var total = 0.0
        for band in a.indices {
            let pa = a[band], pb = b[band]
            for y in start..<end { total += abs(pb[y] - pa[y - s]) }
        }
        costs[s + limit] = total / Double((end - start) * a.count)
    }
    let finite = costs.filter(\.isFinite)
    result.baseline = finite.reduce(0, +) / Double(max(1, finite.count))
    var minima: [Int] = []
    for i in costs.indices where (i == 0 || costs[i] <= costs[i - 1]) && (i == costs.count - 1 || costs[i] <= costs[i + 1]) { minima.append(i) }
    guard let best = minima.min(by: { costs[$0] < costs[$1] }) else { return result }
    var chosen = best
    if let predicted {
        // Repeated rows can tie; prefer the candidate nearest the prediction.
        let candidates = minima.filter { costs[$0] <= costs[best] * 1.2 + 0.25 }
        chosen = candidates.min(by: { abs(Double($0 - limit) - predicted) < abs(Double($1 - limit) - predicted) }) ?? best
    }
    var shift = Double(chosen - limit)
    if chosen > 0, chosen < costs.count - 1 {
        let l = costs[chosen - 1], c = costs[chosen], r = costs[chosen + 1]
        let denominator = l - 2 * c + r
        if denominator > 1e-9 { shift += max(-0.5, min(0.5, 0.5 * (l - r) / denominator)) }
    }
    result.shift = shift; result.cost = costs[chosen]; result.ok = result.detail > 1.0
    return result
}

/// Finds the row where a template of rows best matches, allowing it to run
/// past the bottom of the frame.
func locate(_ template: [[Double]], in frame: Int, bands: [Range<Int>], rows: Range<Int>, minimumRows: Int) -> (row: Double, cost: Double) {
    let all = profiles(frame, bands: bands, rows: 0..<H)
    let length = template.first?.count ?? 0
    var costs: [Double] = []
    for y in rows {
        let visible = min(length, H - y)
        guard visible >= minimumRows else { costs.append(.infinity); continue }
        var total = 0.0
        for band in template.indices { for r in 0..<visible { total += abs(all[band][y + r] - template[band][r]) } }
        costs.append(total / Double(visible * template.count))
    }
    guard let best = costs.indices.min(by: { costs[$0] < costs[$1] }), costs[best].isFinite else { return (.nan, .infinity) }
    var row = Double(rows.lowerBound + best)
    if best > 0, best < costs.count - 1, costs[best - 1].isFinite, costs[best + 1].isFinite {
        let l = costs[best - 1], c = costs[best], r = costs[best + 1], denominator = l - 2 * c + r
        if denominator > 1e-9 { row += max(-0.5, min(0.5, 0.5 * (l - r) / denominator)) }
    }
    return (row, costs[best])
}

func columns(_ minX: Double, _ maxX: Double, count: Int) -> [Range<Int>] {
    let lower = Int((minX / 2).rounded(.up)), upper = Int((maxX / 2).rounded(.down))
    let width = max(1, (upper - lower) / count)
    return (0..<count).map { lower + $0 * width ..< lower + ($0 + 1) * width }
}
func median(_ values: [Double]) -> Double? {
    guard !values.isEmpty else { return nil }
    let sorted = values.sorted(); return sorted[sorted.count / 2]
}

// MARK: - Keyboard and composer templates (chat)

struct Tracker { var template: [[Double]]; var bands: [Range<Int>]; var offset: Double; var threshold: Double }
var composerTracker: Tracker?, keyboardTracker: Tracker?
var composerHeight = 44.0
/// The frame on screen at `time`: the last one presented at or before it.
func frameIndex(at time: Double) -> Int? {
    guard frameCount > 0, appTime(0) <= time + 0.02 else { return nil }
    return (0..<frameCount).last { appTime($0) <= time + 0.002 } ?? 0
}

// MARK: - Per-frame analysis

struct FrameResult {
    var dt = 0.0
    var displacement: [Match] = [], top: [Match] = [], bottom: [Match] = []
    var model: [Double?] = []
    var flights: [Bool] = []
    var blankRun = 0.0
    var headerDiff = 0.0
    var keyboardTop: Double?, keyboardCost = Double.infinity
    var composerTop: Double?, composerCost = Double.infinity
    var newestBottom: Double?
    var flags: [String] = []
}

func listRegion(_ list: Int, composerTop: Double?) -> Range<Int> {
    let frame = lists[list].frame
    var top = frame[1] + 2, bottom = frame[1] + frame[3] - 4
    if isChat, let composerTop { bottom = min(bottom, composerTop - 3) }
    return max(0, Int(top.rounded(.up)))..<min(H, max(Int(top) + 1, Int(bottom.rounded(.down))))
}

func run() throws {
    var results = [FrameResult](repeating: FrameResult(), count: frameCount)
    let listBands = lists.map { list in columns(list.frame[0] + 14, list.frame[0] + list.frame[2] - 14, count: max(2, Int(list.frame[2] / 48))) }
    let marginBand = lists.map { list in Int((list.frame[0] + 2) / 2)..<Int((list.frame[0] + 10) / 2) }
    let cardBand = lists.map { list in columns(list.frame[0] + 30, list.frame[0] + list.frame[2] - 30, count: 1)[0] }
    let headerTop = 60, headerBottom = Int(lists.map { $0.frame[1] }.min() ?? 0) - 4

    for i in 0..<frameCount {
        var result = FrameResult()
        let time = appTime(i)
        // Blank: rows of background only inside a list.
        for list in lists.indices {
            let rows = listRegion(list, composerTop: sampleRect("composerBar", at: time)?[1])
            let background = median(rows.compactMap { y in marginBand[list].isEmpty ? nil : Double(marginBand[list].reduce(0) { $0 + pixel(i, $1, y) }) / Double(marginBand[list].count) }) ?? 0
            var run = 0, longest = 0
            for y in rows {
                var low = 255, high = 0, total = 0
                for x in listBands[list].first!.lowerBound..<listBands[list].last!.upperBound { let v = pixel(i, x, y); low = min(low, v); high = max(high, v); total += v }
                let mean = Double(total) / Double(listBands[list].last!.upperBound - listBands[list].first!.lowerBound)
                if abs(mean - background) < 2.5, high - low < 8 { run += 1; longest = max(longest, run) } else { run = 0 }
            }
            result.blankRun = max(result.blankRun, Double(longest))
        }
        if i > 0 {
            result.dt = pts[i] - pts[i - 1]
            if headerBottom > headerTop {
                var total = 0
                for y in headerTop..<headerBottom { for x in 0..<W { total += abs(pixel(i, x, y) - pixel(i - 1, x, y)) } }
                result.headerDiff = Double(total) / Double((headerBottom - headerTop) * W)
            }
        }
        results[i] = result
    }

    // Displacement per list, with the model aligned to the video.
    func measure() {
        for i in 1..<frameCount {
            var result = results[i]
            result.displacement = []; result.top = []; result.bottom = []; result.model = []; result.flights = []
            for list in lists.indices {
                let composer = [appTime(i), appTime(i - 1)].compactMap { sampleRect("composerBar", at: $0)?[1] }.min()
                let rows = listRegion(list, composerTop: composer)
                let previous = results[i - 1].displacement.count > list ? results[i - 1].displacement[list] : nil
                let predicted = previous.flatMap { $0.ok && results[i - 1].dt > 0 ? $0.shift * result.dt / results[i - 1].dt : nil }
                let a = profiles(i - 1, bands: listBands[list], rows: rows), b = profiles(i, bands: listBands[list], rows: rows)
                result.displacement.append(match(a, b, maxShift: rows.count - 100, minimumOverlap: 100, predicted: predicted))
                let third = rows.count / 3
                let topRows = rows.lowerBound..<(rows.lowerBound + third), bottomRows = (rows.upperBound - third)..<rows.upperBound
                result.top.append(match(profiles(i - 1, bands: listBands[list], rows: topRows), profiles(i, bands: listBands[list], rows: topRows), maxShift: third - 40, minimumOverlap: 40, predicted: predicted))
                result.bottom.append(match(profiles(i - 1, bands: listBands[list], rows: bottomRows), profiles(i, bands: listBands[list], rows: bottomRows), maxShift: third - 40, minimumOverlap: 40, predicted: predicted))
                result.model.append(modelDisplacement(list, from: appTime(i - 1), to: appTime(i)))
                result.flights.append(flightActive(list, at: appTime(i)))
            }
            results[i] = result
        }
    }
    progress("tracked keyboard, composer, blank and header")
    measure()
    progress("measured displacement")
    if !isDevice {
        func mismatch(_ candidate: Double) -> (Double, Int) {
            var total = 0.0, used = 0
            for i in 1..<frameCount {
                let start = base + pts[i - 1] + candidate, end = base + pts[i] + candidate
                for list in lists.indices where results[i].displacement[list].ok {
                    guard let model = modelDisplacement(list, from: start, to: end) else { continue }
                    let video = results[i].displacement[list].shift
                    if abs(video) > 0.5 || abs(model) > 0.5 { total += min(40, abs(video - model)); used += 1 }
                }
            }
            return (used > 0 ? total / Double(used) : .infinity, used)
        }
        var best = (lag: 0.0, error: Double.infinity)
        // The wall clocks agree to a few frames; search only that far.
        for step in -40...40 {
            let candidate = Double(step) * 0.004
            let (error, used) = mismatch(candidate)
            if used >= 10, error < best.error { best = (candidate, error) }
        }
        if best.error.isFinite { lag = best.lag; measure() }
        progress("aligned clock: lag \(Int(lag * 1000)) ms, mean error \(best.error)")
    }

    // Templates come from frames where the log says what is where.
    if isChat {
        let hidden = samples.first { sample in
            guard (sample["firstResponder"] as? Bool) == false, doubles(sample["composerBar"]).count == 4, let time = number(sample["time"]) else { return false }
            return time > appTime(0) + 0.05
        }
        if let hidden, let time = number(hidden["time"]), let index = frameIndex(at: time) {
            let bar = doubles(hidden["composerBar"])
            let start = Int(bar[1].rounded()) - 2
            composerHeight = bar[3]
            let bands = columns(bar[0] + 4, bar[0] + bar[2] - 4, count: 8)
            composerTracker = Tracker(template: profiles(index, bands: bands, rows: start..<min(H, start + Int(bar[3]) + 4)), bands: bands, offset: bar[1] - Double(start), threshold: 6)
        }
        // The keyboard at rest: the latest sample before a hide whose top has
        // not moved for 0.25 s.
        var restIndex: Int?
        for (i, sample) in samples.enumerated() where (sample["firstResponder"] as? Bool) == true {
            guard let top = number(sample["keyboardTop"]), let time = number(sample["time"]), top < heightPoints - 100 else { continue }
            let window = samples[..<i].reversed().prefix { (number($0["time"]) ?? 0) > time - 0.25 }
            if window.count > 5, window.allSatisfy({ abs((number($0["keyboardTop"]) ?? -1) - top) < 0.01 }) { restIndex = i; break }
        }
        if let restIndex, let time = number(samples[restIndex]["time"]), let top = number(samples[restIndex]["keyboardTop"]), let index = frameIndex(at: time) {
            let start = Int(top.rounded())
            let bands = columns(4, widthPoints - 4, count: 8)
            keyboardTracker = Tracker(template: profiles(index, bands: bands, rows: start..<min(H, start + 70)), bands: bands, offset: top - Double(start), threshold: 8)
        }
    }

    progress("templates: composer \(composerTracker != nil), keyboard \(keyboardTracker != nil)")
    progress("aligned; tracking keyboard and composer")
    for i in 0..<frameCount {
        var result = results[i]
        let time = appTime(i)
        // The model says where the composer and the keyboard should be;
        // search near there, so similar-looking rows can't be mistaken for them.
        if let composerTracker, let expected = sampleRect("composerBar", at: time)?[1] {
            let center = Int((expected - composerTracker.offset).rounded())
            let found = locate(composerTracker.template, in: i, bands: composerTracker.bands, rows: max(0, center - 30)..<min(H - 20, center + 30), minimumRows: 20)
            result.composerCost = found.cost
            if found.cost < composerTracker.threshold { result.composerTop = found.row + composerTracker.offset }
        }
        if let keyboardTracker {
            let chatBottom = lists[0].frame[1] + lists[0].frame[3]
            let expected = number(samples[sampleIndex(at: time) ?? 0]["keyboardTop"]) ?? heightPoints
            var centers = [expected]
            if i > 0, let previous = results[i - 1].keyboardTop { centers.append(previous) }
            var found = (row: Double.nan, cost: Double.infinity)
            for center in centers where center < heightPoints - 12 {
                let row = Int((center - keyboardTracker.offset).rounded())
                let candidate = locate(keyboardTracker.template, in: i, bands: keyboardTracker.bands, rows: max(0, row - 80)..<min(H - 12, row + 80), minimumRows: 12)
                if candidate.cost < found.cost { found = candidate }
            }
            if !(found.cost < keyboardTracker.threshold), expected >= chatBottom - 1 {
                // The model says hidden: look for a keyboard that is still on screen.
                found = locate(keyboardTracker.template, in: i, bands: keyboardTracker.bands, rows: Int(chatBottom - 200)..<(H - 12), minimumRows: 12)
            }
            result.keyboardCost = found.cost
            if found.cost < keyboardTracker.threshold { result.keyboardTop = found.row + keyboardTracker.offset }
        }
        // Newest row: the first card edge above the composer.
        if let composerTop = result.composerTop {
            let background = median((Int(composerTop) - 40..<Int(composerTop) - 1).flatMap { y in marginBand[0].map { pixel(i, $0, y) } }.map(Double.init)) ?? 0
            var y = Int(composerTop) + 1
            func level(_ y: Int) -> Double { Double(cardBand[0].reduce(0) { $0 + pixel(i, $1, y) }) / Double(cardBand[0].count) }
            // Up out of the composer's edge into background, then to the card.
            while y > Int(composerTop) - 8, abs(level(y) - background) > 3 { y -= 1 }
            while y > Int(composerTop) - 60, level(y) - background < 6 { y -= 1 }
            if y > Int(composerTop) - 60 {
                // Subpixel: where the level crosses halfway between the card and the background.
                let upper = level(y), lower = level(y + 1), half = background + (upper - background) / 2
                let fraction = upper - lower > 0.5 ? (upper - half) / (upper - lower) : 0
                result.newestBottom = Double(y) + 0.5 + min(1, max(0, fraction))
            }
        }
        results[i] = result
    }

    // MARK: Flags
    // Only the scenario itself is judged: from its start to the last sample.
    let windowStart = number(log["startedAt"]) ?? -Double.infinity, windowEnd = sampleTimes.last ?? .infinity
    func inWindow(_ i: Int) -> Bool { appTime(i) >= windowStart && appTime(i) <= windowEnd }
    var residuals: [Double] = results.map { $0.displacement.first.map { $0.cost.isFinite ? $0.cost : 0 } ?? 0 }
    residuals[0] = residuals.count > 1 ? residuals[1] : 0
    var keyboardMoving = [Bool](repeating: false, count: frameCount)
    for i in 1..<frameCount {
        if let a = results[i - 1].keyboardTop, let b = results[i].keyboardTop, abs(a - b) > 0.3 { keyboardMoving[i] = true }
        if (results[i - 1].keyboardTop == nil) != (results[i].keyboardTop == nil) { keyboardMoving[i] = true }
    }
    // The demo pins the composer 8 pt above the keyboard layout guide. While
    // the keyboard is hidden the guide rests on the safe area (above the tab
    // bar), not at the screen's bottom where the keyboard enters, so during
    // an animated show or hide the composer must have made the same fraction
    // of its travel as the keyboard has of its own; under a finger, the guide
    // follows the keyboard's top and the gap stays 8 pt. A frame is off when
    // it satisfies neither.
    let shownKeyboard = median(results.compactMap(\.keyboardTop).filter { $0 < heightPoints - 120 }.map { ($0 * 2).rounded() / 2 })
    func mode(_ values: [Double]) -> Double? {
        var counts: [Double: Int] = [:]
        for value in values { counts[(value * 2).rounded() / 2, default: 0] += 1 }
        return counts.max { $0.value < $1.value }?.key
    }
    let restingKeyboard = mode(results.compactMap(\.keyboardTop).filter { $0 < heightPoints - 120 }) ?? shownKeyboard
    let shownComposer = restingKeyboard.flatMap { kb in mode((0..<frameCount).compactMap { i in results[i].keyboardTop.flatMap { abs($0 - kb) < 0.6 ? results[i].composerTop : nil } }) }
    let hiddenComposer = mode((0..<frameCount).compactMap { results[$0].keyboardTop == nil ? results[$0].composerTop : nil })
    var composerDeviation = [Double?](repeating: nil, count: frameCount)
    for i in 0..<frameCount {
        guard let k = results[i].keyboardTop, let c = results[i].composerTop else { continue }
        let tracking = k - (c + composerHeight) - 8
        var deviation = tracking
        if let restingKeyboard, let shownComposer, let hiddenComposer, heightPoints - restingKeyboard > 50 {
            let progress = (heightPoints - k) / (heightPoints - restingKeyboard)
            let curve = c - (hiddenComposer + (shownComposer - hiddenComposer) * progress)
            if abs(curve) < abs(deviation) { deviation = curve }
        }
        composerDeviation[i] = deviation
    }
    // The newest row rests a fixed distance above the composer whenever the
    // list is at its newest message.
    let rowGaps = (0..<frameCount).map { i in results[i].composerTop.flatMap { c in results[i].newestBottom.map { c - $0 } } }
    func atNewest(_ i: Int) -> Bool {
        guard let newest = sampleRect("newestRow", at: appTime(i)), let bar = sampleRect("composerBar", at: appTime(i)) else { return false }
        return abs(bar[1] - (newest[1] + newest[3])) < 1.5
    }
    let restingRowGap = median((0..<frameCount).filter { atNewest($0) && !keyboardMoving[$0] }.compactMap { rowGaps[$0] })
    let quantum = isDevice ? 0.0005 : 1.0 / 600
    for i in 1..<frameCount where inWindow(i) {
        var flags: [String] = []
        let r = results[i]
        for list in lists.indices {
            let tag = lists.count > 1 ? "\(lists[list].engine):" : ""
            let match = r.displacement[list]
            func velocity(_ j: Int) -> Double? {
                guard j >= 1, j < frameCount, results[j].displacement[list].ok, results[j].dt > 0 else { return nil }
                return results[j].displacement[list].shift / results[j].dt
            }
            let modelVelocity = r.model[list].map { $0 / max(r.dt, 1e-3) }
            let before = velocity(i - 1), after = velocity(i + 1)
            let neighborsMoving = [before, after].compactMap { $0 }.filter { abs($0) > 300 }.count == 2
            let expected = (modelVelocity.map { abs($0) > 300 } ?? false) || neighborsMoving
            if r.dt > nominalInterval * 1.6, expected { flags.append("\(tag)gap\(Int((r.dt * 1000).rounded()))ms") }
            // Under a finger the list moves when touches arrive; a still frame
            // between touches is input cadence, not a rendering stall.
            let fingered = tracking(list, at: appTime(i)) || tracking(list, at: appTime(i - 1))
            if match.ok, abs(match.shift) < 0.25, neighborsMoving, !fingered { flags.append("\(tag)frozen") }
            // A jump: away from the motion of both neighbors (allowing for
            // timestamp quantization) and from what the app reported.
            if match.ok, let before, let after {
                let predicted = (before + after) / 2 * r.dt
                let tolerance = max(4, 0.3 * abs(predicted), (abs(before) + abs(after)) * quantum * 1.5)
                let videoJump = abs(match.shift - predicted) > tolerance
                let modelJump = r.model[list].map { abs(match.shift - $0) > max(4, 0.3 * abs($0), abs($0 / max(r.dt, 1e-3)) * 0.006) } ?? true
                if videoJump, modelJump, !fingered { flags.append("\(tag)jump\(String(format: "%.0f", match.shift - predicted))") }
            }
            if let model = r.model[list], match.ok, abs(match.shift - model) > max(20, 0.5 * abs(model)) { flags.append("\(tag)offmodel\(String(format: "%.0f", match.shift - model))") }
            if !match.ok, expected { flags.append("\(tag)featureless") }
            let top = r.top[list], bottom = r.bottom[list]
            if top.ok, bottom.ok, top.cost < 4, bottom.cost < 4, abs(top.shift - bottom.shift) > 2, max(abs(top.shift), abs(bottom.shift)) > 1 {
                flags.append("\(tag)nonrigid\(String(format: "%.0f", top.shift - bottom.shift))")
            }
        }
        let window = (max(1, i - 4)...min(frameCount - 1, i + 4)).filter { $0 != i }.map { residuals[$0] }
        if let typical = median(window), residuals[i] > 3, residuals[i] > 3 * max(typical, 0.5) { flags.append("pop") }
        if r.blankRun > 48 { flags.append("blank\(Int(r.blankRun))") }
        if r.headerDiff > 1.0 { flags.append("header") }
        if let deviation = composerDeviation[i], abs(deviation) > 1.5 { flags.append("kbsync\(String(format: "%+.1f", deviation))") }
        if let gap = rowGaps[i], let restingRowGap, atNewest(i), abs(gap - restingRowGap) > 1.5 { flags.append("rowgap\(String(format: "%.1f", gap - restingRowGap))") }
        results[i].flags = flags
    }

    // MARK: Output
    let start = number(log["startedAt"]) ?? appTime(0)
    var csv = "frame,pts,app_time,dt_ms"
    for list in lists.indices {
        let p = lists.count > 1 ? lists[list].engine + "_" : ""
        csv += ",\(p)d_video,\(p)v_video,\(p)d_model,\(p)v_model,\(p)residual,\(p)d_top,\(p)d_bottom,\(p)flight"
    }
    csv += ",blank_run,header_diff,keyboard_top,composer_top,composer_gap,composer_deviation,newest_bottom,row_gap,flags\n"
    func f(_ value: Double?, _ digits: Int = 2) -> String { value.map { $0.isFinite ? String(format: "%.\(digits)f", $0) : "" } ?? "" }
    for i in 0..<frameCount {
        let r = results[i]
        csv += "\(i),\(f(pts[i], 4)),\(f(appTime(i) - start, 4)),\(f(r.dt * 1000))"
        for list in lists.indices {
            if i == 0 { csv += ",,,,,,,,"; continue }
            let m = r.displacement[list]
            csv += ",\(m.ok ? f(m.shift) : ""),\(m.ok && r.dt > 0 ? f(m.shift / r.dt, 0) : ""),\(f(r.model[list])),\(f(r.model[list].map { $0 / max(r.dt, 1e-3) }, 0)),\(f(m.cost)),\(r.top[list].ok ? f(r.top[list].shift) : ""),\(r.bottom[list].ok ? f(r.bottom[list].shift) : ""),\(r.flights[list] ? 1 : 0)"
        }
        let gap = r.keyboardTop.flatMap { k in r.composerTop.map { k - ($0 + composerHeight) } }
        let rowGap = r.composerTop.flatMap { c in r.newestBottom.map { c - $0 } }
        csv += ",\(f(r.blankRun, 0)),\(f(r.headerDiff)),\(f(r.keyboardTop)),\(f(r.composerTop)),\(f(gap)),\(f(composerDeviation[i])),\(f(r.newestBottom)),\(f(rowGap)),\(r.flags.joined(separator: " "))\n"
    }
    try csv.write(toFile: "\(outDirectory)/\(name).csv", atomically: true, encoding: .utf8)

    // Summary.
    let flagged = (0..<frameCount).filter { !results[$0].flags.isEmpty }
    var kinds: [String: Int] = [:]
    for i in flagged { for flag in results[i].flags { kinds[flag.replacingOccurrences(of: "[-0-9]+(ms)?$", with: "", options: .regularExpression), default: 0] += 1 } }
    let intervals = (1..<frameCount).map { results[$0].dt * 1000 }
    // Frame rate while something moves: the recorder emits a frame only when
    // the screen changes, so idle stretches don't count.
    let motionFrames = (1..<frameCount).filter { i in
        keyboardMoving[i] || results[i].displacement.contains { $0.ok && abs($0.shift) > 0.5 }
    }
    let motionIntervals = motionFrames.map { results[$0].dt * 1000 }
    let motionFps = median(motionIntervals).map { 1000 / max($0, 0.1) } ?? 0
    var listSummaries: [[String: Any]] = []
    for list in lists.indices {
        let speeds = (1..<frameCount).compactMap { i -> Double? in let m = results[i].displacement[list]; return m.ok && results[i].dt > 0 ? abs(m.shift / results[i].dt) : nil }
        let errors = (1..<frameCount).compactMap { i -> Double? in
            let m = results[i].displacement[list]
            guard m.ok, let model = results[i].model[list] else { return nil }
            return abs(m.shift - model)
        }
        let moving = (1..<frameCount).filter { abs(results[$0].displacement[list].shift) > 0.5 && results[$0].displacement[list].ok }
        listSummaries.append([
            "engine": lists[list].engine, "inverted": lists[list].inverted,
            "maxSpeedPointsPerSecond": speeds.max() ?? 0, "movingFrames": moving.count,
            "travelPoints": (1..<frameCount).reduce(0.0) { $0 + (results[$1].displacement[list].ok ? results[$1].displacement[list].shift : 0) },
            "modelErrorMedian": median(errors) ?? 0, "modelErrorP95": errors.isEmpty ? 0 : errors.sorted()[Int(Double(errors.count - 1) * 0.95)],
            "modelErrorMax": errors.max() ?? 0,
        ])
    }
    var keyboard: [String: Any] = [:]
    if keyboardTracker != nil || composerTracker != nil {
        let gaps = (0..<frameCount).compactMap { i in results[i].keyboardTop.flatMap { k in results[i].composerTop.map { k - ($0 + composerHeight) } } }
        let deviations = composerDeviation.compactMap { $0 }.map(abs)
        let movingDeviations = (0..<frameCount).filter { keyboardMoving[$0] }.compactMap { composerDeviation[$0] }.map(abs)
        let newestFrames = (0..<frameCount).filter { atNewest($0) && inWindow($0) }
        let newestGaps = newestFrames.compactMap { rowGaps[$0] }
        let movingNewestGaps = newestFrames.filter { keyboardMoving[$0] }.compactMap { rowGaps[$0] }
        let rigid = (1..<frameCount).filter { keyboardMoving[$0] }.compactMap { i -> Double? in
            let t = results[i].top[0], b = results[i].bottom[0]
            return t.ok && b.ok && t.cost < 4 && b.cost < 4 ? abs(t.shift - b.shift) : nil
        }
        keyboard = [
            "templateFound": keyboardTracker != nil, "composerTemplateFound": composerTracker != nil,
            "framesWithKeyboard": results.filter { $0.keyboardTop != nil }.count, "keyboardMovingFrames": keyboardMoving.filter { $0 }.count,
            "keyboardTopToComposerBottomMin": gaps.min() ?? .nan, "keyboardTopToComposerBottomMax": gaps.max() ?? .nan,
            "composerOffGuideMax": deviations.max() ?? .nan, "composerOffGuideMovingMax": movingDeviations.max() ?? .nan,
            "framesAtNewest": newestFrames.count, "restingRowGap": restingRowGap ?? .nan,
            "rowGapAtNewestMin": newestGaps.min() ?? .nan, "rowGapAtNewestMax": newestGaps.max() ?? .nan,
            "rowGapAtNewestMovingMin": movingNewestGaps.min() ?? .nan, "rowGapAtNewestMovingMax": movingNewestGaps.max() ?? .nan,
            "listNonRigidDuringKeyboardMax": rigid.max() ?? .nan,
        ]
    }
    let summary: [String: Any] = [
        "clip": name, "scenario": scenario, "engine": engine, "source": isDevice ? "device in-app capture" : "simulator recordVideo",
        "frames": frameCount, "durationSeconds": pts[frameCount - 1] - pts[0],
        "effectiveFps": Double(frameCount - 1) / max(0.001, pts[frameCount - 1] - pts[0]),
        "motionFrames": motionFrames.count, "motionFps": motionFps, "motionIntervalMaxMs": motionIntervals.max() ?? 0,
        "frameIntervalMedianMs": median(intervals) ?? 0, "frameIntervalMaxMs": intervals.max() ?? 0,
        "alignmentLagSeconds": lag, "lists": listSummaries, "keyboard": keyboard,
        "maxBlankRunPoints": results.map(\.blankRun).max() ?? 0,
        "flaggedFrames": flagged.count, "flagKinds": kinds,
        "flagged": flagged.prefix(400).map { ["frame": $0, "time": appTime($0) - start, "flags": results[$0].flags] as [String: Any] },
        "events": events.compactMap { e -> [String: Any]? in
            guard let t = number(e["time"]) else { return nil }
            var copy = e; copy["time"] = t - start
            copy["frame"] = frameIndex(at: t) ?? -1
            return copy
        },
        "mainThread": log["mainThread"] ?? [:],
    ]
    func clean(_ value: Any) -> Any {
        if let d = value as? Double { return d.isFinite ? d : NSNull() }
        if let a = value as? [Any] { return a.map(clean) }
        if let m = value as? [String: Any] { return m.mapValues(clean) }
        return value
    }
    try JSONSerialization.data(withJSONObject: clean(summary), options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: "\(outDirectory)/\(name)-summary.json"))

    var markdown = "# \(name)\n\n\(scenario), \(engine), \(isDevice ? "device in-app capture" : "simulator recordVideo"): \(frameCount) frames over \(f(pts[frameCount - 1] - pts[0])) s; while moving \(motionFrames.count) frames at \(f(motionFps, 0)) fps (median interval), longest interval while moving \(f(motionIntervals.max(), 1)) ms. Clock lag \(f(lag * 1000, 0)) ms.\n\n"
    for summary in listSummaries {
        markdown += "- \(summary["engine"] ?? ""): max \(f(summary["maxSpeedPointsPerSecond"] as? Double, 0)) pt/s, travel \(f(summary["travelPoints"] as? Double, 0)) pt over \(summary["movingFrames"] ?? 0) moving frames; video vs model per frame: median \(f(summary["modelErrorMedian"] as? Double)) pt, p95 \(f(summary["modelErrorP95"] as? Double)) pt, max \(f(summary["modelErrorMax"] as? Double)) pt\n"
    }
    if !keyboard.isEmpty {
        markdown += "- keyboard: \(keyboard["framesWithKeyboard"] ?? 0) frames show it, \(keyboard["keyboardMovingFrames"] ?? 0) with it moving; keyboard top − composer bottom \(f(keyboard["keyboardTopToComposerBottomMin"] as? Double)) … \(f(keyboard["keyboardTopToComposerBottomMax"] as? Double)) pt; composer out of step with the keyboard (same curve progress, or 8 pt gap under a finger) by at most \(f(keyboard["composerOffGuideMax"] as? Double)) pt (moving ≤ \(f(keyboard["composerOffGuideMovingMax"] as? Double)))\n"
        markdown += "- newest row: at newest in \(keyboard["framesAtNewest"] ?? 0) frames; composer top − newest card bottom \(f(keyboard["rowGapAtNewestMin"] as? Double)) … \(f(keyboard["rowGapAtNewestMax"] as? Double)) pt (rest \(f(keyboard["restingRowGap"] as? Double)); while the keyboard moves \(f(keyboard["rowGapAtNewestMovingMin"] as? Double)) … \(f(keyboard["rowGapAtNewestMovingMax"] as? Double))); list top vs bottom third while the keyboard moves ≤ \(f(keyboard["listNonRigidDuringKeyboardMax"] as? Double)) pt\n"
    }
    markdown += "- longest blank run \(f(results.map(\.blankRun).max(), 0)) pt; flagged frames \(flagged.count): \(kinds.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: ", "))\n\n"
    if !flagged.isEmpty {
        markdown += "| frame | t (s) | flags |\n|---:|---:|---|\n"
        for i in flagged.prefix(60) { markdown += "| \(i) | \(f(appTime(i) - start, 3)) | \(results[i].flags.joined(separator: " ")) |\n" }
        markdown += "\n"
    }
    try markdown.write(toFile: "\(outDirectory)/\(name)-summary.md", atomically: true, encoding: .utf8)
    progress("wrote csv and summary")

    // MARK: Sheets
    let font = ["/usr/share/fonts/truetype/dejavu/DejaVuSansMono.ttf", "/System/Library/Fonts/Menlo.ttc", "/System/Library/Fonts/Supplemental/Courier New.ttf"].first { FileManager.default.fileExists(atPath: $0) } ?? ""
    func escape(_ text: String) -> String { text.replacingOccurrences(of: ":", with: "\\:").replacingOccurrences(of: "'", with: "") }
    /// Tiles the given frames (in order, `columns` across), each scaled to
    /// `width`, cropped to `crop` rows in points if given, with labels.
    func sheet(_ frames: [Int], labels: [String], columns: Int, width: Int, crop: (Double, Double)?, file: String) throws {
        guard !frames.isEmpty else { return }
        let unique = Array(Set(frames)).sorted()
        let selection = unique.map { "eq(n\\,\($0))" }.joined(separator: "+")
        let directory = NSTemporaryDirectory() + "/sheet-\(name)-\(ProcessInfo.processInfo.processIdentifier)"
        try? FileManager.default.removeItem(atPath: directory)
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: directory) }
        var filter = "select='\(selection)'"
        if let crop { filter += ",crop=iw:ih*\((crop.1 - crop.0) / heightPoints):0:ih*\(crop.0 / heightPoints)" }
        filter += ",scale=\(width):-2"
        _ = try run(["ffmpeg", "-v", "error", "-y", "-i", videoPath, "-fps_mode", "passthrough", "-vf", filter, "\(directory)/f-%05d.png"])
        // Lay out in the requested order with a label above each tile.
        var inputs: [String] = []
        for frame in frames {
            guard let position = unique.firstIndex(of: frame) else { continue }
            inputs += ["-i", "\(directory)/f-\(String(format: "%05d", position + 1)).png"]
        }
        let count = inputs.count / 2
        let rows = (count + columns - 1) / columns
        var graph = ""
        for k in 0..<count {
            let label = escape(labels[k])
            graph += "[\(k):v]pad=iw:ih+28:0:28:white,drawtext=fontfile=\(font):text='\(label)':x=4:y=6:fontsize=15:fontcolor=\(label.contains("!") ? "red" : "black")[t\(k)];"
        }
        let blanks = rows * columns - count
        if blanks > 0 {
            graph += "[t0]split=\(blanks + 1)[t0]" + (0..<blanks).map { "[b\($0)]" }.joined() + ";"
            for b in 0..<blanks { graph += "[b\(b)]drawbox=c=white:t=fill[e\(b)];" }
        }
        let cells = (0..<count).map { "[t\($0)]" } + (0..<blanks).map { "[e\($0)]" }
        var layout: [String] = []
        for k in 0..<cells.count { layout.append("\(k % columns)_\(k / columns)".replacingOccurrences(of: "_", with: "_")) }
        // xstack needs pixel offsets; tiles share one size.
        let probe = String(decoding: try run(["ffprobe", "-v", "error", "-show_entries", "stream=width,height", "-of", "csv=p=0", "\(directory)/f-00001.png"]), as: UTF8.self)
        let size = probe.split(separator: ",").compactMap { Int($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
        guard size.count == 2 else { return }
        let tileW = size[0], tileH = size[1] + 28
        let positions = (0..<cells.count).map { "\(($0 % columns) * tileW)_\(($0 / columns) * tileH)" }.joined(separator: "|")
        graph += cells.joined() + (cells.count > 1 ? "xstack=inputs=\(cells.count):layout=\(positions):fill=white" : "null")
        _ = try run(["ffmpeg", "-v", "error", "-y"] + inputs + ["-filter_complex", graph, "-frames:v", "1", file])
    }
    func label(_ i: Int) -> String {
        let r = results[i]
        var text = "#\(i) \(f(appTime(i) - start, 3))s"
        if i > 0, let m = r.displacement.first, m.ok { text += " d\(f(m.shift, 1))" }
        if !r.flags.isEmpty { text += " !" + r.flags.prefix(2).joined(separator: ",") }
        return text
    }
    // Overview: up to 40 evenly spaced frames.
    let step = max(1, frameCount / 40)
    let overview = Array(stride(from: 0, to: frameCount, by: step))
    try sheet(overview, labels: overview.map(label), columns: 10, width: 195, crop: nil, file: "\(outDirectory)/\(name)-overview.png")
    // Flagged frames with their neighbors, grouped so nearby flags share rows.
    var groups: [[Int]] = []
    for i in flagged {
        if let last = groups.last?.last, i - last <= 2 { groups[groups.count - 1].append(i) } else { groups.append([i]) }
    }
    var tiles: [Int] = []
    for group in groups.prefix(14) {
        let center = group[group.count / 2]
        tiles += [max(0, center - 1), center, min(frameCount - 1, center + 1)]
    }
    if !tiles.isEmpty {
        try sheet(tiles, labels: tiles.map(label), columns: 6, width: 260, crop: nil, file: "\(outDirectory)/\(name)-flagged.png")
    }
    // Keyboard: every moving frame (up to 48), cropped to the composer band.
    if keyboardTracker != nil {
        let moving = (0..<frameCount).filter { keyboardMoving[$0] }
        let chosen = moving.count > 48 ? stride(from: 0, to: moving.count, by: Int((Double(moving.count) / 48).rounded(.up))).map { moving[$0] } : moving
        let keyboardLabels = chosen.map { i -> String in
            let r = results[i]
            let gap = r.keyboardTop.flatMap { k in r.composerTop.map { k - ($0 + composerHeight) } }
            let rowGap = r.composerTop.flatMap { c in r.newestBottom.map { c - $0 } }
            return "#\(i) kb\(f(r.keyboardTop, 1)) g\(f(gap, 1)) r\(f(rowGap, 1))"
        }
        try sheet(chosen, labels: keyboardLabels, columns: 8, width: 260, crop: (330, heightPoints), file: "\(outDirectory)/\(name)-keyboard.png")
    }

    // Velocity plot: video (blue), model (green), flags (red), events (gray).
    let plotW = 1400, plotH = 420, margin = 40
    var image = [UInt8](repeating: 255, count: plotW * plotH * 3)
    func put(_ x: Int, _ y: Int, _ c: (UInt8, UInt8, UInt8)) {
        guard x >= 0, x < plotW, y >= 0, y < plotH else { return }
        let o = (y * plotW + x) * 3; image[o] = c.0; image[o + 1] = c.1; image[o + 2] = c.2
    }
    func line(_ x0: Int, _ y0: Int, _ x1: Int, _ y1: Int, _ c: (UInt8, UInt8, UInt8)) {
        let steps = max(abs(x1 - x0), abs(y1 - y0), 1)
        for s in 0...steps { put(x0 + (x1 - x0) * s / steps, y0 + (y1 - y0) * s / steps, c) }
    }
    let totalTime = max(0.001, pts[frameCount - 1] - pts[0])
    var peak = 100.0
    for i in 1..<frameCount { for list in lists.indices where results[i].displacement[list].ok && results[i].dt > 0 { peak = max(peak, abs(results[i].displacement[list].shift / results[i].dt)) } }
    peak = min(peak, 20000)
    func px(_ t: Double) -> Int { margin + Int((t - pts[0]) / totalTime * Double(plotW - 2 * margin)) }
    func py(_ v: Double) -> Int { plotH / 2 - Int(max(-peak, min(peak, v)) / peak * Double(plotH / 2 - margin)) }
    line(margin, plotH / 2, plotW - margin, plotH / 2, (180, 180, 180))
    for e in events { if let t = number(e["time"]) { let x = px(t - base - lag); line(x, margin / 2, x, plotH - margin / 2, (200, 200, 200)) } }
    let colors: [(UInt8, UInt8, UInt8)] = [(30, 90, 220), (220, 120, 20), (140, 40, 180)]
    for list in lists.indices {
        var previousModel: (Int, Int)?, previousVideo: (Int, Int)?
        for i in 1..<frameCount {
            let r = results[i]; let x = px(pts[i])
            if let model = r.model[list], r.dt > 0 { let p = (x, py(model / r.dt)); if let q = previousModel { line(q.0, q.1, p.0, p.1, (40, 170, 60)) }; previousModel = p }
            if r.displacement[list].ok, r.dt > 0 {
                let p = (x, py(r.displacement[list].shift / r.dt))
                if let q = previousVideo { line(q.0, q.1, p.0, p.1, colors[list % colors.count]) }
                previousVideo = p
                for dx in -1...1 { for dy in -1...1 { put(p.0 + dx, p.1 + dy, colors[list % colors.count]) } }
            }
        }
    }
    for i in flagged { let x = px(pts[i]); line(x, plotH - margin / 2 - 12, x, plotH - margin / 2, (220, 20, 20)) }
    let ppm = Data("P6\n\(plotW) \(plotH)\n255\n".utf8) + Data(image)
    let ppmPath = NSTemporaryDirectory() + "/plot-\(name).ppm"
    try ppm.write(to: URL(fileURLWithPath: ppmPath))
    let legend = escape("\(name)  screen velocity pt/s (±\(Int(peak)))  video \(lists.map(\.engine).joined(separator: "/")) = blue/orange/purple, model = green, flags = red, events = gray")
    _ = try run(["ffmpeg", "-v", "error", "-y", "-i", ppmPath, "-vf", "drawtext=fontfile=\(font):text='\(legend)':x=10:y=8:fontsize=14", "\(outDirectory)/\(name)-velocity.png"])
    try? FileManager.default.removeItem(atPath: ppmPath)
    print(markdown)
}

do { try run() } catch { FileHandle.standardError.write(Data("analyze-video: \(error)\n".utf8)); exit(1) }
