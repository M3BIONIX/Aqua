import SwiftUI
import AquaCore

struct DownloadsView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var downloads: DownloadCenter

    var body: some View {
        let ordered = downloads.ordered
        let current = ordered.first { $0.isTransferring } ?? ordered.first { $0.state == .paused }
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                header
                if let current {
                    ActiveDownloadCard(item: current)
                }
                NetworkMonitor()
                let rest = ordered.filter { $0.id != current?.id }
                if !rest.isEmpty {
                    QueueSection(items: rest)
                } else if current == nil {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("No downloads").font(.geist(15, .medium))
                        Text("Choose Install on a game in your library and it shows up here.")
                            .font(.geist(14)).foregroundStyle(Theme.mutedText)
                        Button("Go to Library") { model.route = .library }
                            .buttonStyle(SecondaryButtonStyle()).padding(.top, 6)
                    }
                }
            }
            .padding(.horizontal, 40)
            .padding(.top, 26)
            .padding(.bottom, 36)
        }
        .scrollIndicators(.never)
    }

    private var header: some View {
        HStack(alignment: .bottom) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Downloads").font(.geist(28, .semibold)).tracking(-0.56)
                Text(subtitle).font(.geist(14)).foregroundStyle(Theme.mutedText)
            }
            Spacer()
            HStack(spacing: 10) {
                if downloads.items.contains(where: { !$0.isPending }) {
                    Button("Clear finished") { downloads.clearFinished() }.buttonStyle(SecondaryButtonStyle())
                }
                if downloads.items.contains(where: { $0.isPending && $0.state != .paused }) {
                    Button { downloads.pauseAll() } label: { Label("Pause all", systemImage: "pause.fill") }
                        .buttonStyle(SecondaryButtonStyle())
                } else if downloads.items.contains(where: { $0.state == .paused }) {
                    Button { downloads.resumeAll() } label: { Label("Resume all", systemImage: "play.fill") }
                        .buttonStyle(SecondaryButtonStyle())
                }
            }
        }
        .padding(.top, 26)
    }

    private var subtitle: String {
        let queued = downloads.pending.count
        let location = "Installing to \(model.settings.gamesURL.lastPathComponent)"
        return queued == 0 ? location : "\(queued) in queue  ·  \(location)"
    }
}

enum DownloadText {
    static func state(_ item: DownloadItem) -> String {
        switch item.state {
        case .preparing(let message): return message
        case .downloading: return "Downloading"
        case .queued: return "Queued"
        case .paused: return "Paused"
        case .failed(let message): return message
        case .finished: return "Installed"
        }
    }

    static func stats(_ item: DownloadItem) -> String {
        var parts: [String] = []
        if item.bytesTotal > 0 { parts.append("\(Format.bytes(item.bytesDone)) of \(Format.bytes(item.bytesTotal))") }
        else { parts.append("\(Int(item.fraction * 100))%") }
        if item.isTransferring { parts.append(Format.speed(item.networkBytesPerSecond)) }
        if let eta = item.secondsRemaining, item.isTransferring { parts.append("\(Format.duration(eta)) left") }
        return parts.joined(separator: "  ·  ")
    }
}

struct DownloadControls: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var downloads: DownloadCenter
    let item: DownloadItem

    var body: some View {
        HStack(spacing: 8) {
            switch item.state {
            case .paused, .queued:
                Button { downloads.resume(item.id) } label: { Label("Resume", systemImage: "play.fill") }
                    .buttonStyle(PrimaryButtonStyle())
            case .failed:
                Button("Retry") { if let game = model.game(id: item.id) { model.install(game) } }
                    .buttonStyle(PrimaryButtonStyle())
            case .finished:
                if let game = model.game(id: item.id) {
                    Button { model.play(game) } label: { Label("Play", systemImage: "play.fill") }.buttonStyle(PrimaryButtonStyle())
                }
            default:
                Button { downloads.pause(item.id) } label: { Label("Pause", systemImage: "pause.fill") }
                    .buttonStyle(PrimaryButtonStyle())
            }
            if let game = model.game(id: item.id), let path = model.installPath(of: game) {
                Button { model.reveal(path: path) } label: { Image(systemName: "folder") }
                    .buttonStyle(IconButtonStyle())
                    .help("Show in Finder")
            }
            if item.isPending || item.state != .finished {
                Button { downloads.cancel(item.id) } label: { Image(systemName: "xmark") }
                    .buttonStyle(IconButtonStyle())
                    .help(item.store == .steam ? "Remove from Steam's queue" : "Cancel download")
            }
        }
        .labelStyle(TightLabelStyle())
    }
}

struct TightLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 8) {
            configuration.icon.font(.system(size: 11))
            configuration.title
        }
    }
}

private struct ActiveDownloadCard: View {
    @EnvironmentObject var model: AppModel
    let item: DownloadItem

    var body: some View {
        HStack(alignment: .top, spacing: 28) {
            ArtworkImage(url: item.artURL, title: item.title)
                .frame(width: 300, height: 140)
                .clipShape(RoundedRectangle(cornerRadius: Theme.radius))
                .onTapGesture { model.route = .game(item.id) }
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(DownloadText.state(item)).font(.geist(13))
                            .foregroundStyle(item.state == .paused ? Theme.mutedText : Theme.accentText)
                        Text(item.title).font(.geist(22, .semibold)).tracking(-0.22).lineLimit(1)
                    }
                    Spacer()
                    DownloadControls(item: item)
                }
                Spacer(minLength: 16)
                ProgressLine(fraction: item.fraction, height: 4)
                HStack(spacing: 40) {
                    Stat(label: "Downloaded", value: item.bytesTotal > 0 ? "\(Format.bytes(item.bytesDone)) of \(Format.bytes(item.bytesTotal))" : "\(Int(item.fraction * 100))%")
                    Stat(label: "Network", value: Format.speed(item.networkBytesPerSecond))
                    Stat(label: "Disk write", value: Format.speed(item.diskBytesPerSecond))
                    Stat(label: "Time left", value: item.secondsRemaining.map(Format.duration) ?? "–")
                }
                .padding(.top, 12)
            }
            .frame(height: 140)
        }
        .padding(20)
        .background(Theme.panel, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.border))
    }
}

private struct Stat: View {
    let label: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.geist(12)).foregroundStyle(Theme.mutedText)
            Text(value).font(.mono(14))
        }
    }
}

private enum ChartRange: String, CaseIterable {
    case fiveMinutes = "5 min"
    case thirtyMinutes = "30 min"
    case session = "Session"

    var seconds: Int? {
        switch self {
        case .fiveMinutes: return 300
        case .thirtyMinutes: return 1800
        case .session: return nil
        }
    }
}

private struct NetworkMonitor: View {
    @EnvironmentObject var downloads: DownloadCenter
    @State private var range: ChartRange = .fiveMinutes

    var body: some View {
        let samples = visibleSamples
        let values = samples.map(\.network)
        let peak = values.max() ?? 0
        let active = values.filter { $0 > 0 }
        let average = active.isEmpty ? 0 : active.reduce(0, +) / Double(active.count)
        let scale = Self.niceCeiling(max(peak, 1_000_000))

        VStack(alignment: .leading, spacing: 16) {
            HStack {
                HStack(spacing: 16) {
                    Text("Network").font(.geist(15, .semibold))
                    HStack(spacing: 14) {
                        ForEach(ChartRange.allCases, id: \.self) { option in
                            Button { range = option } label: {
                                Text(option.rawValue)
                                    .font(.geist(13))
                                    .foregroundStyle(range == option ? Theme.text : Theme.mutedText)
                                    .padding(.bottom, 2)
                                    .overlay(alignment: .bottom) {
                                        Rectangle().fill(range == option ? Theme.accentText : .clear).frame(height: 1)
                                    }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                Spacer()
                HStack(spacing: 28) {
                    MonitorStat(label: "Now", value: Format.speed(values.last ?? 0), highlight: true)
                    MonitorStat(label: "Peak", value: Format.speed(peak))
                    MonitorStat(label: "Average", value: Format.speed(average))
                    MonitorStat(label: "This session", value: Format.bytes(Int64(downloads.sessionBytes)))
                }
            }
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading) {
                    Text(Self.axis(scale))
                    Spacer()
                    Text(Self.axis(scale / 2))
                    Spacer()
                    Text("0")
                }
                .font(.mono(11))
                .foregroundStyle(Theme.faintText)
                .frame(width: 48, height: 150, alignment: .leading)
                ThroughputChart(values: values, capacity: range.seconds ?? max(values.count, 60), scale: scale)
                    .frame(height: 150)
            }
        }
        .padding(20)
        .background(Theme.panel, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.border))
    }

    private var visibleSamples: [ThroughputSample] {
        guard let seconds = range.seconds else { return downloads.samples }
        return Array(downloads.samples.suffix(seconds))
    }

    static func niceCeiling(_ value: Double) -> Double {
        let mb = value / 1_000_000
        let steps: [Double] = [1, 2, 5, 10, 20, 25, 50, 100, 200, 250, 500, 1000, 2000]
        return (steps.first { $0 >= mb * 1.1 } ?? (mb * 1.2).rounded(.up)) * 1_000_000
    }

    static func axis(_ value: Double) -> String {
        let mb = value / 1_000_000
        return mb == mb.rounded() ? "\(Int(mb)) MB" : String(format: "%.1f MB", mb)
    }
}

private struct MonitorStat: View {
    let label: String
    let value: String
    var highlight = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(label).font(.geist(12)).foregroundStyle(Theme.mutedText)
            Text(value).font(.mono(13)).foregroundStyle(highlight ? Theme.accentText : Theme.text)
        }
    }
}

/// Area chart of throughput. New samples enter on the right; the window holds `capacity` seconds.
private struct ThroughputChart: View {
    let values: [Double]
    let capacity: Int
    let scale: Double

    var body: some View {
        Canvas { context, size in
            for fraction in [0.0, 0.5] {
                var grid = Path()
                let y = size.height * fraction + 0.5
                grid.move(to: CGPoint(x: 0, y: y))
                grid.addLine(to: CGPoint(x: size.width, y: y))
                context.stroke(grid, with: .color(.white.opacity(0.05)), lineWidth: 1)
            }
            var baseline = Path()
            baseline.move(to: CGPoint(x: 0, y: size.height - 0.5))
            baseline.addLine(to: CGPoint(x: size.width, y: size.height - 0.5))
            context.stroke(baseline, with: .color(.white.opacity(0.08)), lineWidth: 1)

            guard values.count > 1 else { return }
            let step = size.width / CGFloat(max(capacity - 1, 1))
            let start = size.width - step * CGFloat(values.count - 1)
            let points = values.enumerated().map { index, value in
                CGPoint(x: start + step * CGFloat(index), y: size.height - size.height * CGFloat(min(value / scale, 1)) * 0.96)
            }
            var line = Path()
            line.addLines(points)
            var area = line
            area.addLine(to: CGPoint(x: points.last!.x, y: size.height))
            area.addLine(to: CGPoint(x: points.first!.x, y: size.height))
            area.closeSubpath()
            context.fill(area, with: .linearGradient(Gradient(colors: [Theme.accent.opacity(0.35), Theme.accent.opacity(0)]),
                                                     startPoint: .zero, endPoint: CGPoint(x: 0, y: size.height)))
            context.stroke(line, with: .color(Theme.accentText), style: StrokeStyle(lineWidth: 1.5, lineJoin: .round))
        }
    }
}

private struct QueueSection: View {
    let items: [DownloadItem]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text("Up next").font(.geist(15, .semibold))
                Spacer()
                Text("Start now moves a game to the front").font(.geist(13)).foregroundStyle(Theme.mutedText)
            }
            .padding(.bottom, 8)
            VStack(spacing: 0) {
                ForEach(items) { item in QueueRow(item: item) }
            }
            .overlay(alignment: .top) { Rectangle().fill(Theme.divider).frame(height: 1) }
        }
    }
}

private struct QueueRow: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var downloads: DownloadCenter
    let item: DownloadItem

    var body: some View {
        let done = !item.isPending
        HStack(spacing: 16) {
            ArtworkImage(url: item.artURL)
                .frame(width: 92, height: 43)
                .clipShape(RoundedRectangle(cornerRadius: 4))
                .opacity(done ? 0.6 : 1)
            Text(item.title).font(.geist(14, .medium)).foregroundStyle(done ? Theme.mutedText : Theme.text).lineLimit(1)
            Spacer()
            Text(item.bytesTotal > 0 ? Format.bytes(item.bytesTotal) : "–")
                .font(.mono(13)).foregroundStyle(done ? Theme.faintText : Theme.mutedText)
                .frame(width: 110, alignment: .leading)
            Text(stateText).font(.geist(13)).foregroundStyle(stateColor).lineLimit(1)
                .frame(width: 200, alignment: .leading)
            action.frame(width: 90, alignment: .trailing)
        }
        .frame(height: 64)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.divider).frame(height: 1) }
        .contextMenu {
            if item.isPending { Button(item.store == .steam ? "Remove from Steam's queue" : "Cancel download") { downloads.cancel(item.id) } }
        }
    }

    private var stateText: String {
        switch item.state {
        case .queued: return "Waiting"
        case .paused: return item.fraction > 0 ? "Paused at \(Int(item.fraction * 100))%" : "Paused"
        case .finished: return item.finishedAt.map { "Finished \(Format.ago($0))" } ?? "Finished"
        case .failed(let message): return message
        default: return DownloadText.state(item)
        }
    }

    private var stateColor: Color {
        if case .failed = item.state { return Theme.danger }
        return item.isPending ? Theme.mutedText : Theme.faintText
    }

    @ViewBuilder
    private var action: some View {
        switch item.state {
        case .queued:
            Button("Start now") { downloads.startNow(item.id) }.buttonStyle(LinkButtonStyle()).font(.geist(13))
        case .paused:
            Button("Resume") { downloads.resume(item.id) }.buttonStyle(LinkButtonStyle()).font(.geist(13))
        case .failed:
            Button("Retry") { if let game = model.game(id: item.id) { model.install(game) } }.buttonStyle(LinkButtonStyle()).font(.geist(13))
        case .finished:
            Button("Play") { if let game = model.game(id: item.id) { model.play(game) } }.buttonStyle(LinkButtonStyle()).font(.geist(13))
        default:
            EmptyView()
        }
    }
}
