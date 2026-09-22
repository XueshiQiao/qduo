import SwiftUI

/// The Appearance page: which shape the popup takes, the geometry of the ring
/// styles, and how a result is rendered once an action produces text.
///
/// Every control here updates the live preview in place, so the Preview button
/// is how you tune: open it once, then drag sliders and watch.
struct AppearancePage: View {

    @ObservedObject private var store: PopBarStore

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
                    Text(L("popbar.style.capsule")).tag(PopBarStyle.capsule)
                    Text(L("popbar.style.wheel")).tag(PopBarStyle.wheel)
                    Text(L("popbar.style.liquid")).tag(PopBarStyle.liquidGlass)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(maxWidth: 220)
            } label: {
                iconLabel("circle.hexagongrid", .indigo, L("popbar.style.label"))
            }
            // The wheel and liquid-glass styles share these geometry/content knobs;
            // the capsule has none of them.
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
            Button { store.showPreview() } label: {
                Label(L("popbar.preview.button"), systemImage: "eye")
            }
        } header: {
            Text(L("popbar.display.header"))
        } footer: {
            Text(L("popbar.style.footer"))
                .fixedSize(horizontal: false, vertical: true)
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
