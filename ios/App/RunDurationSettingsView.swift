import SwiftUI

struct RunDurationSettingsView: View {
    var embedded = false
    @EnvironmentObject private var model: PilotViewModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var confirmUnlimited = false
    @State private var showCustom = false
    private let presets = [5, 15, 30, 60]
    private var minutes: Int { max(1, min(1440, model.configuration.selectedRunDurationSeconds / 60)) }
    private var unlimited: Bool { model.configuration.unlimitedRun == true }

    var body: some View {
        PilotSettingsNavigation(embedded: embedded) {
            ScrollView {
                VStack(spacing: 24) {
                    VStack(spacing: 10) {
                        Text("按你的节奏运行")
                            .font(.system(.title2, design: .rounded, weight: .semibold))
                        Text("屏幕共享与设备就绪后开始计时。")
                            .font(.subheadline).foregroundStyle(.secondary)
                    }.multilineTextAlignment(.center)
                    durationDial.disabled(model.isSessionActive)
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: dynamicTypeSize.isAccessibilitySize ? 2 : 4), spacing: 10) {
                        ForEach(presets, id: \.self) { value in
                            Button { select(minutes: value) } label: {
                                Text("\(value) 分钟").font(.subheadline.weight(.medium))
                                    .frame(maxWidth: .infinity, minHeight: 48)
                                    .foregroundStyle(!unlimited && minutes == value ? Color.white : Color.primary)
                                    .background(!unlimited && minutes == value ? Color(red: 0.11, green: 0.37, blue: 0.82) : PilotPalette.group, in: RoundedRectangle(cornerRadius: 16))
                            }.buttonStyle(.plain)
                                .accessibilityAddTraits(!unlimited && minutes == value ? .isSelected : [])
                        }
                    }.disabled(model.isSessionActive)
                    VStack(spacing: 0) {
                        Button { showCustom.toggle() } label: {
                            let layout = dynamicTypeSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8)) : AnyLayout(HStackLayout())
                            layout {
                                PilotSettingsRowLabel(title: "自定义时长", symbol: "slider.horizontal.3")
                                if !dynamicTypeSize.isAccessibilitySize { Spacer() }
                                Text("\(minutes) 分钟").foregroundStyle(.secondary).monospacedDigit()
                                Image(systemName: "chevron.down").font(.caption).foregroundStyle(.tertiary)
                                    .rotationEffect(.degrees(showCustom ? 180 : 0))
                            }.frame(minHeight: 52)
                        }.buttonStyle(.plain)
                        if showCustom {
                            Stepper(value: Binding(get: { minutes }, set: { select(minutes: $0) }), in: 1...1440) {
                                Text("最长 24 小时").font(.caption).foregroundStyle(.secondary)
                            }.padding(.bottom, 16)
                        }
                        Divider()
                        Toggle(isOn: Binding(get: { unlimited }, set: { enabled in
                            guard !model.isSessionActive else { return }
                            if enabled { confirmUnlimited = true }
                            else { model.configuration.unlimitedRun = false; _ = model.save() }
                        })) {
                            PilotSettingsRowLabel(title: "不限时", subtitle: "由任务完成或手动停止来结束", symbol: "infinity")
                        }.tint(PilotPalette.accent).frame(minHeight: 60)
                    }.padding(.horizontal, 18)
                        .background(PilotPalette.group, in: RoundedRectangle(cornerRadius: 24))
                        .disabled(model.isSessionActive)
                    Text(model.isSessionActive ? "当前任务结束后可以修改时长。" : unlimited ? "每次开始前确认，任务完成后自动结束。" : "到达时限后结束任务，也可以随时手动停止。")
                        .font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }.padding(.horizontal, 20).padding(.vertical, 24)
                    .frame(maxWidth: 560).frame(maxWidth: .infinity)
            }
            .navigationTitle("运行时长").navigationBarTitleDisplayMode(.inline)
            .modifier(PilotSettingsPageStyle(showsCloseButton: !embedded, appliesHorizontalMargins: false))
            .animation(reduceMotion ? nil : .smooth(duration: 0.28), value: minutes)
            .animation(reduceMotion ? nil : .smooth(duration: 0.28), value: unlimited)
            .animation(reduceMotion ? nil : .smooth(duration: 0.28), value: showCustom)
            .alert("开启不限时？", isPresented: $confirmUnlimited) {
                Button("取消", role: .cancel) {}
                Button("开启") {
                    guard !model.isSessionActive else { return }
                    model.configuration.unlimitedRun = true; _ = model.save()
                }
            } message: {
                Text("取消任务的时间上限。每次开始前仍会确认；系统中断或设备断线时会暂停。")
            }
        }
    }

    private var durationDial: some View {
        ZStack {
            Circle().stroke(PilotPalette.accent.opacity(0.08), lineWidth: 10)
            ForEach(0..<60, id: \.self) { tick in
                Capsule().fill(Color.secondary.opacity(tick % 5 == 0 ? 0.36 : 0.13))
                    .frame(width: tick % 5 == 0 ? 2 : 1, height: tick % 5 == 0 ? 12 : 5)
                    .offset(y: -110).rotationEffect(.degrees(Double(tick) * 6))
            }
            Circle().trim(from: 0, to: unlimited ? 1 : min(1, Double(minutes) / 60))
                .stroke(PilotPalette.accent.gradient, style: StrokeStyle(lineWidth: 10, lineCap: .round))
                .rotationEffect(.degrees(-90))
            VStack(spacing: 5) {
                if unlimited {
                    Image(systemName: "infinity").font(.system(size: 58, weight: .light))
                } else {
                    Text("\(minutes)").font(.system(size: 60, weight: .light, design: .rounded))
                        .monospacedDigit().contentTransition(.numericText())
                }
                Text(unlimited ? "直到任务结束" : "分钟").font(.subheadline).foregroundStyle(.secondary)
            }
        }.frame(width: 252, height: 252).padding(.vertical, 6)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("运行时长")
            .accessibilityValue(unlimited ? "不限时" : "\(minutes) 分钟")
            .accessibilityAdjustableAction { direction in
                switch direction {
                case .increment: select(minutes: min(1440, minutes + 1))
                case .decrement: select(minutes: max(1, minutes - 1))
                @unknown default: break
                }
            }
    }

    private func select(minutes: Int) {
        guard !model.isSessionActive else { return }
        model.configuration.runDurationSeconds = minutes * 60
        model.configuration.unlimitedRun = false
        _ = model.save()
    }
}
