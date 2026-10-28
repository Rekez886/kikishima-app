// 发言者定位：截取会议窗口，检测平台的「正在发言」高亮框位置
// Zoom = 绿色描边格子；Google Meet = 蓝色描边格子。色值随版本变，带校准日志。
import Foundation
import ScreenCaptureKit
import CoreImage
import CoreMedia
import AppKit
import Vision
import OSLog

private let logger = Logger(subsystem: "com.kikishima.mac", category: "SpeakerLocator")

/// 平台高亮色档案：用 HSV 色相区间判色（缩图后描边与周围混色，RGB 距离失效，色相稳定）
struct PlatformProfile {
    let name: String
    let hueMin: Double, hueMax: Double
    let minSat: Double
    let minValue: Int

    func matches(_ r: Int, _ g: Int, _ b: Int) -> Bool {
        let mx = max(r, g, b), mn = min(r, g, b)
        guard mx > minValue, mx - mn > 50 else { return false }
        let d = Double(mx - mn)
        var hue: Double
        if mx == g { hue = 120 + 60 * Double(b - r) / d }
        else if mx == r { hue = 60 * Double(g - b) / d }
        else { hue = 240 + 60 * Double(r - g) / d }
        if hue < 0 { hue += 360 }
        return hue >= hueMin && hue <= hueMax && d / Double(mx) > minSat
    }
}

let platformProfiles: [PlatformProfile] = [
    // Zoom 发言者黄绿框：实测 (158,240,80) ≈ hue 90°，离线两张截图验证通过
    PlatformProfile(name: "zoom", hueMin: 68, hueMax: 118, minSat: 0.4, minValue: 120),
    // Google Meet 发言者蓝框（Google Blue ≈ hue 215°），待实测定标
    PlatformProfile(name: "meet", hueMin: 200, hueMax: 232, minSat: 0.45, minValue: 120),
]

/// 检测结果：会议窗口内的发言者格子（归一化坐标，原点左上）+ 窗口在屏幕上的位置
struct SpeakerLocation {
    let tileRect: CGRect       // 归一化 0-1，相对会议窗口
    let faceRect: CGRect?      // 发言者人脸（归一化，原点左上），气泡锚点
    let windowFrame: CGRect    // 会议窗口的屏幕坐标（CG 坐标系，原点左上）
    let platform: String
}

@MainActor
final class SpeakerLocator: NSObject, SCStreamOutput {
    var onLocation: ((SpeakerLocation?) -> Void)?
    var calibrationLogging = true   // 首轮采色定标用

    private var stream: SCStream?
    private var windowFrame: CGRect = .zero
    private var platformName = ""
    private let ciContext = CIContext(options: [.workingColorSpace: NSNull()])
    private var frameCount = 0
    private var lastFrame: CIImage?      // 调试快照用：检测器眼里的最后一帧（只在 debugBubble 时保留，否则会一直扣住 SCStream 的缓冲）
    private var gen = 0                  // 启停代数：start 的 await 期间被 stop 了，就把刚建的 stream 停掉
    private var lastRect: CGRect?
    nonisolated(unsafe) private var captureDebugFrames = false

    /// 把最后一帧 + 检测结果写成 PNG（定标用）；返回文件 URL
    func saveDebugSnapshot(to dir: URL) -> URL? {
        guard let frame = lastFrame else { return nil }
        let rep = NSCIImageRep(ciImage: frame)
        let img = NSImage(size: rep.size); img.addRepresentation(rep)
        guard let tiff = img.tiffRepresentation, let bmp = NSBitmapImageRep(data: tiff) else { return nil }
        // 画检测框
        NSGraphicsContext.saveGraphicsState()
        if let ctx = NSGraphicsContext(bitmapImageRep: bmp) {
            NSGraphicsContext.current = ctx
            if let r = lastRect {
                let w = CGFloat(bmp.pixelsWide), h = CGFloat(bmp.pixelsHigh)
                NSColor.red.setStroke()
                let p = NSBezierPath(rect: NSRect(x: r.minX * w, y: (1 - r.maxY) * h, width: r.width * w, height: r.height * h))
                p.lineWidth = 4; p.stroke()
            }
            ctx.flushGraphics()
        }
        NSGraphicsContext.restoreGraphicsState()
        guard let png = bmp.representation(using: .png, properties: [:]) else { return nil }
        let df = DateFormatter(); df.dateFormat = "yyyy-MM-dd HH.mm.ss"
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("调试快照 \(df.string(from: Date())) \(platformName) \(lastRect == nil ? "未检出" : "检出").png")
        try? png.write(to: url)
        return url
    }

    func start() async {
        gen += 1
        let myGen = gen
        captureDebugFrames = CaptionState.shared.debugBubble
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            guard gen == myGen else { return }
            // 找会议窗口：Zoom app 或 浏览器里的 Meet 标签
            let candidates = content.windows.filter { w in
                guard w.frame.width > 400, w.frame.height > 300 else { return false }
                let bundle = w.owningApplication?.bundleIdentifier ?? ""
                let title = w.title ?? ""
                if bundle.contains("zoom") { return true }
                if title.localizedCaseInsensitiveContains("meet") && Self.isBrowser(bundle) { return true }
                return false
            }
            // 兜底（测试用）：没有会议窗口时，优先标题含 YouTube 的浏览器窗口，再退最大浏览器窗口
            let browsers = content.windows.filter { w in
                guard w.frame.width > 500, w.frame.height > 350 else { return false }
                return Self.isBrowser(w.owningApplication?.bundleIdentifier ?? "")
            }
            let youtube = browsers.filter { ($0.title ?? "").localizedCaseInsensitiveContains("youtube") }
            let pool = candidates.isEmpty ? (youtube.isEmpty ? browsers : youtube) : candidates
            guard let target = pool.max(by: { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }) else {
                logger.info("未找到 Zoom/Meet/浏览器窗口")
                onLocation?(nil)
                return
            }
            windowFrame = target.frame
            platformName = (target.owningApplication?.bundleIdentifier ?? "").contains("zoom") ? "zoom" : "meet"
            logger.info("锁定会议窗口: \(self.platformName, privacy: .public)")

            let filter = SCContentFilter(desktopIndependentWindow: target)
            let config = SCStreamConfiguration()
            // 描边只有几像素粗：截取分辨率不能太低，否则缩图后消失
            config.width = 1280
            config.height = Int(1280 * target.frame.height / target.frame.width)
            config.minimumFrameInterval = CMTime(value: 1, timescale: 4)   // 4fps 足够
            config.capturesAudio = false
            config.showsCursor = false

            let s = SCStream(filter: filter, configuration: config, delegate: nil)
            try s.addStreamOutput(self, type: .screen, sampleHandlerQueue: DispatchQueue(label: "speaker-locator"))
            try await s.startCapture()
            guard gen == myGen else { try? await s.stopCapture(); return }   // 等待期间用户已停止：别让这条流成为没人管的孤儿
            stream = s
        } catch {
            logger.error("SpeakerLocator 启动失败: \(error.localizedDescription, privacy: .public)")
            onLocation?(nil)
        }
    }

    static func isBrowser(_ bundle: String) -> Bool {
        bundle.contains("Chrome") || bundle.contains("Safari")
            || bundle.contains("thebrowser")   // Arc / Dia (company.thebrowser.*)
            || bundle.contains("Arc") || bundle.contains("firefox") || bundle.contains("Edge")
    }

    func stop() {
        gen += 1
        let s = stream
        stream = nil
        Task { try? await s?.stopCapture() }
    }

    nonisolated func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, let pixelBuffer = sampleBuffer.imageBuffer else { return }
        // 主判据：「放得最大的人」= 演讲者视图里平台放大的当前发言者（尺寸不受配色/版本影响，免定标）
        // 画廊视图中窗口大小相同，无法判定主导者时不显示。绿框检测保留为备用（detectHighlight）。
        let faces = Self.detectAllFaces(pixelBuffer: pixelBuffer)
        let dominant = Self.dominantFace(faces)
        let snapshot = captureDebugFrames ? CIImage(cvPixelBuffer: pixelBuffer) : nil
        Task { @MainActor in
            if let snapshot { self.lastFrame = snapshot }
            self.lastRect = dominant
        }
        guard let face = dominant else {
            Task { @MainActor in self.onLocation?(nil) }
            return
        }
        let tile = face.insetBy(dx: -face.width * 0.6, dy: -face.height * 0.6)
            .intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
        Task { @MainActor in
            self.frameCount += 1
            self.onLocation?(SpeakerLocation(tileRect: tile, faceRect: face,
                                             windowFrame: self.windowFrame, platform: self.platformName))
        }
    }

    /// 全帧所有人脸（归一化，原点左上）
    nonisolated static func detectAllFaces(pixelBuffer: CVPixelBuffer) -> [CGRect] {
        let request = VNDetectFaceRectanglesRequest()
        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, options: [:])
        guard (try? handler.perform([request])) != nil, let faces = request.results else { return [] }
        return faces.map { f in
            CGRect(x: f.boundingBox.origin.x,
                   y: 1 - f.boundingBox.origin.y - f.boundingBox.height,
                   width: f.boundingBox.width, height: f.boundingBox.height)
        }
    }

    /// 主导人脸：最大者面积 ≥ 第二名 1.8 倍，且宽度 ≥ 画面 10%；否则 nil（画廊视图/共享屏幕不显示）
    nonisolated static func dominantFace(_ faces: [CGRect]) -> CGRect? {
        let sorted = faces.sorted { $0.width * $0.height > $1.width * $1.height }
        guard let first = sorted.first, first.width >= 0.10 else { return nil }
        if sorted.count > 1 {
            let a1 = first.width * first.height, a2 = sorted[1].width * sorted[1].height
            guard a1 >= a2 * 1.8 else { return nil }
        }
        return first
    }

    /// 全帧找人脸，挑中心落在发言者格子里、面积最大的那张（Vision 原点左下 → 翻转为左上）
    nonisolated static func detectFace(pixelBuffer: CVPixelBuffer, inTile tile: CGRect) -> CGRect? {
        let request = VNDetectFaceRectanglesRequest()
        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, options: [:])
        guard (try? handler.perform([request])) != nil, let faces = request.results, !faces.isEmpty else { return nil }
        let flipped: [CGRect] = faces.map { f in
            CGRect(x: f.boundingBox.origin.x,
                   y: 1 - f.boundingBox.origin.y - f.boundingBox.height,
                   width: f.boundingBox.width, height: f.boundingBox.height)
        }
        return flipped
            .filter { tile.insetBy(dx: -0.02, dy: -0.02).contains(CGPoint(x: $0.midX, y: $0.midY)) }
            .max { $0.width * $0.height < $1.width * $1.height }
    }

    /// 高亮框检测：缩到 400 宽（描边只有几像素粗，缩太小会消失），按平台特征色做掩码，取包围盒
    nonisolated static func detectHighlight(pixelBuffer: CVPixelBuffer, ciContext: CIContext) -> CGRect? {
        let ci = CIImage(cvPixelBuffer: pixelBuffer)
        let scale = 960.0 / ci.extent.width
        let small = ci.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let w = Int(small.extent.width), h = Int(small.extent.height)
        guard w > 0, h > 0 else { return nil }
        var pixels = [UInt8](repeating: 0, count: w * h * 4)
        ciContext.render(small, toBitmap: &pixels, rowBytes: w * 4,
                         bounds: CGRect(x: 0, y: 0, width: w, height: h),
                         format: .RGBA8, colorSpace: CGColorSpaceCreateDeviceRGB())

        var best: (rect: CGRect, score: Int)?
        for profile in platformProfiles {
            // 掩码 + 行/列投影：矩形描边在投影上是两对长尖峰，零散图标只是小鼓包
            var mask = [Bool](repeating: false, count: w * h)
            var rows = [Int](repeating: 0, count: h)
            var cols = [Int](repeating: 0, count: w)
            var total = 0
            for y in 0..<h {
                for x in 0..<w {
                    let i = (y * w + x) * 4
                    if profile.matches(Int(pixels[i]), Int(pixels[i+1]), Int(pixels[i+2])) {
                        mask[y * w + x] = true; rows[y] += 1; cols[x] += 1; total += 1
                    }
                }
            }
            guard total > 80 else { continue }
            // 候选横边：连续行的绿像素数 ≥ 窗口宽 6%；候选竖边：连续列 ≥ 窗口高 8%
            let hBands = Self.bands(rows, threshold: max(12, w * 6 / 100))
            let vBands = Self.bands(cols, threshold: max(10, h * 8 / 100))
            guard hBands.count >= 2, vBands.count >= 2 else { continue }
            // 枚举上下边×左右边组合，校验：横边上的绿像素确实横跨左右边位置
            for ti in 0..<hBands.count {
                for bi in (ti + 1)..<hBands.count {
                    let top = hBands[ti], bottom = hBands[bi]
                    guard bottom.center - top.center > h / 12 else { continue }
                    for li in 0..<vBands.count {
                        for ri in (li + 1)..<vBands.count {
                            let left = vBands[li], right = vBands[ri]
                            guard right.center - left.center > w / 12 else { continue }
                            // 一致性：顶边那一行在 [left, right] 区间内的绿像素占比
                            let span = max(1, right.center - left.center)
                            var hit = 0, hitB = 0
                            for x in left.center...right.center {
                                if mask[top.center * w + x] || mask[min(h - 1, top.center + 1) * w + x] || mask[max(0, top.center - 1) * w + x] { hit += 1 }
                                if mask[bottom.center * w + x] || mask[max(0, bottom.center - 1) * w + x] || mask[min(h - 1, bottom.center + 1) * w + x] { hitB += 1 }
                            }
                            let ratio = Double(hit + hitB) / Double(2 * span)
                            guard ratio > 0.55 else { continue }
                            let score = hit + hitB + top.strength + bottom.strength
                            if best == nil || score > best!.score {
                                best = (CGRect(x: Double(left.center) / Double(w),
                                               y: Double(top.center) / Double(h),
                                               width: Double(right.center - left.center) / Double(w),
                                               height: Double(bottom.center - top.center) / Double(h)), score)
                            }
                        }
                    }
                }
            }
        }
        return best?.rect
    }

    /// 把投影直方图里超过阈值的连续区段聚成「边带」，返回中心位置与强度
    nonisolated static func bands(_ hist: [Int], threshold: Int) -> [(center: Int, strength: Int)] {
        var out: [(Int, Int)] = []
        var start = -1, peak = 0
        for i in 0..<hist.count {
            if hist[i] >= threshold {
                if start < 0 { start = i; peak = 0 }
                peak = max(peak, hist[i])
            } else if start >= 0 {
                out.append(((start + i - 1) / 2, peak)); start = -1
            }
        }
        if start >= 0 { out.append(((start + hist.count - 1) / 2, peak)) }
        return out.map { (center: $0.0, strength: $0.1) }
    }
}
