import SwiftUI
import AppKit
import UniformTypeIdentifiers
import Foundation

// MARK: - 画质档位（SSIM 来自 2940×1912 屏幕录制逐帧实测）

struct Preset: Identifiable, Equatable {
    let id: String
    let label: String
    let crf: Int
    let ssim: String
    let note: String
}

let kPresets: [Preset] = [
    Preset(id: "lossless", label: "视觉无损", crf: 16, ssim: "0.9993",
           note: "默认 · 画质几乎与原片一致，体积约缩到 1/4"),
    Preset(id: "balanced", label: "均衡", crf: 18, ssim: "0.9991",
           note: "再多省一点，细小文字仍保持锐利"),
    Preset(id: "compact", label: "更小", crf: 20, ssim: "0.9988",
           note: "适合网盘、微信、邮件传输"),
    Preset(id: "tiny", label: "极限", crf: 22, ssim: "0.9985",
           note: "细小文字边缘可能出现轻微损失"),
]

struct MediaInfo {
    var size: Int64 = 0
    var duration: Double = 0
    var width: Int = 0
    var height: Int = 0
    var codec: String = ""
    var fps: Double = 0
    var hasAudio: Bool = false
    var color: String = ""
}

enum JobStatus: String {
    case queued, running, done, error, cancelled
}

struct Job: Identifiable {
    let id = UUID()
    let url: URL
    let info: MediaInfo
    var status: JobStatus = .queued
    var progress: Double = 0
    var speed: String = ""
    var outputURL: URL?
    var outputSize: Int64 = 0
    var outputFPS: Double = 0
    var errorText: String = ""
    var ssim: Double?
    var elapsed: TimeInterval = 0
    var name: String { url.lastPathComponent }
    var savedPercent: Double? {
        guard status == .done, info.size > 0, outputSize > 0 else { return nil }
        return (1 - Double(outputSize) / Double(info.size)) * 100
    }
}

struct Settings {
    var crf: Int
    var hevc: Bool
    var keepAudio: Bool
    var verify: Bool
    var outDir: URL
}

// MARK: - 格式化

func fmtBytes(_ n: Int64) -> String {
    if n <= 0 { return "0 B" }
    let units = ["B", "KB", "MB", "GB", "TB"]
    var v = Double(n), i = 0
    while v >= 1024 && i < units.count - 1 { v /= 1024; i += 1 }
    return i < 2 ? String(format: "%.0f %@", v, units[i])
                 : String(format: "%.1f %@", v, units[i])
}

func fmtDuration(_ s: Double) -> String {
    let t = Int(s.rounded())
    return t >= 3600 ? String(format: "%d:%02d:%02d", t / 3600, (t % 3600) / 60, t % 60)
                     : String(format: "%d:%02d", t / 60, t % 60)
}

func fmtElapsed(_ s: TimeInterval) -> String {
    let t = Int(s.rounded())
    if t >= 60 { return String(format: "%d 分 %d 秒", t / 60, t % 60) }
    return "\(t) 秒"
}

func regexGroups(_ s: String, _ pattern: String) -> [String] {
    guard let re = try? NSRegularExpression(pattern: pattern),
          let m = re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) else { return [] }
    var out: [String] = []
    for i in 1..<m.numberOfRanges {
        let r = m.range(at: i)
        out.append(r.location == NSNotFound ? "" : (s as NSString).substring(with: r))
    }
    return out
}

func lastValue(_ text: String, _ key: String) -> String? {
    var found: String?
    for raw in text.split(separator: "\n") {
        let parts = raw.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
        if parts.count == 2 && String(parts[0]).trimmingCharacters(in: .whitespaces) == key {
            found = String(parts[1]).trimmingCharacters(in: .whitespaces)
        }
    }
    return found
}

// MARK: - ffmpeg 引擎

final class Engine {
    let ffmpeg: URL

    init() {
        let fm = FileManager.default
        // 1) 显式指定（命令行自测 / 换引擎时用）
        if let env = ProcessInfo.processInfo.environment["VC_FFMPEG"],
           fm.isExecutableFile(atPath: env) {
            ffmpeg = URL(fileURLWithPath: env)
            return
        }
        // 2) 应用包内 Resources（正式 .app）
        let inBundle = (Bundle.main.resourceURL ?? Bundle.main.bundleURL)
            .appendingPathComponent("ffmpeg")
        if fm.isExecutableFile(atPath: inBundle.path) {
            ffmpeg = inBundle
            return
        }
        // 3) 可执行文件同级
        let sibling = URL(fileURLWithPath: CommandLine.arguments[0])
            .deletingLastPathComponent().appendingPathComponent("ffmpeg")
        if fm.isExecutableFile(atPath: sibling.path) {
            ffmpeg = sibling
            return
        }
        ffmpeg = inBundle
    }

    var available: Bool {
        FileManager.default.isExecutableFile(atPath: ffmpeg.path)
    }

    private func capture(_ args: [String], stderr: Bool = true, timeout: TimeInterval = 60) -> String {
        let p = Process()
        p.executableURL = ffmpeg
        p.arguments = ["-nostdin"] + args
        let pipe = Pipe()
        if stderr { p.standardError = pipe; p.standardOutput = FileHandle.nullDevice }
        else { p.standardOutput = pipe; p.standardError = FileHandle.nullDevice }
        do { try p.run() } catch { return "" }
        let d = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(data: d, encoding: .utf8) ?? ""
    }

    func version() -> String {
        let s = capture(["-version"], stderr: false)
        return regexGroups(s, #"ffmpeg version\s+([\d.]+)"#).first ?? "unknown"
    }

    func probe(_ url: URL) -> MediaInfo? {
        let s = capture(["-hide_banner", "-i", url.path])
        guard !s.isEmpty else { return nil }
        var i = MediaInfo()
        i.size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)??.int64Value ?? 0
        let d = regexGroups(s, #"Duration:\s*(\d+):(\d+):([\d.]+)"#)
        if d.count >= 3 {
            i.duration = (Double(d[0]) ?? 0) * 3600 + (Double(d[1]) ?? 0) * 60 + (Double(d[2]) ?? 0)
        }
        i.codec = regexGroups(s, #"Video:\s*([^\s,]+)"#).first ?? ""
        let r = regexGroups(s, #"\b(\d{3,5})x(\d{3,5})\b"#)
        if r.count >= 2 { i.width = Int(r[0]) ?? 0; i.height = Int(r[1]) ?? 0 }
        i.fps = Double(regexGroups(s, #"([\d.]+)\s*fps"#).first ?? "") ?? 0
        i.hasAudio = s.range(of: #"Stream #\d+:\d+[^\n]*Audio:"#, options: .regularExpression) != nil
        i.color = s.contains("bt709") ? "bt709" : ""
        return i
    }

    func outputFPS(_ url: URL) -> Double {
        let s = capture(["-hide_banner", "-i", url.path])
        return Double(regexGroups(s, #"([\d.]+)\s*fps"#).first ?? "") ?? 0
    }

    func frameCheck(_ url: URL) -> (Double, Double?) {
        let fps = outputFPS(url)
        let s = capture(["-hide_banner", "-loglevel", "info", "-i", url.path,
                         "-vf", "vfrdet", "-an", "-f", "null", "-"], timeout: 1800)
        let vfr = Double(regexGroups(s, #"VFR:([0-9.]+)"#).first ?? "")
        return (fps, vfr)
    }

    func verifySSIM(src: URL, dst: URL) -> Double? {
        let s = capture(["-hide_banner", "-loglevel", "info", "-i", src.path, "-i", dst.path,
                         "-filter_complex",
                         "[0:v]setpts=PTS-STARTPTS[ref];[1:v]setpts=PTS-STARTPTS[dis];[ref][dis]ssim[out]",
                         "-map", "[out]", "-an", "-f", "null", "-"], timeout: 1800)
        return Double(regexGroups(s, #"All:\s*([0-9.]+)"#).first ?? "")
    }

    /// 转码：不缩放、不改色彩、音轨默认直接复制，并强制输出恒定帧率
    func transcode(src: URL, dst: URL, info: MediaInfo, settings: Settings,
                   audioFallback: Bool,
                   progress: @escaping (Double, String) -> Void,
                   register: @escaping (Process) -> Void,
                   isCancelled: @escaping () -> Bool) -> (Int32, String) {

        let progURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("vc_\(UUID().uuidString).progress")
        try? FileManager.default.removeItem(at: progURL)

        var a = ["-hide_banner", "-nostdin", "-loglevel", "error", "-nostats",
                 "-progress", progURL.path, "-i", src.path, "-map", "0:v:0"]
        if settings.hevc {
            a += ["-c:v", "libx265", "-preset", "medium", "-crf", String(settings.crf), "-tag:v", "hvc1"]
        } else {
            a += ["-c:v", "libx264", "-preset", "medium", "-crf", String(settings.crf), "-tag:v", "avc1"]
        }
        a += ["-pix_fmt", "yuv420p"]

        // 稳定帧率：锁定为源帧率的 CFR，并固定 MP4 时间基
        let fps = info.fps > 0 ? info.fps : 30.0
        a += ["-fps_mode", "cfr", "-r", String(format: "%.5f", fps),
              "-video_track_timescale", "30000"]

        if info.color == "bt709" {
            a += ["-color_primaries", "bt709", "-color_trc", "bt709", "-colorspace", "bt709"]
        }
        if settings.keepAudio && info.hasAudio {
            a += ["-map", "0:a:0"]
            a += audioFallback ? ["-c:a", "aac", "-b:a", "192k"] : ["-c:a", "copy"]
        } else {
            a += ["-an"]
        }
        a += ["-map_metadata", "0", "-movflags", "+faststart", "-y", dst.path]

        let p = Process()
        p.executableURL = ffmpeg
        p.arguments = a
        let errPipe = Pipe()
        p.standardError = errPipe
        p.standardOutput = FileHandle.nullDevice

        var errText = ""
        let errLock = NSLock()
        errPipe.fileHandleForReading.readabilityHandler = { fh in
            let d = fh.availableData
            if !d.isEmpty, let s = String(data: d, encoding: .utf8) {
                errLock.lock(); errText += s; errLock.unlock()
            }
        }

        do { try p.run() } catch {
            return (-1, "无法启动编码引擎：\(error.localizedDescription)")
        }
        register(p)

        var lastPct = -1.0
        while p.isRunning {
            if isCancelled() { p.terminate(); break }
            if let text = try? String(contentsOf: progURL, encoding: .utf8) {
                if let ms = lastValue(text, "out_time_ms"), let v = Double(ms), info.duration > 0 {
                    let pct = min(99.0, max(0.0, v / 1_000_000 / info.duration * 100))
                    if abs(pct - lastPct) >= 0.4 {
                        lastPct = pct
                        progress(pct, lastValue(text, "speed") ?? "")
                    }
                }
            }
            Thread.sleep(forTimeInterval: 0.3)
        }
        p.waitUntilExit()
        errPipe.fileHandleForReading.readabilityHandler = nil
        try? FileManager.default.removeItem(at: progURL)
        errLock.lock(); let captured = errText; errLock.unlock()
        return (p.terminationStatus, captured.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}

// MARK: - 任务模型

final class Model: ObservableObject {
    @Published var jobs: [Job] = []
    @Published var presetId = "lossless"
    @Published var hevc = true
    @Published var keepAudio = true
    @Published var verify = false
    @Published var outDir: URL
    @Published var engineReady = false
    @Published var engineVersion = ""

    let engine = Engine()
    private var processes: [UUID: Process] = [:]
    private var cancelled: Set<UUID> = []
    private var pending: [(UUID, Settings)] = []
    private var queueRunning = false
    private let lock = NSLock()

    private static let exts: Set<String> = [
        "mp4", "mov", "m4v", "mkv", "avi", "webm", "mts", "m2ts", "mpg", "mpeg",
        "wmv", "flv", "ts", "3gp", "mp4v"
    ]

    init() {
        let fallback = URL(fileURLWithPath: NSHomeDirectory() + "/Downloads/视频压缩输出",
                           isDirectory: true)
        if let saved = UserDefaults.standard.string(forKey: "vc_outdir") {
            outDir = URL(fileURLWithPath: saved, isDirectory: true)
        } else {
            outDir = fallback
        }
        checkEngine()
    }

    private func checkEngine() {
        DispatchQueue.global().async {
            let ok = self.engine.available
            let v = ok ? self.engine.version() : ""
            DispatchQueue.main.async {
                self.engineReady = ok
                self.engineVersion = v
            }
        }
    }

    var currentCRF: Int { kPresets.first { $0.id == presetId }?.crf ?? 16 }

    private func currentSettings() -> Settings {
        Settings(crf: currentCRF, hevc: hevc, keepAudio: keepAudio,
                 verify: verify, outDir: outDir)
    }

    /// 拖入文件 -> 立即探测 -> 立即入队开压，无需额外确认
    func add(urls: [URL]) {
        var valid: [URL] = []
        for u in urls {
            let ext = u.pathExtension.lowercased()
            guard Self.exts.contains(ext),
                  FileManager.default.fileExists(atPath: u.path) else { continue }
            if jobs.contains(where: { $0.url == u && ($0.status == .queued || $0.status == .running) }) {
                continue
            }
            valid.append(u)
        }
        guard !valid.isEmpty else { return }

        DispatchQueue.global(qos: .userInitiated).async {
            var prepared: [(URL, MediaInfo)] = []
            for u in valid {
                if let info = self.engine.probe(u) { prepared.append((u, info)) }
            }
            let settings = DispatchQueue.main.sync { self.currentSettings() }
            DispatchQueue.main.async {
                var ids: [UUID] = []
                for (u, info) in prepared {
                    let j = Job(url: u, info: info)
                    self.jobs.insert(j, at: 0)
                    ids.append(j.id)
                }
                self.enqueue(ids: ids, settings: settings)
            }
        }
    }

    private func enqueue(ids: [UUID], settings: Settings) {
        lock.lock()
        for id in ids { pending.append((id, settings)) }
        let shouldStart = !queueRunning
        if shouldStart { queueRunning = true }
        lock.unlock()
        if shouldStart {
            DispatchQueue.global(qos: .userInitiated).async { self.drainQueue() }
        }
    }

    private func drainQueue() {
        while true {
            lock.lock()
            guard !pending.isEmpty else {
                queueRunning = false
                lock.unlock()
                return
            }
            let item = pending.removeFirst()
            lock.unlock()
            runJob(id: item.0, settings: item.1)
        }
    }

    private func snapshot(id: UUID) -> Job? {
        if Thread.isMainThread { return jobs.first { $0.id == id } }
        var result: Job?
        DispatchQueue.main.sync { result = self.jobs.first { $0.id == id } }
        return result
    }

    private func update(id: UUID, _ block: @escaping (inout Job) -> Void) {
        if Thread.isMainThread {
            if let i = jobs.firstIndex(where: { $0.id == id }) { block(&jobs[i]) }
        } else {
            DispatchQueue.main.async {
                if let i = self.jobs.firstIndex(where: { $0.id == id }) { block(&self.jobs[i]) }
            }
        }
    }

    private func isCancelled(_ id: UUID) -> Bool {
        lock.lock(); let c = cancelled.contains(id); lock.unlock()
        return c
    }

    private func uniqueOutput(dir: URL, stem: String) -> URL {
        var u = dir.appendingPathComponent(stem + ".mp4")
        var n = 2
        while FileManager.default.fileExists(atPath: u.path) {
            u = dir.appendingPathComponent("\(stem)-\(n).mp4")
            n += 1
        }
        return u
    }

    private func runJob(id: UUID, settings: Settings) {
        guard let job = snapshot(id: id) else { return }
        update(id: id) { $0.status = .running; $0.progress = 0; $0.errorText = "" }
        let started = Date()
        try? FileManager.default.createDirectory(at: settings.outDir, withIntermediateDirectories: true)
        let dst = uniqueOutput(dir: settings.outDir,
                               stem: job.url.deletingPathExtension().lastPathComponent + "_压缩版")

        let progressCB: (Double, String) -> Void = { pct, spd in
            self.update(id: id) { $0.progress = pct; $0.speed = spd }
        }
        let registerCB: (Process) -> Void = { p in
            self.lock.lock(); self.processes[id] = p; self.lock.unlock()
        }
        let cancelCB: () -> Bool = { self.isCancelled(id) }

        var (code, err) = engine.transcode(
            src: job.url, dst: dst, info: job.info, settings: settings, audioFallback: false,
            progress: progressCB, register: registerCB, isCancelled: cancelCB)

        // 部分源音轨（PCM 等）无法直接复制进 MP4，自动降级为 AAC 再试一次
        if code != 0 && settings.keepAudio && job.info.hasAudio && !isCancelled(id) {
            try? FileManager.default.removeItem(at: dst)
            (code, err) = engine.transcode(
                src: job.url, dst: dst, info: job.info, settings: settings, audioFallback: true,
                progress: progressCB, register: registerCB, isCancelled: cancelCB)
        }
        lock.lock(); processes.removeValue(forKey: id); lock.unlock()

        if isCancelled(id) {
            try? FileManager.default.removeItem(at: dst)
            update(id: id) { $0.status = .cancelled; $0.speed = "" }
            return
        }
        guard code == 0 else {
            update(id: id) {
                $0.status = .error
                $0.speed = ""
                $0.errorText = err.isEmpty ? "转码失败（退出码 \(code)）" : String(err.suffix(400))
            }
            return
        }

        let size = (try? FileManager.default.attributesOfItem(atPath: dst.path)[.size] as? NSNumber)??.int64Value ?? 0
        let fps = engine.outputFPS(dst)
        var ssim: Double? = nil
        if settings.verify {
            update(id: id) { $0.speed = "画质校验中" }
            ssim = engine.verifySSIM(src: job.url, dst: dst)
        }
        update(id: id) {
            $0.status = .done
            $0.progress = 100
            $0.speed = ""
            $0.outputURL = dst
            $0.outputSize = size
            $0.outputFPS = fps
            $0.ssim = ssim
            $0.elapsed = Date().timeIntervalSince(started)
        }
    }

    func cancel(id: UUID) {
        lock.lock()
        cancelled.insert(id)
        let p = processes[id]
        lock.unlock()
        p?.terminate()
        update(id: id) { if $0.status == .queued { $0.status = .cancelled } }
    }

    func remove(id: UUID) {
        if let j = jobs.first(where: { $0.id == id }), j.status == .running {
            cancel(id: id)
        }
        jobs.removeAll { $0.id == id }
    }

    func clearFinished() {
        jobs.removeAll { [.done, .error, .cancelled].contains($0.status) }
    }

    var hasFinished: Bool { jobs.contains { [.done, .error, .cancelled].contains($0.status) } }

    func reveal(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    func chooseOutputDir() {
        let p = NSOpenPanel()
        p.canChooseFiles = false
        p.canChooseDirectories = true
        p.canCreateDirectories = true
        p.allowsMultipleSelection = false
        p.message = "选择压缩后视频的保存位置"
        p.begin { [weak self] resp in
            if resp == .OK, let u = p.url {
                self?.outDir = u
                UserDefaults.standard.set(u.path, forKey: "vc_outdir")
            }
        }
    }
}

// MARK: - 文件选择 / 拖放

enum FileDialog {
    static func pickVideos(_ done: @escaping ([URL]) -> Void) {
        let p = NSOpenPanel()
        p.canChooseFiles = true
        p.canChooseDirectories = false
        p.allowsMultipleSelection = true
        p.message = "选择要压缩的视频（选好即开始）"
        p.begin { if $0 == .OK { done(p.urls) } }
    }
}

enum DropHandler {
    static func load(_ providers: [NSItemProvider], done: @escaping ([URL]) -> Void) {
        let group = DispatchGroup()
        var urls: [URL] = []
        let lock = NSLock()
        for p in providers where p.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            group.enter()
            p.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                var u: URL?
                if let url = item as? URL { u = url }
                else if let data = item as? Data { u = URL(dataRepresentation: data, relativeTo: nil) }
                else if let str = item as? String { u = URL(string: str) }
                if let u = u { lock.lock(); urls.append(u); lock.unlock() }
                group.leave()
            }
        }
        group.notify(queue: .main) { done(urls) }
    }
}

// MARK: - 界面

struct DropZone: View {
    let active: Bool
    let onURLs: ([URL]) -> Void

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 14)
                .fill(active ? Color.accentColor.opacity(0.09)
                             : Color(nsColor: .controlBackgroundColor))
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(active ? Color.accentColor : Color(nsColor: .separatorColor),
                              style: StrokeStyle(lineWidth: 1.5, dash: [7, 5]))
            VStack(spacing: 9) {
                Image(systemName: active ? "arrow.down.circle.fill" : "arrow.down.to.line.circle")
                    .font(.system(size: 29, weight: .light))
                    .foregroundStyle(active ? Color.accentColor : Color.secondary)
                Text(active ? "松开即可开始压缩" : "把视频拖到这里，立即开始压缩")
                    .font(.system(size: 15, weight: .medium))
                Text("支持一次拖入多个 · MP4 / MOV / MKV / AVI / WebM")
                    .font(.caption).foregroundStyle(.secondary)
                Button("或点这里选择文件") { FileDialog.pickVideos(onURLs) }
                    .buttonStyle(.link).font(.callout)
            }
            .padding(18)
        }
        .frame(height: 164)
    }
}

struct JobRow: View {
    let job: Job
    @EnvironmentObject var model: Model

    private var meta: String {
        var p: [String] = []
        if job.info.width > 0 { p.append("\(job.info.width)×\(job.info.height)") }
        if job.info.fps > 0 { p.append(String(format: "%.2f fps", job.info.fps)) }
        if job.info.duration > 0 { p.append(fmtDuration(job.info.duration)) }
        p.append(fmtBytes(job.info.size))
        return p.joined(separator: " · ")
    }

    @ViewBuilder private var badge: some View {
        let (text, color): (String, Color) = {
            switch job.status {
            case .queued: return ("排队中", .secondary)
            case .running: return ("压缩中", .accentColor)
            case .done: return ("已完成", Color(nsColor: .systemGreen))
            case .error: return ("失败", .red)
            case .cancelled: return ("已取消", .secondary)
            }
        }()
        Text(text).font(.caption).fontWeight(.medium)
            .foregroundStyle(color)
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(Capsule().fill(color.opacity(0.12)))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 11) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .windowBackgroundColor))
                    Image(systemName: "film").foregroundStyle(.secondary)
                }.frame(width: 34, height: 34)
                VStack(alignment: .leading, spacing: 2) {
                    Text(job.name).font(.callout).fontWeight(.medium)
                        .lineLimit(1).truncationMode(.middle)
                    Text(meta).font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 6)
                badge
                Button {
                    model.remove(id: job.id)
                } label: {
                    Image(systemName: "xmark").font(.caption).foregroundStyle(.tertiary)
                }.buttonStyle(.plain)
            }

            if job.status == .running || job.status == .queued {
                ProgressView(value: job.status == .queued ? 0 : job.progress, total: 100)
                    .padding(.top, 10)
                HStack(spacing: 8) {
                    Text(job.status == .queued ? "等待队列"
                         : (job.speed == "画质校验中" ? "画质校验中"
                            : String(format: "%.0f%%", job.progress)))
                    Spacer()
                    if !job.speed.isEmpty && job.speed != "画质校验中" { Text(job.speed) }
                    if job.status == .running {
                        Button("取消") { model.cancel(id: job.id) }
                            .buttonStyle(.link).font(.caption)
                    }
                }
                .font(.caption).foregroundStyle(.secondary).padding(.top, 5)
            }

            if job.status == .done {
                HStack(spacing: 8) {
                    Text(fmtBytes(job.info.size)).font(.callout).foregroundStyle(.secondary)
                    Image(systemName: "arrow.right").font(.caption).foregroundStyle(.tertiary)
                    Text(fmtBytes(job.outputSize))
                        .font(.system(size: 16, weight: .semibold)).monospacedDigit()
                    if let s = job.savedPercent {
                        Text(String(format: "−%.1f%%", s))
                            .font(.caption).fontWeight(.semibold)
                            .padding(.horizontal, 8).padding(.vertical, 3)
                            .background(Capsule().fill(Color(nsColor: .systemGreen).opacity(0.14)))
                            .foregroundStyle(Color(nsColor: .systemGreen))
                    }
                    Spacer()
                    if let u = job.outputURL {
                        Button("在 Finder 显示") { model.reveal(u) }
                            .buttonStyle(.link).font(.caption)
                    }
                }.padding(.top, 11)
                HStack(spacing: 5) {
                    Text(String(format: "%.2f fps 恒定", job.outputFPS > 0 ? job.outputFPS : job.info.fps))
                    if let s = job.ssim { Text("· SSIM " + String(format: "%.4f", s)) }
                    Text("· 用时 " + fmtElapsed(job.elapsed))
                }.font(.caption).foregroundStyle(.secondary).padding(.top, 4)
            }

            if job.status == .error {
                Text(job.errorText).font(.caption).foregroundStyle(.red)
                    .lineLimit(3).padding(.top, 9)
                HStack {
                    Spacer()
                    Button("重试") {
                        model.add(urls: [job.url])
                        model.remove(id: job.id)
                    }.buttonStyle(.link).font(.caption)
                }.padding(.top, 3)
            }
        }
        .padding(13)
        .background(RoundedRectangle(cornerRadius: 11).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 11)
            .strokeBorder(Color(nsColor: .separatorColor).opacity(0.55), lineWidth: 0.5))
    }
}

struct SettingsView: View {
    @EnvironmentObject var model: Model
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("压缩设置").font(.title2).fontWeight(.semibold)
            Text("只影响之后拖入的视频，已在队列中的任务保持原设置。")
                .font(.caption).foregroundStyle(.secondary)
            Divider()

            Text("画质档位").font(.headline)
            ForEach(kPresets) { p in
                Button {
                    model.presetId = p.id
                } label: {
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: model.presetId == p.id
                              ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(model.presetId == p.id ? Color.accentColor : Color.secondary)
                            .padding(.top, 2)
                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Text(p.label).fontWeight(.medium)
                                Spacer()
                                Text("CRF \(p.crf)").font(.caption).foregroundStyle(.secondary)
                            }
                            Text(p.note).font(.caption).foregroundStyle(.secondary)
                            Text("实测 SSIM \(p.ssim)").font(.caption2).foregroundStyle(.tertiary)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(9)
                    .background(RoundedRectangle(cornerRadius: 8)
                        .fill(model.presetId == p.id
                              ? Color.accentColor.opacity(0.09)
                              : Color(nsColor: .controlBackgroundColor)))
                }.buttonStyle(.plain)
            }

            Divider()
            Text("输出编码").font(.headline)
            Picker("", selection: $model.hevc) {
                Text("HEVC · 同画质体积更小（推荐）").tag(true)
                Text("H.264 · 兼容老旧播放器").tag(false)
            }.pickerStyle(.radioGroup)

            Toggle("保留原音轨（直接复制，不二次编码）", isOn: $model.keepAudio)
            Toggle("压缩后做 SSIM 画质校验（会多花时间）", isOn: $model.verify)

            Divider()
            HStack {
                Spacer()
                Button("完成") { dismiss() }
                    .buttonStyle(.borderedProminent).controlSize(.large)
            }
        }
        .padding(24)
        .frame(width: 430)
    }
}

struct ContentView: View {
    @EnvironmentObject var model: Model
    @State private var dropActive = false
    @State private var showSettings = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("把视频拖进来，立即开始压缩")
                        .font(.system(size: 20, weight: .semibold))
                    Text("画质优先 · 恒定帧率 · 保留原分辨率与音轨 · 全部在本机完成")
                        .font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                HStack(spacing: 6) {
                    Circle().fill(model.engineReady ? Color(nsColor: .systemGreen) : Color.red)
                        .frame(width: 7, height: 7)
                    Text(model.engineReady ? "引擎就绪" : "引擎缺失")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 26).padding(.top, 22).padding(.bottom, 18)

            DropZone(active: dropActive) { model.add(urls: $0) }
                .padding(.horizontal, 26)

            HStack(spacing: 8) {
                Text("输出位置").font(.caption).foregroundStyle(.secondary)
                Text(model.outDir.path).font(.caption).lineLimit(1).truncationMode(.middle)
                Spacer()
                Button("更改…") { model.chooseOutputDir() }
                    .buttonStyle(.link).font(.caption)
            }
            .padding(.horizontal, 26).padding(.top, 13)

            Divider().padding(.vertical, 16)

            HStack {
                Text("任务").font(.headline)
                Text("\(model.jobs.count)").font(.caption).foregroundStyle(.secondary)
                Spacer()
                if model.hasFinished {
                    Button("清空已完成") { model.clearFinished() }
                        .buttonStyle(.link).font(.callout)
                }
            }.padding(.horizontal, 26).padding(.bottom, 8)

            if model.jobs.isEmpty {
                VStack(spacing: 9) {
                    Image(systemName: "tray").font(.title).foregroundStyle(.tertiary)
                    Text("还没有任务").font(.callout).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 9) {
                        ForEach(model.jobs) { job in JobRow(job: job) }
                    }
                    .padding(.horizontal, 26).padding(.bottom, 10)
                }
            }

            HStack(spacing: 7) {
                Image(systemName: "lock.shield").font(.caption).foregroundStyle(.tertiary)
                Text("本机处理 · 文件不上传").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Text("\(model.hevc ? "HEVC" : "H.264") CRF \(model.currentCRF) · 强制恒定帧率 · ffmpeg \(model.engineVersion)")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 26).padding(.vertical, 11)
            .background(Color(nsColor: .controlBackgroundColor))
        }
        .frame(minWidth: 740, idealWidth: 860, minHeight: 560, idealHeight: 680)
        .background(Color(nsColor: .windowBackgroundColor))
        // 整个窗口都是拖放目标：文件拖进界面任意位置即开始压缩
        .onDrop(of: [.fileURL], isTargeted: $dropActive) { providers in
            DropHandler.load(providers) { urls in
                if !urls.isEmpty { model.add(urls: urls) }
            }
            return true
        }
        .overlay(
            RoundedRectangle(cornerRadius: 0)
                .strokeBorder(dropActive ? Color.accentColor : Color.clear, lineWidth: 3)
                .allowsHitTesting(false)
        )
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { showSettings = true } label: {
                    Label("设置", systemImage: "slider.horizontal.3")
                }
            }
        }
        .sheet(isPresented: $showSettings) {
            SettingsView().environmentObject(model)
        }
        .onReceive(NotificationCenter.default.publisher(for: .vcOpenURLs)) { note in
            if let urls = note.object as? [URL] { model.add(urls: urls) }
        }
    }
}

extension Notification.Name {
    static let vcOpenURLs = Notification.Name("vcOpenURLs")
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        if let i = CommandLine.arguments.firstIndex(of: "--selftest"),
           i + 1 < CommandLine.arguments.count {
            DispatchQueue.global().async { SelfTest.run(path: CommandLine.arguments[i + 1]) }
        }
    }

    // 拖到 Dock 图标上也能直接开始压缩
    func application(_ sender: NSApplication, openFiles filenames: [String]) {
        let urls = filenames.map { URL(fileURLWithPath: $0) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            NotificationCenter.default.post(name: .vcOpenURLs, object: urls)
        }
        sender.reply(toOpenOrPrint: .success)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

// MARK: - 命令行自测入口（验证引擎、画质、恒定帧率）

enum SelfTest {
    static func run(path: String) {
        let e = Engine()
        guard e.available else { print("SELFTEST FAIL: ffmpeg missing at \(e.ffmpeg.path)"); exit(1) }
        let url = URL(fileURLWithPath: path)
        guard let info = e.probe(url) else { print("SELFTEST FAIL: probe"); exit(1) }
        print("SELFTEST probe: \(info.width)x\(info.height) \(info.fps)fps "
              + "\(String(format: "%.2f", info.duration))s \(info.size) bytes audio=\(info.hasAudio)")
        fflush(stdout)

        let dir = URL(fileURLWithPath: "/tmp/vc_selftest", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let dst = dir.appendingPathComponent("out.mp4")
        try? FileManager.default.removeItem(at: dst)
        let s = Settings(crf: 16, hevc: true, keepAudio: true, verify: true, outDir: dir)
        let t = Date()
        let (code, err) = e.transcode(src: url, dst: dst, info: info, settings: s,
                                      audioFallback: false, progress: { _, _ in },
                                      register: { _ in }, isCancelled: { false })
        guard code == 0 else { print("SELFTEST FAIL: \(err)"); exit(1) }
        let outSize = (try? FileManager.default.attributesOfItem(atPath: dst.path)[.size] as? NSNumber)??.int64Value ?? 0
        let ssim = e.verifySSIM(src: url, dst: dst)
        let (fps, vfr) = e.frameCheck(dst)
        print("SELFTEST OK: \(info.size) -> \(outSize), saved "
              + String(format: "%.1f%%", (1 - Double(outSize) / Double(info.size)) * 100))
        print("SELFTEST SSIM: \(ssim.map { String(format: "%.6f", $0) } ?? "n/a")"
              + " | fps: \(fps) | VFR: \(vfr.map { String(format: "%.6f", $0) } ?? "n/a")"
              + " | elapsed \(String(format: "%.1f", Date().timeIntervalSince(t)))s")
        fflush(stdout)
        exit(0)
    }
}

#if !VC_CLI
@main
struct VideoCompressorApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var model = Model()

    var body: some Scene {
        WindowGroup {
            ContentView().environmentObject(model)
        }
        .windowResizability(.contentSize)
        .commands {
            CommandGroup(replacing: .newItem) { }
            CommandGroup(replacing: .appInfo) {
                Button("关于视频压缩转换器") {
                    NSApplication.shared.orderFrontStandardAboutPanel(nil)
                }
            }
        }
    }
}
#endif
