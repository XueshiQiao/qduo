import SwiftUI

/// The Appearance page: which shape the popup takes, the geometry of the ring
/// styles, and how a result is rendered once an action produces text.
///
/// Every control here updates the live preview in place, so the Preview button
/// is how you tune: open it once, then drag sliders and watch.
struct AppearancePage: View {

    @ObservedObject private var store: PopBarStore
    @State private var confirmingReset = false

    init(store: PopBarStore) {
        _store = ObservedObject(wrappedValue: store)
    }

    var body: some View {
        Form {
            styleSection
            resultSection
        }
        .formStyle(.grouped)
        .navigationTitle(L("page.appearance"))
        // Don't leave the live tuning preview orphaned on another page.
        .onDisappear { store.dismissPreview() }
    }

    // MARK: - Style

    private var styleSection: some View {
        Section {
            LabeledContent {
                Picker("", selection: Binding(get: { store.style }, set: { store.setStyle($0) })) {
                    Text(L("popbar.style.liquid")).tag(PopBarStyle.liquidGlass)
                    Text(L("popbar.style.donut")).tag(PopBarStyle.donut)
                    Text(L("popbar.style.capsule")).tag(PopBarStyle.capsule)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(maxWidth: 320)
            } label: {
                iconLabel("circle.hexagongrid", .indigo, L("popbar.style.label"))
            }
            // Each style has its own knobs, below. Liquid and 3D Glass have the same
            // set, but each keeps its own values.
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
                Button { store.showPreview() } label: {
                    Label(L("popbar.preview.button"), systemImage: "eye")
                }
                Spacer()
                // Resets only the selected style's own settings. Asks first: tuned
                // values cannot be got back once reset.
                Button { confirmingReset = true } label: {
                    Label(L("popbar.reset.button"), systemImage: "arrow.counterclockwise")
                }
                .confirmationDialog(String(format: L("popbar.reset.confirm"), styleName(store.style)),
                                    isPresented: $confirmingReset) {
                    Button(L("popbar.reset.action"), role: .destructive) { store.resetStyleSettings() }
                    Button(L("popbar.reset.cancel"), role: .cancel) {}
                }
            }
        } header: {
            Text(L("popbar.display.header"))
        } footer: {
            Text(L("popbar.style.footer"))
                .fixedSize(horizontal: false, vertical: true)
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
