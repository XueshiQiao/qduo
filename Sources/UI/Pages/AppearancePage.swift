import SwiftUI
import AppKit

/// The Appearance page: which shape the popup takes, the geometry of the ring
/// styles, and how a result is rendered once an action produces text.
///
/// The popup itself is drawn at the top of the page (`PopBarStylePreview`), and
/// every control below changes it in place: pick a style, open Advanced, drag.
struct AppearancePage: View {

    @ObservedObject private var store: PopBarStore
    @State private var confirmingReset = false
    /// Whether the selected style's own knobs are shown. Closed every time the
    /// page opens: most people pick a style and never tune it.
    @State private var showingAdvanced = false

    init(store: PopBarStore) {
        _store = ObservedObject(wrappedValue: store)
    }

    var body: some View {
        Form {
            styleSection
            advancedSection
            resultSection
        }
        .formStyle(.grouped)
        .navigationTitle(L("page.appearance"))
    }

    // MARK: - Style

    private var styleSection: some View {
        Section {
            StyleSegments(selection: Binding(get: { store.style }, set: { store.setStyle($0) }),
                          styles: [.liquidGlass, .donut, .capsule], title: styleName)
                .frame(width: 360)
                .frame(maxWidth: .infinity)
            PopBarStylePreview(store: store)
        } header: {
            Text(L("popbar.display.header"))
        } footer: {
            Text(L("popbar.preview.footer"))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Advanced

    /// The selected style's own knobs, folded away by default. Each style has its
    /// own set; Liquid and 3D Glass have the same set, but each keeps its own values.
    private var advancedSection: some View {
        Section {
            if showingAdvanced {
                if store.style == .capsule {
                    radiusRow(label: L("popbar.capsule.iconSize"), symbol: "square.grid.2x2",
                              value: store.capsuleIconSize,
                              range: PopBarPreferences.capsuleIconSizeRange) {
                        store.setCapsuleIconSize($0)
                    }
                    radiusRow(label: L("popbar.capsule.labelSize"), symbol: "textformat.size",
                              value: store.capsuleLabelSize,
                              range: PopBarPreferences.capsuleLabelSizeRange) {
                        store.setCapsuleLabelSize($0)
                    }
                    Toggle(isOn: Binding(get: { store.capsuleBorder },
                                         set: { store.setCapsuleBorder($0) })) {
                        iconLabel("rectangle", .indigo, L("popbar.capsule.border"))
                    }
                }
                if store.style == .liquidGlass {
                    Toggle(isOn: Binding(get: { store.wheelLiquidDividers },
                                         set: { store.setWheelLiquidDividers($0) })) {
                        iconLabel("circle.dotted", .indigo, L("popbar.donut.dividers"))
                    }
                }
                if store.style == .donut {
                    Toggle(isOn: Binding(get: { store.wheelDonutDividers },
                                         set: { store.setWheelDonutDividers($0) })) {
                        iconLabel("circle.dotted", .indigo, L("popbar.donut.dividers"))
                    }
                }
                if store.style.isWheel {
                    radiusRow(label: L("popbar.wheel.outer"), symbol: "circle.circle",
                              value: store.wheelOuterRadius,
                              range: PopBarPreferences.wheelOuterRadiusRange) {
                        store.setWheelOuterRadius($0)
                    }
                    radiusRow(label: L("popbar.wheel.inner"), symbol: "smallcircle.circle",
                              value: store.wheelInnerRadius,
                              range: PopBarPreferences.wheelInnerRadiusRange) {
                        store.setWheelInnerRadius($0)
                    }
                    radiusRow(label: L("popbar.wheel.subSeam"), symbol: "circle.dashed",
                              value: store.wheelSubSeam,
                              range: PopBarPreferences.wheelSubSeamRange) {
                        store.setWheelSubSeam($0)
                    }
                    radiusRow(label: L("popbar.wheel.subThickness"), symbol: "circle.circle.fill",
                              value: store.wheelSubThickness,
                              range: PopBarPreferences.wheelSubThicknessRange) {
                        store.setWheelSubThickness($0)
                    }
                    Toggle(isOn: Binding(get: { store.wheelShowIcons },
                                         set: { store.setWheelShowIcons($0) })) {
                        iconLabel("square.grid.2x2", .indigo, L("popbar.wheel.showIcons"))
                    }
                    Toggle(isOn: Binding(get: { store.wheelShowLabels },
                                         set: { store.setWheelShowLabels($0) })) {
                        iconLabel("textformat", .indigo, L("popbar.wheel.showLabels"))
                    }
                    Toggle(isOn: Binding(get: { store.wheelAutoHideOnExit },
                                         set: { store.setWheelAutoHideOnExit($0) })) {
                        iconLabel("cursorarrow.motionlines", .indigo, L("popbar.wheel.autoHide"))
                    }
                }
                HStack {
                    Spacer()
                    // Resets only the selected style's own settings. Asks first: tuned
                    // values cannot be got back once reset.
                    Button { confirmingReset = true } label: {
                        Label(L("popbar.reset.button"), systemImage: "arrow.counterclockwise")
                    }
                    .confirmationDialog(String(format: L("popbar.reset.confirm"), styleName(store.style)),
                                        isPresented: $confirmingReset,
                                        titleVisibility: .visible) {
                        Button(L("popbar.reset.action"), role: .destructive) { store.resetStyleSettings() }
                        Button(L("popbar.reset.cancel"), role: .cancel) {}
                    }
                }
            }
        } header: {
            HStack {
                Text(String(format: L("popbar.advanced.header"), styleName(store.style)))
                Spacer()
                Button(showingAdvanced ? L("popbar.advanced.hide") : L("popbar.advanced.show")) {
                    withAnimation(.easeInOut(duration: 0.2)) { showingAdvanced.toggle() }
                }
                .buttonStyle(.link)
                .font(.callout)
            }
        } footer: {
            // Folded, the section has no rows, and its header would sit right on top
            // of the next one's; this says what is inside and keeps them apart.
            if !showingAdvanced {
                Text(L("popbar.advanced.collapsed"))
            }
        }
    }

    private func styleName(_ style: PopBarStyle) -> String {
        switch style {
        case .liquidGlass: return L("popbar.style.liquid")
        case .donut: return L("popbar.style.donut")
        case .capsule: return L("popbar.style.capsule")
        }
    }

    /// A labeled slider with its value shown, used for every wheel dimension.
    private func radiusRow(label: String, symbol: String, value: Double,
                           range: ClosedRange<Double>,
                           onChange: @escaping (Double) -> Void) -> some View {
        LabeledContent {
            HStack(spacing: 10) {
                Slider(value: Binding(get: { value }, set: { onChange($0) }), in: range, step: 1)
                    .frame(maxWidth: 180)
                Text("\(Int(value))")
                    .font(.system(size: 11, weight: .medium).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 28, alignment: .trailing)
            }
        } label: {
            iconLabel(symbol, .indigo, label)
        }
    }

    // MARK: - Result

    private var resultSection: some View {
        Section {
            Toggle(isOn: Binding(get: { store.autoExpandHeight },
                                 set: { store.setAutoExpandHeight($0) })) {
                iconLabel("arrow.up.and.down.text.horizontal", .indigo, L("popbar.autoheight.label"))
            }
            LabeledContent {
                HStack(spacing: 10) {
                    Slider(value: Binding(get: { store.resultFontSize },
                                          set: { store.setResultFontSize($0) }),
                           in: PopBarPreferences.resultFontSizeRange, step: 1)
                        .frame(maxWidth: 180)
                    Text("\(Int(store.resultFontSize))")
                        .font(.system(size: 11, weight: .medium).monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(width: 22, alignment: .trailing)
                }
            } label: {
                iconLabel("textformat.size", .indigo, L("popbar.fontsize.label"))
            }
            Picker(selection: Binding(get: { store.readingHighlight },
                                      set: { store.setReadingHighlight($0) })) {
                Text(L("popbar.readingHighlight.pill")).tag(ReadingHighlightStyle.pill)
                Text(L("popbar.readingHighlight.marker")).tag(ReadingHighlightStyle.marker)
                Text(L("popbar.readingHighlight.solid")).tag(ReadingHighlightStyle.solid)
                Text(L("popbar.readingHighlight.karaoke")).tag(ReadingHighlightStyle.karaoke)
            } label: {
                iconLabel("highlighter", .indigo, L("popbar.readingHighlight.label"))
            }
        } header: {
            Text(L("popbar.result.header"))
        } footer: {
            VStack(alignment: .leading, spacing: 4) {
                Text(L("popbar.autoheight.footer"))
                Text(L("popbar.fontsize.footer"))
            }
            .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// The style switch: the system segmented control, with the selected segment
/// filled in the accent colour (`selectedSegmentBezelColor`). Left plain, the
/// selected segment on macOS 26 is a raised light chip that reads as one more
/// button rather than as the choice that is in effect.
private struct StyleSegments: NSViewRepresentable {
    @Binding var selection: PopBarStyle
    let styles: [PopBarStyle]
    let title: (PopBarStyle) -> String

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSSegmentedControl {
        let control = NSSegmentedControl(labels: styles.map(title), trackingMode: .selectOne,
                                         target: context.coordinator, action: #selector(Coordinator.changed(_:)))
        control.selectedSegmentBezelColor = .controlAccentColor
        control.segmentDistribution = .fillEqually
        control.controlSize = .large
        return control
    }

    func updateNSView(_ control: NSSegmentedControl, context: Context) {
        context.coordinator.parent = self
        for (i, style) in styles.enumerated() where control.label(forSegment: i) != title(style) {
            control.setLabel(title(style), forSegment: i)   // the app's language can change live
        }
        control.selectedSegment = styles.firstIndex(of: selection) ?? -1
    }

    final class Coordinator: NSObject {
        var parent: StyleSegments
        init(_ parent: StyleSegments) { self.parent = parent }

        @objc func changed(_ sender: NSSegmentedControl) {
            guard parent.styles.indices.contains(sender.selectedSegment) else { return }
            parent.selection = parent.styles[sender.selectedSegment]
        }
    }
}
