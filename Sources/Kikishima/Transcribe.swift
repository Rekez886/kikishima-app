// 本地流式转写：macOS 26 SpeechAnalyzer + SpeechTranscriber
// 整个类在主线程上（start / stop / 重连都由 CaptionState 驱动）；只有 feed() 在音频 IO 线程上跑，它碰的三个字段用锁保护
import Foundation
import Speech
import AVFoundation
import OSLog

private let logger = Logger(subsystem: "com.kikishima.mac", category: "Transcribe")

/// 转写事件：volatile = 未定稿（会被替换），finalized = 定稿（往 committed 累加）
enum TranscriptEvent {
    case volatile(String)
    case finalized(String)
    case error(String)
}

@MainActor
final class TranscribeEngine {
    private var analyzer: SpeechAnalyzer?
    private var transcriber: SpeechTranscriber?
    // 音频 IO 线程（feed）与主线程（start/stop）同时碰的三个字段：锁保护；nonisolated(unsafe) 让 feed 能从非隔离上下文访问
    private let lock = NSLock()
    nonisolated(unsafe) private var inputBuilder: AsyncStream<AnalyzerInput>.Continuation?
    nonisolated(unsafe) private var analyzerFormat: AVAudioFormat?
    nonisolated(unsafe) private var converter: AVAudioConverter?
    private var resultsTask: Task<Void, Never>?
    /// 模型下载进度（0~1），无需下载时为 nil
    var onDownloadProgress: ((Double) -> Void)?

    /// locale: "en_US" / "ja_JP"
    /// 代数：每次 start/stop +1；await 之后发现代数变了 = 已被别的 start/stop 接管，只拆自己建的东西
    private var gen = 0

    func start(localeID: String, onEvent: @escaping @Sendable (TranscriptEvent) -> Void) async throws {
        stop()   // 幂等：上一次没停干净就先清
        gen += 1
        let myGen = gen
        let locale = Locale(identifier: localeID)
        let transcriber = SpeechTranscriber(
            locale: locale,
            transcriptionOptions: [],
            reportingOptions: [.volatileResults],
            attributeOptions: []
        )
        self.transcriber = transcriber

        // 模型资产：没装则下载（首次要几百 MB，之后秒开）
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            let progress = request.progress
            let observer = progress.observe(\.fractionCompleted, options: [.new]) { [weak self] p, _ in
                let v = p.fractionCompleted
                Task { @MainActor in self?.onDownloadProgress?(v) }
            }
            defer { observer.invalidate() }
            try await request.downloadAndInstall()
        }
        try Task.checkCancellation()   // 用户在下载期间取消：什么都还没建，直接退出
        guard gen == myGen else { throw CancellationError() }

        let analyzer = SpeechAnalyzer(modules: [transcriber])
        let fmt = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber])
        try Task.checkCancellation()
        guard gen == myGen else { throw CancellationError() }
        self.analyzer = analyzer

        // bufferingNewest：分析器卡住/挂掉时丢旧音频，而不是无限堆内存（2 小时会议 ~230 MB）
        let (stream, builder) = AsyncStream<AnalyzerInput>.makeStream(bufferingPolicy: .bufferingNewest(256))
        lock.lock(); self.inputBuilder = builder; self.analyzerFormat = fmt; self.converter = nil; lock.unlock()
        try await analyzer.start(inputSequence: stream)
        if Task.isCancelled || gen != myGen {   // 取消/被接管在 analyzer.start 期间到达：只拆自己建的这套，不碰当前会话的
            builder.finish()
            Task { try? await analyzer.finalizeAndFinishThroughEndOfInput() }
            if gen == myGen { lock.lock(); inputBuilder = nil; analyzerFormat = nil; converter = nil; lock.unlock(); self.analyzer = nil; self.transcriber = nil }
            throw CancellationError()
        }

        resultsTask = Task {
            do {
                for try await result in transcriber.results {
                    guard self.gen == myGen, !Task.isCancelled else { return }
                    let text = String(result.text.characters)
                    if result.isFinal {
                        onEvent(.finalized(text))
                    } else {
                        onEvent(.volatile(text))
                    }
                }
            } catch {
                // stop() 主动取消不算错误
                if error is CancellationError || Task.isCancelled { return }
                onEvent(.error(trAny("转写流中断：%@", error.localizedDescription)))
            }
        }
        logger.info("transcriber started, locale \(localeID)")
    }

    /// 音频线程调用：tap 的原始 buffer 转成分析器格式后喂入
    nonisolated func feed(bufferList: UnsafePointer<AudioBufferList>, sourceFormat: AVAudioFormat) {
        lock.lock()
        guard let inputBuilder, let analyzerFormat else { lock.unlock(); return }
        if converter == nil || converter?.inputFormat != sourceFormat {
            converter = AVAudioConverter(from: sourceFormat, to: analyzerFormat)
            converter?.primeMethod = .none
        }
        let converter = self.converter
        lock.unlock()
        guard let converter else { return }
        guard let src = AVAudioPCMBuffer(pcmFormat: sourceFormat, bufferListNoCopy: bufferList, deallocator: nil) else { return }
        let ratio = analyzerFormat.sampleRate / sourceFormat.sampleRate
        let capacity = AVAudioFrameCount(Double(src.frameLength) * ratio) + 64
        guard let dst = AVAudioPCMBuffer(pcmFormat: analyzerFormat, frameCapacity: capacity) else { return }
        var consumed = false
        var convErr: NSError?
        converter.convert(to: dst, error: &convErr) { _, outStatus in
            if consumed { outStatus.pointee = .noDataNow; return nil }
            consumed = true
            outStatus.pointee = .haveData
            return src
        }
        if convErr == nil, dst.frameLength > 0 {
            inputBuilder.yield(AnalyzerInput(buffer: dst))
        }
    }

    func stop() {
        gen += 1
        lock.lock()
        let builder = inputBuilder
        inputBuilder = nil; converter = nil; analyzerFormat = nil
        lock.unlock()
        builder?.finish()
        let analyzer = self.analyzer
        let task = resultsTask
        resultsTask = nil
        // 先让分析器把尾巴吐完再取消结果流，否则最后半句丢失
        Task {
            try? await analyzer?.finalizeAndFinishThroughEndOfInput()
            task?.cancel()
        }
        self.analyzer = nil
        self.transcriber = nil
    }

    /// 重置转换器（输出设备切换后采样率可能变）
    nonisolated func resetConverter() { lock.lock(); converter = nil; lock.unlock() }
}
