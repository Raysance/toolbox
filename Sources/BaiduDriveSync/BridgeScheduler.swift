import Combine
import Foundation
import SwiftUI

@MainActor
final class BridgeScheduler {
    private let bridge: BridgeModel
    private let networkAllows: (FolderRule) -> Bool
    private var observation: AnyCancellable?
    private var timers: [UUID: AnyCancellable] = [:]
    private var intervals: [UUID: Int] = [:]

    init(bridge: BridgeModel, networkAllows: @escaping (FolderRule) -> Bool) {
        self.bridge = bridge
        self.networkAllows = networkAllows
        observation = bridge.$rules.sink { [weak self] rules in self?.update(rules) }
    }

    private func update(_ rules: [FolderRule]) {
        var enabled: [UUID: Int] = [:]
        for rule in rules where rule.settings.automatic {
            enabled[rule.id] = rule.settings.minutes
        }
        for id in intervals.keys where enabled[id] != intervals[id] {
            timers[id] = nil
        }
        for (id, minutes) in enabled where intervals[id] != minutes {
            timers[id] = Timer.publish(every: Double(minutes) * 60, on: .main, in: .common)
                .autoconnect()
                .sink { [weak self] _ in Task { await self?.fire(id, minutes: minutes) } }
        }
        intervals = enabled
    }

    private func fire(_ id: UUID, minutes: Int) async {
        guard let rule = bridge.rules.first(where: { $0.id == id }),
              rule.settings.automatic, rule.settings.minutes == minutes, networkAllows(rule),
              !bridge.running.contains(id), bridge.conflicts[id] == nil else { return }
        await bridge.sync(rule)
    }
}

struct RuleScheduleControls: View {
    @Binding var options: RuleOptions
    let isBaiduUpload: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Toggle("定时同步", isOn: $options.automatic)
            if options.automatic {
                HStack {
                    Text("每隔")
                    TextField("分钟数", value: $options.minutes, format: .number.grouping(.never))
                        .frame(width: 62).multilineTextAlignment(.trailing)
                    Stepper("同步间隔", value: $options.minutes, in: 1...1440).labelsHidden()
                    Text("分钟同步一次")
                }
                Toggle("允许在热点或受限网络上定时同步", isOn: $options.allowMetered)
            }
            if isBaiduUpload {
                Stepper("并行上传数   \(options.parallelUploads)", value: $options.parallelUploads, in: 1...8)
            }
        }.padding(.vertical, 4)
    }
}

struct RuleScheduleEditor: View {
    @Environment(\.dismiss) private var dismiss
    @ViewState private var options: RuleOptions
    @ViewState private var issue = ""
    let rule: FolderRule
    let save: (RuleOptions) throws -> Void

    init(rule: FolderRule, save: @escaping (RuleOptions) throws -> Void) {
        self.rule = rule
        self.save = save
        _options = State(initialValue: rule.settings)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(rule.remote.name + " · 同步计划").font(.title2.bold())
            Text(URL(fileURLWithPath: rule.local.root).lastPathComponent +
                 (rule.uploadsOnly ? " → " : " ↔ ") + rule.remote.root)
                .lineLimit(2).truncationMode(.middle)
            RuleScheduleControls(options: $options, isBaiduUpload: rule.uploadsOnly && rule.remote.kind == "baidu")
            if !issue.isEmpty { Text(issue).foregroundStyle(.red) }
            HStack {
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("保存") {
                    do { try save(options); dismiss() } catch { issue = error.localizedDescription }
                }.keyboardShortcut(.defaultAction)
            }
        }.padding(20).frame(width: 420)
    }
}
