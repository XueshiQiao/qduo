import SwiftUI
import AppKit

/// The About page: a centered app hero, author/cross-promo link rows, the
/// anonymous-usage opt-out, and copyright. A check-for-updates button lives in
/// the page toolbar. Mirrors AnyDrag's AboutPage.
struct AboutPage: View {
    @EnvironmentObject var appState: AppState
    @State private var updateSpin = 0
    @State private var analyticsEnabled = Preferences.analyticsEnabled

    private static let brandTint  = Color(red: 0.16, green: 0.17, blue: 0.20)

    private var versionString: String {
        String(format: L("about.version.format"), Brand.version, Brand.build)
    }

    var body: some View {
        Form {
            Section {
                VStack(spacing: 10) {
                    Image("AppLogo")
                        .resizable().frame(width: 84, height: 84)
                        .clipShape(RoundedRectangle(cornerRadius: 19, style: .continuous))
                    Text(Brand.name).font(.title2).fontWeight(.bold)
                    Text(versionString).font(.callout).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                Text(L("popbar.about.body"))
                    .font(.caption).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity)
            }

            Section {
                if let repo = Brand.repoURL {
                    linkRow(asset: "GitHubLogo", tint: Self.brandTint,
                            title: L("GitHub Repository"), url: repo)
                }
                linkRow(asset: "XLogo", tint: Self.brandTint,
                        title: Brand.authorXHandle, url: Brand.authorXURL)
                linkRow(systemImage: "globe", tint: .blue,
                        title: "\(L("about.website.description")) \(Brand.authorWebsiteURL.host ?? "")",
                        url: Brand.authorWebsiteURL)
            }

            Section {
                Toggle(isOn: Binding(get: { analyticsEnabled }, set: { setAnalytics($0) })) {
                    iconLabel("chart.bar.fill", .purple, L("about.analytics.toggle"))
                }
                Text(L("about.analytics.subtitle"))
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section {
                Text(L("about.copyright"))
                    .font(.caption).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
            }
        }
        .formStyle(.grouped)
        .navigationTitle(L("About"))
        // The setting lives in the config file, which can be edited by hand, so a
        // one-shot copy taken when the page opened would go stale.
        .onReceive(NotificationCenter.default.publisher(for: .configReloadedFromDisk)) { _ in
            analyticsEnabled = Preferences.analyticsEnabled
        }
        .toolbar {
            ToolbarItem {
                Button {
                    updateSpin += 1
                    appState.updateController.checkForUpdates(nil)
                } label: {
                    if #available(macOS 15, *) {
                        Label(L("Check for Updates…"), systemImage: "arrow.triangle.2.circlepath")
                            .symbolEffect(.rotate, value: updateSpin)
                    } else {
                        Label(L("Check for Updates…"), systemImage: "arrow.triangle.2.circlepath")
                    }
                }
                .disabled(!appState.updateController.canCheckForUpdates)
            }
        }
    }

    private func setAnalytics(_ on: Bool) {
        analyticsEnabled = on
        Preferences.setAnalyticsEnabled(on)
    }

    private func linkRow(asset: String? = nil, systemImage: String? = nil,
                         tint: Color, title: String, url: URL) -> some View {
        Button {
            NSWorkspace.shared.open(url)
        } label: {
            HStack(spacing: 10) {
                if let asset { AssetIconTile(asset: asset, color: tint) }
                else if let systemImage { IconTile(symbol: systemImage, color: tint) }
                Text(title)
                Spacer()
                Image(systemName: "arrow.up.right").font(.caption).foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
