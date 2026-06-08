import SwiftUI
import Charts
import AppKit

struct TransferRow: View {
    @ObservedObject var transfer: Transfer

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            if transfer.state == .transferring || transfer.state == .verifying {
                progressSection
                if transfer.samples.count > 1 { chart }
            } else {
                statusLine
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.secondary.opacity(0.06)))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.secondary.opacity(0.12)))
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: transfer.direction == .send ? "arrow.up.circle.fill" : "arrow.down.circle.fill")
                .font(.title2)
                .foregroundStyle(transfer.direction == .send ? Color.blue : Color.green)
            VStack(alignment: .leading, spacing: 2) {
                Text(transfer.primaryName).font(.headline).lineLimit(1)
                Text("\(transfer.direction == .send ? "To" : "From") \(transfer.peerName)")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            stateBadge
        }
    }

    private var stateBadge: some View {
        Group {
            switch transfer.state {
            case .completed:
                Label("Done", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
            case .failed:
                Label("Failed", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red)
            case .rejected:
                Label("Declined", systemImage: "hand.raised.fill").foregroundStyle(.orange)
            case .awaitingApproval:
                Label("Waiting", systemImage: "hourglass").foregroundStyle(.secondary)
            case .connecting:
                Label("Connecting", systemImage: "bolt.horizontal").foregroundStyle(.secondary)
            case .verifying:
                Label("Verifying", systemImage: "checkmark.shield").foregroundStyle(.secondary)
            default:
                EmptyView()
            }
        }
        .font(.caption).labelStyle(.titleAndIcon)
    }

    private var progressSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            ProgressView(value: transfer.progress)
            HStack {
                Text("\(Format.bytes(transfer.bytesTransferred)) / \(Format.bytes(transfer.totalBytes))")
                Spacer()
                Text(Format.rate(transfer.throughput)).fontWeight(.medium)
                Text("· ETA \(Format.eta(remaining: transfer.totalBytes - transfer.bytesTransferred, rate: transfer.throughput))")
            }
            .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var chart: some View {
        Chart(transfer.samples) { sample in
            AreaMark(x: .value("Time", sample.time),
                     y: .value("Rate", sample.bytesPerSecond))
            .foregroundStyle(.tint.opacity(0.25))
            LineMark(x: .value("Time", sample.time),
                     y: .value("Rate", sample.bytesPerSecond))
            .foregroundStyle(.tint)
            .interpolationMethod(.catmullRom)
        }
        .chartXAxis(.hidden)
        .chartYAxis {
            AxisMarks(position: .leading) { value in
                AxisValueLabel {
                    if let rate = value.as(Double.self) { Text(Format.rate(rate)) }
                }
            }
        }
        .frame(height: 70)
    }

    @ViewBuilder private var statusLine: some View {
        switch transfer.state {
        case .failed(let message):
            Text(message).font(.caption).foregroundStyle(.red)
        case .completed where transfer.savedLocation != nil:
            HStack {
                Text("Saved \(Format.bytes(transfer.totalBytes))")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Reveal in Finder") {
                    if let url = transfer.savedLocation {
                        NSWorkspace.shared.activateFileViewerSelecting([url])
                    }
                }
                .buttonStyle(.link).font(.caption)
            }
        case .completed:
            Text("Sent \(Format.bytes(transfer.totalBytes))")
                .font(.caption).foregroundStyle(.secondary)
        default:
            EmptyView()
        }
    }
}
