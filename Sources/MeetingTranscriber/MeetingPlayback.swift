import Foundation
import AVFoundation
import Combine

@MainActor
final class MeetingPlayback: ObservableObject {
    @Published private(set) var source: AudioSource = .system
    @Published private(set) var sources: [AudioSource] = []
    @Published private(set) var position: TimeInterval = 0
    @Published private(set) var duration: TimeInterval = 0
    @Published private(set) var isPlaying = false
    @Published private(set) var message = ""
    @Published var followText = true
    @Published var rate: Float = 1 { didSet { player?.rate = rate } }
    var volume: Float = 1 { didSet { player?.volume = volume } }
    private var segments: [MeetingAudioSegment] = []
    private var urls: [UUID: URL] = [:]
    private var recordID: UUID?
    private var current: MeetingAudioSegment?
    private var player: AVAudioPlayer?
    private var timer: Timer?

    func configure(_ record: MeetingRecord?, store: MeetingStore) {
        let valid = (record?.audioSegments ?? []).filter { $0.start.isFinite && $0.start >= 0 && $0.duration.isFinite && $0.duration > 0 }.sorted { $0.start < $1.start }
        guard recordID != record?.id || segments != valid else { return }
        reset()
        recordID = record?.id
        segments = valid
        if let record {
            for segment in valid {
                if let url = try? store.audioURL(for: segment, in: record), FileManager.default.fileExists(atPath: url.path) { urls[segment.id] = url }
            }
        }
        sources = AudioSource.allCases.filter { source in valid.contains { $0.source == source && urls[$0.id] != nil } }
        if let first = sources.first { selectSource(first) }
        else { message = valid.isEmpty ? "这场会议没有可回放的录音。" : "录音文件已缺失，转写文字仍可查看。" }
    }

    func reset() {
        pause(); player = nil; current = nil; recordID = nil; segments = []; urls = [:]
        sources = []; position = 0; duration = 0; message = ""
    }
    private var track: [MeetingAudioSegment] { segments.filter { $0.source == source && urls[$0.id] != nil } }

    func selectSource(_ value: AudioSource) {
        guard sources.contains(value) else { return }
        let oldPosition = position
        pause(); player = nil; current = nil; source = value
        duration = track.map { $0.start + $0.duration }.max() ?? 0
        if !seek(oldPosition), let first = track.first { _ = seek(first.start) }
    }

    @discardableResult
    func seek(_ time: TimeInterval) -> Bool {
        guard time.isFinite else { return false }
        let wasPlaying = isPlaying
        pause()
        position = min(max(0, time), duration)
        guard let segment = track.last(where: { position >= $0.start && position < $0.start + $0.duration }),
              let url = urls[segment.id] else {
            player = nil; current = nil
            message = "此位置没有这一路录音，可选择其他时间或声音来源。"
            return false
        }
        do {
            if current?.id != segment.id {
                player = try AVAudioPlayer(contentsOf: url)
                current = segment
                player?.enableRate = true
                player?.volume = volume
            }
            guard let player, position - segment.start < player.duration else {
                self.player = nil; current = nil
                message = "此位置超出实际录音范围。"; return false
            }
            player.currentTime = position - segment.start
            player.rate = rate
            message = ""
            if wasPlaying { play() }
            return true
        } catch { player = nil; current = nil; message = "录音无法播放：" + error.localizedDescription; return false }
    }
    func toggle() { if isPlaying { pause() } else { play() } }
    func play() {
        if player == nil || position >= duration {
            guard let next = position >= duration ? track.first : track.first(where: { $0.start >= position }) else { return }
            let skippedGap = next.start > position
            guard seek(next.start) else { return }
            if skippedGap { message = "已跳到下一段录音，跳过没有录音的间隔。" }
        }
        guard let player, player.play() else { message = "录音未能播放，请重试。"; return }
        isPlaying = true
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.12, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }
    func pause() { player?.pause(); isPlaying = false; timer?.invalidate(); timer = nil }
    private func tick() {
        guard isPlaying, let player, let current else { return }
        position = current.start + player.currentTime
        if !player.isPlaying {
            pause()
            if let next = track.first(where: { $0.start >= current.start + current.duration - 0.01 && $0.id != current.id }) {
                if seek(next.start) {
                    message = next.start > current.start + current.duration + 0.1 ? "已跳过没有录音的间隔。" : ""
                    play()
                }
            } else { position = min(duration, current.start + player.duration) }
        }
    }
}
