import CoreAudio
import Foundation

/// A device other than the Mac itself that audio is going to: an AirPlay
/// speaker or TV, or Bluetooth headphones such as AirPods.
struct AudioRoute: Equatable {
    enum Device {
        case homePodMini
        case homePod
        case appleTV
        case tv
        case airPods
        case airPodsPro
        case airPodsMax
        case headphones
        case speaker
        /// An AirPlay device that hasn't been identified yet.
        case airPlay
    }

    /// The device's name, or "2 Speakers" when Music plays to several.
    var destination: String
    var device: Device

    /// False while all that's known is "some AirPlay device".
    var isIdentified: Bool {
        device != .airPlay
    }

    var systemImage: String {
        switch device {
        case .homePodMini: "homepod.mini.fill"
        case .homePod: "homepod.fill"
        case .appleTV: "appletv.fill"
        case .tv: "tv.fill"
        case .airPods: "airpods"
        case .airPodsPro: "airpods.pro"
        case .airPodsMax: "airpods.max"
        case .headphones: "headphones"
        case .speaker: "hifispeaker.fill"
        case .airPlay: "airplay.audio"
        }
    }

    /// What the device announces on the network is definitive: an Apple
    /// model, or for anyone else's device whether it has a screen (a TV).
    /// Without that, fall back to Music's device kind, then to the name.
    static func airPlayDevice(named name: String, announced: AirPlayDeviceDirectory.Device?, musicKind: UInt32? = nil) -> Device {
        if let model = announced?.model {
            if model.hasPrefix("AudioAccessory5") { return .homePodMini }
            if model.hasPrefix("AudioAccessory") { return .homePod }
            if model.hasPrefix("AppleTV") { return .appleTV }
        }
        if announced?.hasScreen == true {
            return .tv
        }
        let lowercased = name.lowercased()
        if musicKind == MusicAirPlayDevice.homePod || lowercased.contains("homepod") {
            return lowercased.contains("mini") ? .homePodMini : .homePod
        }
        if musicKind == MusicAirPlayDevice.appleTV || lowercased.contains("apple tv") {
            return .appleTV
        }
        if musicKind == MusicAirPlayDevice.tv || lowercased.contains("tv") {
            return .tv
        }
        return .speaker
    }

    /// Bluetooth devices only give a name, which for AirPods is
    /// "Justin's AirPods Pro" unless renamed.
    static func bluetoothDevice(named name: String) -> Device {
        let lowercased = name.lowercased()
        if lowercased.contains("airpods max") { return .airPodsMax }
        if lowercased.contains("airpods pro") { return .airPodsPro }
        if lowercased.contains("airpods") { return .airPods }
        return .headphones
    }
}

/// Watches where audio is playing, read-only: MacCove shows the route but
/// doesn't change it.
///
/// - The Mac's own output, through Core Audio: AirPlay chosen in Control
///   Center, and Bluetooth headphones like AirPods.
/// - While Apple Music plays, Music's own AirPlay devices too, since Music
///   can AirPlay by itself without changing the Mac's output.
@Observable
final class AudioRouteMonitor {
    private struct SystemOutput: Equatable {
        enum Transport { case airPlay, bluetooth }
        var name: String
        var transport: Transport
    }

    /// The Mac's model name, "MacBook Pro", like the iPhone shows "iPhone".
    private(set) var sourceName = "Mac"

    private var systemOutput: SystemOutput?
    /// Music's AirPlay devices other than the Mac itself.
    private var musicDevices: [MusicAirPlayDevice] = []

    private let directory = AirPlayDeviceDirectory()
    @ObservationIgnored private let music: MusicScripting
    @ObservationIgnored private let isMusicPlaying: () -> Bool
    @ObservationIgnored private var musicTask: Task<Void, Never>?

    private static let system = AudioObjectID(kAudioObjectSystemObject)
    private static let musicPollInterval: Duration = .seconds(2)

    init(music: MusicScripting, isMusicPlaying: @escaping () -> Bool) {
        self.music = music
        self.isMusicPlaying = isMusicPlaying
        observeSystem(kAudioHardwarePropertyDefaultOutputDevice)
        observeSystem(kAudioHardwarePropertyDevices)
        refreshSystemOutput()
        pollMusic()
    }

    var route: AudioRoute? {
        if let first = musicDevices.first {
            return AudioRoute(
                destination: musicDevices.count > 1 ? "\(musicDevices.count) Speakers" : first.name,
                device: AudioRoute.airPlayDevice(named: first.name, announced: directory.device(named: first.name), musicKind: first.kind)
            )
        }
        guard let output = systemOutput else { return nil }
        switch output.transport {
        case .airPlay:
            // The Mac's AirPlay output is usually just called "AirPlay". If it
            // does carry a device's name, that settles it.
            if let announced = directory.device(named: output.name) {
                return AudioRoute(destination: output.name, device: AudioRoute.airPlayDevice(named: output.name, announced: announced))
            }
            // Otherwise it's whichever device says it's receiving.
            let receivers = directory.receivingDevices
            if let first = receivers.first {
                return AudioRoute(
                    destination: receivers.count > 1 ? "\(receivers.count) Speakers" : first.name,
                    device: AudioRoute.airPlayDevice(named: first.name, announced: first)
                )
            }
            // A device takes a moment to announce a new session, so until one
            // does, guess the last receiver; it's usually the same speaker.
            if let last = directory.lastReceivingDevice {
                return AudioRoute(destination: last.name, device: AudioRoute.airPlayDevice(named: last.name, announced: last))
            }
            // Never AirPlayed before, or Local Network access was declined.
            return AudioRoute(destination: output.name, device: .airPlay)
        case .bluetooth:
            return AudioRoute(destination: output.name, device: AudioRoute.bluetoothDevice(named: output.name))
        }
    }

    // MARK: - Music

    private func pollMusic() {
        musicTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.refreshMusicDevices()
                try? await Task.sleep(for: Self.musicPollInterval)
            }
        }
    }

    private func refreshMusicDevices() async {
        guard isMusicPlaying() else {
            setMusicDevices([])
            return
        }
        // nil means Music couldn't be asked; keep what we had.
        guard let devices = await music.currentAirPlayDevices() else { return }
        setMusicDevices(devices.filter { $0.kind != MusicAirPlayDevice.computer })
    }

    /// Polling would otherwise redraw the island every few seconds.
    private func setMusicDevices(_ devices: [MusicAirPlayDevice]) {
        guard musicDevices != devices else { return }
        musicDevices = devices
        if !devices.isEmpty {
            directory.startIfNeeded()
        }
    }

    // MARK: - Core Audio

    private func observeSystem(_ selector: AudioObjectPropertySelector) {
        var address = Self.propertyAddress(selector)
        AudioObjectAddPropertyListenerBlock(Self.system, &address, .main) { [weak self] _, _ in
            MainActor.assumeIsolated { self?.refreshSystemOutput() }
        }
    }

    private func refreshSystemOutput() {
        sourceName = Self.macModelName() ?? "Mac"

        var output: SystemOutput?
        if let device = Self.defaultOutputDevice(), let name = Self.name(device) {
            switch Self.transportType(device) ?? 0 {
            case kAudioDeviceTransportTypeAirPlay:
                output = SystemOutput(name: name, transport: .airPlay)
                directory.startIfNeeded()
            case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE:
                output = SystemOutput(name: name, transport: .bluetooth)
            default:
                break
            }
        }
        if systemOutput != output {
            systemOutput = output
        }
    }

    /// From the built-in output's name, "MacBook Pro Speakers".
    private static func macModelName() -> String? {
        let suffix = " Speakers"
        for id in deviceIDs() where transportType(id) == kAudioDeviceTransportTypeBuiltIn {
            if let name = name(id), name.hasSuffix(suffix) {
                return String(name.dropLast(suffix.count))
            }
        }
        return nil
    }

    private static func propertyAddress(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
    }

    private static func defaultOutputDevice() -> AudioObjectID? {
        var address = propertyAddress(kAudioHardwarePropertyDefaultOutputDevice)
        var device = AudioObjectID(0)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &device) == noErr, device != 0 else {
            return nil
        }
        return device
    }

    private static func deviceIDs() -> [AudioObjectID] {
        var address = propertyAddress(kAudioHardwarePropertyDevices)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &ids) == noErr else { return [] }
        return ids
    }

    private static func transportType(_ id: AudioObjectID) -> UInt32? {
        var address = propertyAddress(kAudioDevicePropertyTransportType)
        var transport: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &transport) == noErr else { return nil }
        return transport
    }

    private static func name(_ id: AudioObjectID) -> String? {
        var address = propertyAddress(kAudioObjectPropertyName)
        var name: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &name) == noErr, let name else { return nil }
        return name.takeRetainedValue() as String
    }
}
