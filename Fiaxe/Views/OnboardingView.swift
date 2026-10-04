import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// First-launch walkthrough: introduces R2 Vault, connects the first bucket, and points out
/// where the app lives on each platform. Shown in place of the main interface until finished.
struct OnboardingView: View {
    @Environment(AppViewModel.self) private var viewModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private enum Step: Int, CaseIterable {
        case welcome, connect, finish
    }

    private enum Field: Hashable {
        case accountId, accessKeyId, secretAccessKey, bucketName, customDomain

        var title: String {
            switch self {
            case .accountId: "Account ID"
            case .accessKeyId: "Access Key ID"
            case .secretAccessKey: "Secret Access Key"
            case .bucketName: "Bucket Name"
            case .customDomain: "Custom Domain (optional)"
            }
        }

        var prompt: String {
            switch self {
            case .accountId: "Account ID or S3 endpoint"
            case .accessKeyId: "Access key from your API token"
            case .secretAccessKey: "Secret from your API token"
            case .bucketName: "my-bucket"
            case .customDomain: "https://cdn.example.com"
            }
        }

        var symbol: String {
            switch self {
            case .accountId: "person.text.rectangle"
            case .accessKeyId: "key.horizontal"
            case .secretAccessKey: "lock.fill"
            case .bucketName: "shippingbox.fill"
            case .customDomain: "globe"
            }
        }
    }

    private struct Feature {
        let symbol: String
        let tint: Color
        let title: String
        let detail: String
    }

    private static let apiTokensURL = URL(string: "https://dash.cloudflare.com/?to=/:account/r2/api-tokens")!

    @State private var step: Step = .welcome
    @State private var isMovingForward = true
    @State private var welcomeAppeared = false
    @State private var finishAppeared = false

    // The connection form. `draftID` stays the same for the whole walkthrough, so connecting
    // again after going back updates the saved connection instead of adding a second one.
    @State private var draftID = UUID()
    @State private var accountId = ""
    @State private var accessKeyId = ""
    @State private var secretAccessKey = ""
    @State private var bucketName = ""
    @State private var customDomain = ""
    // Taken from a pasted S3 endpoint, e.g. `<account>.eu.r2.cloudflarestorage.com`.
    @State private var jurisdiction: R2Jurisdiction = .auto
    @State private var revealSecret = false
    @State private var showTokenHelp = false
    @State private var isConnecting = false
    @State private var connectionError: String?
    @State private var connectedCredentials: R2Credentials?
    @FocusState private var focusedField: Field?

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                currentPage
                    .id(step)
                    .transition(pageTransition)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipped()

            footer
        }
        .background { OnboardingBackground() }
#if os(macOS)
        .frame(minWidth: 820, minHeight: 600)
        .toolbar(removing: .title)
        .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
#else
        .overlay(alignment: .topLeading) {
            if step != .welcome {
                Button(action: goBack) {
                    Image(systemName: "chevron.left")
                        .font(.body.weight(.semibold))
                        .frame(width: 22, height: 22)
                }
                .buttonStyle(.bordered)
                .buttonBorderShape(.circle)
                .disabled(isConnecting)
                .accessibilityLabel("Back")
                .padding(.leading, 16)
                .padding(.top, 8)
                .transition(.opacity)
            }
        }
#endif
    }

    // MARK: - Pages

    @ViewBuilder
    private var currentPage: some View {
        switch step {
        case .welcome: page { welcomePage }
        case .connect: page { connectPage }
        case .finish: page { finishPage }
        }
    }

    /// Centers a page's content, scrolling only when it doesn't fit.
    private func page<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        ScrollView {
            content()
                .frame(maxWidth: 520)
                .padding(.horizontal, 28)
#if os(macOS)
                .padding(.top, 36)
#else
                .padding(.top, 48)
#endif
                .padding(.bottom, 20)
                .frame(maxWidth: .infinity)
        }
        .scrollBounceBehavior(.basedOnSize)
        .defaultScrollAnchor(.center, for: .alignment)
        .scrollDismissesKeyboard(.interactively)
    }

    private var welcomePage: some View {
        VStack(spacing: 30) {
            VStack(spacing: 16) {
                AppIconView()
                    .frame(width: 96, height: 96)
                    .shadow(color: Color.accentColor.opacity(0.35), radius: 22, y: 10)

                VStack(spacing: 6) {
                    Text("Welcome to R2 Vault")
                        .font(.largeTitle.weight(.bold))
                    Text("A fast, native home for your Cloudflare R2 storage.")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                }
                .multilineTextAlignment(.center)
            }
            .modifier(EntranceModifier(index: 0, isVisible: welcomeAppeared, reduceMotion: reduceMotion))

            VStack(alignment: .leading, spacing: 18) {
                ForEach(Array(Self.features.enumerated()), id: \.offset) { index, feature in
                    HStack(alignment: .top, spacing: 16) {
                        IconTile(symbol: feature.symbol, tint: feature.tint, size: 44)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(feature.title)
                                .font(.headline)
                            Text(feature.detail)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 0)
                    }
                    .accessibilityElement(children: .combine)
                    .modifier(EntranceModifier(index: index + 1, isVisible: welcomeAppeared, reduceMotion: reduceMotion))
                }
            }
            .frame(maxWidth: 440)
        }
        .onAppear { welcomeAppeared = true }
    }

    private var connectPage: some View {
        VStack(spacing: 22) {
            pageHeader(
                symbol: "key.fill",
                title: "Connect your bucket",
                subtitle: "Enter the details from an R2 API token. They're kept in your Keychain and only ever sent to Cloudflare."
            )

            tokenHelp

            credentialFields

            if let connectionError {
                Label(connectionError, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .transition(.opacity)
            } else if let connectedCredentials, connectedCredentials == draftCredentials {
                Label("Connected to \u{201C}\(connectedCredentials.bucketName)\u{201D}", systemImage: "checkmark.circle.fill")
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.green)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .transition(.opacity)
            }
        }
        .onChange(of: accountId) { _, newValue in
            // Pasting the S3 endpoint works too: keep the account ID and jurisdiction, and take
            // the bucket from the end of the URL if the bucket name hasn't been filled in yet.
            if newValue.isEmpty { jurisdiction = .auto }
            guard newValue.contains(".r2.cloudflarestorage.com") else { return }
            if value(of: .bucketName).isEmpty, let bucket = Self.bucketName(fromEndpoint: newValue) {
                bucketName = bucket
            }
            jurisdiction = R2Jurisdiction(endpoint: newValue) ?? .auto
            accountId = Self.accountID(fromInput: newValue)
        }
    }

    private var finishPage: some View {
        VStack(spacing: 28) {
            VStack(spacing: 14) {
                Image(systemName: "checkmark")
                    .font(.system(size: 36, weight: .bold))
                    .foregroundStyle(.white)
                    .symbolEffect(.bounce, value: finishAppeared)
                    .frame(width: 80, height: 80)
                    .background(Circle().fill(Color.accentColor.gradient))
                    .shadow(color: Color.accentColor.opacity(0.4), radius: 20, y: 8)
                    .accessibilityHidden(true)

                VStack(spacing: 6) {
                    Text(hasBucket ? "You're all set" : "You're ready to go")
                        .font(.largeTitle.weight(.bold))
                    Group {
                        if let connectedCredentials {
                            Text("\u{201C}\(connectedCredentials.bucketName)\u{201D} is connected and ready for uploads.")
                        } else if hasBucket {
                            Text("Here's where to find things.")
                        } else {
                            Text("Connect a bucket whenever you're ready. Here's where to find things.")
                        }
                    }
                    .font(.title3)
                    .foregroundStyle(.secondary)
                }
                .multilineTextAlignment(.center)
            }

            VStack(spacing: 12) {
#if os(macOS)
                TipCard(
                    symbol: "square.and.arrow.up",
                    tint: .purple,
                    title: "Find R2 Vault in your menu bar",
                    detail: "Click its icon for recent uploads, or drop files onto it to upload from any app."
                )
                if let connectedCredentials {
                    finderDriveCard(connectedCredentials)
                }
                TipCard(
                    symbol: "gearshape.fill",
                    tint: .gray,
                    title: hasBucket ? "Add more buckets any time" : "Add a bucket in Settings",
                    detail: "Open Settings with \u{2318}, to add or switch R2 connections."
                )
#else
                TipCard(
                    symbol: "plus",
                    tint: .blue,
                    title: "Upload with the + button",
                    detail: "In the Files tab, tap + to add photos, videos, or documents."
                )
                TipCard(
                    symbol: "lock.iphone",
                    tint: Color.accentColor,
                    title: "Watch progress on your Lock Screen",
                    detail: "Long uploads show a Live Activity, so you can check in without opening the app."
                )
                TipCard(
                    symbol: "gearshape.fill",
                    tint: .gray,
                    title: hasBucket ? "Add more buckets any time" : "Add a bucket in Settings",
                    detail: "Use the Settings tab to add or switch R2 connections."
                )
#endif
            }
        }
        .onAppear { finishAppeared = true }
    }

    // MARK: - Connect Page Parts

    /// False only when nothing is connected yet: someone replaying the walkthrough from the
    /// Help menu may already have buckets even if they skip connecting one here.
    private var hasBucket: Bool {
        connectedCredentials != nil || !viewModel.credentialsList.isEmpty
    }

    private func pageHeader(symbol: String, title: String, subtitle: String) -> some View {
        VStack(spacing: 14) {
            IconTile(symbol: symbol, tint: Color.accentColor, size: 56)
                .shadow(color: Color.accentColor.opacity(0.3), radius: 16, y: 6)
            VStack(spacing: 6) {
                Text(title)
                    .font(.largeTitle.weight(.bold))
                Text(subtitle)
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .multilineTextAlignment(.center)
        }
    }

    private var tokenHelp: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button {
                withAnimation(.snappy) { showTokenHelp.toggle() }
            } label: {
                HStack {
                    Label("Where do I find these?", systemImage: "questionmark.circle.fill")
                        .font(.callout.weight(.medium))
                    Spacer()
                    Image(systemName: "chevron.down")
                        .font(.caption.weight(.semibold))
                        .rotationEffect(.degrees(showTokenHelp ? 180 : 0))
                        .foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint(showTokenHelp ? "Hides the steps" : "Shows how to create an R2 API token")

            if showTokenHelp {
                VStack(alignment: .leading, spacing: 10) {
                    helpStep(1, "In the Cloudflare dashboard, open **R2** and choose **Manage API Tokens**.")
                    helpStep(2, "Create a token with **Object Read & Write** access to your bucket.")
                    helpStep(3, "Copy the **Access Key ID** and **Secret Access Key**. Your **Account ID** is on the R2 overview page, or paste the S3 endpoint.")
                    Link(destination: Self.apiTokensURL) {
                        Label("Open Cloudflare Dashboard", systemImage: "arrow.up.forward.app")
                            .font(.callout.weight(.medium))
                    }
                    .padding(.top, 2)
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.accentColor.opacity(0.08))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.accentColor.opacity(0.2), lineWidth: 1)
        )
    }

    private func helpStep(_ number: Int, _ text: LocalizedStringKey) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text("\(number)")
                .font(.caption.weight(.bold))
                .foregroundStyle(.white)
                .frame(width: 18, height: 18)
                .background(Circle().fill(Color.accentColor))
            Text(text)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private var credentialFields: some View {
#if os(macOS)
        Grid(horizontalSpacing: 12, verticalSpacing: 14) {
            GridRow {
                field(.accountId)
                field(.bucketName)
            }
            GridRow {
                field(.accessKeyId)
                field(.secretAccessKey)
            }
            GridRow {
                field(.customDomain)
                    .gridCellColumns(2)
            }
        }
#else
        VStack(spacing: 14) {
            ForEach(Self.fieldOrder, id: \.self) { field($0) }
        }
#endif
    }

    private func field(_ field: Field) -> some View {
        let isFocused = focusedField == field
        let showsDomainError = field == .customDomain && customDomainIsInvalid

        return VStack(alignment: .leading, spacing: 6) {
            Text(field.title)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.secondary)

            HStack(spacing: 10) {
                Image(systemName: field.symbol)
                    .foregroundStyle(isFocused ? Color.accentColor : .secondary)
                    .frame(width: 18)
                    .accessibilityHidden(true)

                input(for: field)
                    .textFieldStyle(.plain)
                    .focused($focusedField, equals: field)
                    .onSubmit { submit(from: field) }
#if os(iOS)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .submitLabel(field == .customDomain ? .go : .next)
#endif

                if field == .secretAccessKey {
                    Button {
                        revealSecret.toggle()
                        focusedField = .secretAccessKey
                    } label: {
                        Image(systemName: revealSecret ? "eye.slash" : "eye")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help(revealSecret ? "Hide Secret" : "Show Secret")
                    .accessibilityLabel(revealSecret ? "Hide secret" : "Show secret")
                }
            }
            .padding(.horizontal, 12)
#if os(macOS)
            .frame(height: 34)
#else
            .frame(height: 48)
#endif
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(.background)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(
                        showsDomainError ? Color.red : (isFocused ? Color.accentColor : Color.primary.opacity(0.12)),
                        lineWidth: isFocused || showsDomainError ? 1.5 : 1
                    )
            )
            .animation(.easeOut(duration: 0.15), value: isFocused)

            if showsDomainError {
                Text("Use a full https:// address without ? or # parts.")
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
    }

    @ViewBuilder
    private func input(for field: Field) -> some View {
        let prompt = Text(field.prompt)
        switch field {
        case .accountId:
            TextField(field.title, text: $accountId, prompt: prompt)
        case .accessKeyId:
            TextField(field.title, text: $accessKeyId, prompt: prompt)
        case .secretAccessKey:
            if revealSecret {
                TextField(field.title, text: $secretAccessKey, prompt: prompt)
            } else {
                SecureField(field.title, text: $secretAccessKey, prompt: prompt)
            }
        case .bucketName:
            TextField(field.title, text: $bucketName, prompt: prompt)
        case .customDomain:
            TextField(field.title, text: $customDomain, prompt: prompt)
#if os(iOS)
                .keyboardType(.URL)
#endif
        }
    }

#if os(macOS)
    @ViewBuilder
    private func finderDriveCard(_ credentials: R2Credentials) -> some View {
        let drive = viewModel.finderDrive
        let id = credentials.id

        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 14) {
                IconTile(symbol: "externaldrive.fill", tint: .green, size: 40)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Show \u{201C}\(credentials.bucketName)\u{201D} in Finder")
                        .font(.headline)
                    Text("It appears under Locations. Files stream when opened and use no disk space.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 12)
                if drive.pendingIDs.contains(id) {
                    ProgressView()
                        .controlSize(.small)
                }
                Toggle("Show in Finder", isOn: Binding(
                    get: { drive.isEnabled(id) },
                    set: { enabled in Task { await drive.setEnabled(enabled, for: credentials) } }
                ))
                .labelsHidden()
                .toggleStyle(.switch)
                .disabled(drive.pendingIDs.contains(id))
            }

            if drive.awaitingApprovalIDs.contains(id) {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Label("Turn on R2Vault under File Providers in System Settings to finish.", systemImage: "exclamationmark.triangle.fill")
                        .font(.callout)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 8)
                    Button("Open System Settings") { drive.openExtensionSettings() }
                        .controlSize(.small)
                }
            } else if let error = drive.errors[id] {
                Text(error)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .modifier(CardStyle())
    }
#endif

    // MARK: - Footer

    private var footer: some View {
#if os(macOS)
        ZStack {
            pageDots
            HStack(spacing: 10) {
                if step != .welcome {
                    Button("Back", action: goBack)
                        .controlSize(.large)
                        .disabled(isConnecting)
                }
                Spacer()
                if isConnecting {
                    ProgressView()
                        .controlSize(.small)
                }
                if step == .connect {
                    Button("Set Up Later") { go(to: .finish) }
                        .controlSize(.large)
                        .disabled(isConnecting)
                }
                primaryButton
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 18)
#else
        VStack(spacing: 14) {
            pageDots
            primaryButton
            if step == .connect {
                Button("Set Up Later") { go(to: .finish) }
                    .font(.callout.weight(.medium))
                    .disabled(isConnecting)
            }
        }
        .padding(.horizontal, 24)
        .padding(.top, 12)
        .padding(.bottom, 16)
#endif
    }

    private var primaryButton: some View {
        Button(action: primaryAction) {
            HStack(spacing: 8) {
#if os(iOS)
                if isConnecting {
                    ProgressView()
                        .tint(.white)
                }
#endif
                Text(primaryTitle)
                    .fontWeight(.semibold)
            }
#if os(macOS)
            .frame(minWidth: 96)
#else
            .frame(maxWidth: .infinity)
#endif
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .keyboardShortcut(.defaultAction)
        .disabled(step == .connect && (!formIsComplete || isConnecting))
    }

    private var primaryTitle: String {
        switch step {
        case .welcome: "Get Started"
        case .connect: isConnecting ? "Connecting\u{2026}" : "Connect"
        case .finish: "Start Using R2 Vault"
        }
    }

    private var pageDots: some View {
        HStack(spacing: 7) {
            ForEach(Step.allCases, id: \.self) { item in
                Capsule()
                    .fill(item == step ? Color.accentColor : Color.primary.opacity(0.18))
                    .frame(width: item == step ? 20 : 7, height: 7)
            }
        }
        .animation(.spring(response: 0.4, dampingFraction: 0.8), value: step)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Step \(step.rawValue + 1) of \(Step.allCases.count)")
    }

    // MARK: - Navigation

    private var pageTransition: AnyTransition {
        guard !reduceMotion else { return .opacity }
        let fromTrailing = AnyTransition.offset(x: 48).combined(with: .opacity)
        let fromLeading = AnyTransition.offset(x: -48).combined(with: .opacity)
        return isMovingForward
            ? .asymmetric(insertion: fromTrailing, removal: fromLeading)
            : .asymmetric(insertion: fromLeading, removal: fromTrailing)
    }

    private func go(to next: Step) {
        focusedField = nil
        let forward = next.rawValue > step.rawValue
        let animation: Animation = reduceMotion ? .easeInOut(duration: 0.2) : .spring(response: 0.45, dampingFraction: 0.9)
        guard forward != isMovingForward else {
            withAnimation(animation) { step = next }
            return
        }
        isMovingForward = forward
        // Change pages on the next turn so the outgoing page picks up the new direction first.
        DispatchQueue.main.async {
            withAnimation(animation) { step = next }
        }
    }

    private func goBack() {
        guard let previous = Step(rawValue: step.rawValue - 1) else { return }
        go(to: previous)
    }

    private func primaryAction() {
        switch step {
        case .welcome:
            go(to: .connect)
        case .connect:
            Task { await connect() }
        case .finish:
            viewModel.completeOnboarding()
        }
    }

    private func submit(from field: Field) {
#if os(macOS)
        // Return connects once everything needed is filled in; otherwise it moves along.
        if formIsComplete {
            Task { await connect() }
            return
        }
        focusedField = Self.fieldOrder.first { $0 != .customDomain && value(of: $0).isEmpty } ?? .customDomain
#else
        guard let index = Self.fieldOrder.firstIndex(of: field), index + 1 < Self.fieldOrder.count else {
            Task { await connect() }
            return
        }
        focusedField = Self.fieldOrder[index + 1]
#endif
    }

    // MARK: - Connecting

    private static let fieldOrder: [Field] = [.accountId, .accessKeyId, .secretAccessKey, .bucketName, .customDomain]

    private func value(of field: Field) -> String {
        let raw = switch field {
        case .accountId: accountId
        case .accessKeyId: accessKeyId
        case .secretAccessKey: secretAccessKey
        case .bucketName: bucketName
        case .customDomain: customDomain
        }
        return raw.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var customDomainIsInvalid: Bool {
        let domain = value(of: .customDomain)
        return !domain.isEmpty && R2Credentials.normalizedCustomDomain(domain) == nil
    }

    private var formIsComplete: Bool {
        [Field.accountId, .accessKeyId, .secretAccessKey, .bucketName].allSatisfy { !value(of: $0).isEmpty }
            && !customDomainIsInvalid
    }

    private var draftCredentials: R2Credentials {
        R2Credentials(
            id: draftID,
            accountId: Self.accountID(fromInput: accountId),
            accessKeyId: value(of: .accessKeyId),
            secretAccessKey: value(of: .secretAccessKey),
            bucketName: value(of: .bucketName),
            customDomain: R2Credentials.normalizedCustomDomain(value(of: .customDomain)),
            jurisdiction: jurisdiction
        )
    }

    private func connect() async {
        guard formIsComplete, !isConnecting else { return }
        let credentials = draftCredentials

        focusedField = nil
        isConnecting = true
        withAnimation { connectionError = nil }
        defer { isConnecting = false }

        do {
            let status = try await R2UploadService.bucketStatusCode(credentials: credentials)
            guard status == 200 else {
                withAnimation { connectionError = Self.connectionMessage(forStatus: status, bucket: credentials.bucketName) }
                return
            }
        } catch {
            withAnimation { connectionError = error.localizedDescription }
            return
        }

        viewModel.saveCredentials(credentials)
        viewModel.selectCredentials(id: credentials.id)
        accountId = credentials.accountId
        customDomain = credentials.customDomain ?? ""
        connectedCredentials = credentials
        go(to: .finish)
    }

    private static func connectionMessage(forStatus status: Int, bucket: String) -> String {
        switch status {
        case 401, 403:
            "Cloudflare didn't accept these details. Check the Account ID and keys, and that the token can access \u{201C}\(bucket)\u{201D}."
        case 404:
            "There's no bucket named \u{201C}\(bucket)\u{201D} in this account. Check the bucket name and Account ID. If the bucket is in a jurisdiction such as the EU, paste its S3 endpoint into Account ID instead."
        case 400:
            "Cloudflare couldn't read the request. Check that the Account ID is correct."
        default:
            "Couldn't connect to R2 (HTTP \(status)). Check your details and try again."
        }
    }

    /// Accepts a bare account ID or the token's S3 endpoint
    /// (`https://<account>.r2.cloudflarestorage.com`) and returns the account ID.
    private static func accountID(fromInput input: String) -> String {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        let withScheme = trimmed.contains("://") ? trimmed : "https://\(trimmed)"
        guard trimmed.contains(".r2.cloudflarestorage.com"),
              let host = URLComponents(string: withScheme)?.host,
              let account = host.split(separator: ".").first else {
            return trimmed
        }
        return String(account)
    }

    /// The bucket in an endpoint like `https://<account>.r2.cloudflarestorage.com/<bucket>`.
    private static func bucketName(fromEndpoint input: String) -> String? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        let withScheme = trimmed.contains("://") ? trimmed : "https://\(trimmed)"
        return URLComponents(string: withScheme)?.path
            .split(separator: "/")
            .first
            .map(String.init)
    }

    // MARK: - Content

#if os(macOS)
    private static let features: [Feature] = [
        Feature(symbol: "folder.fill", tint: .blue, title: "Browse every bucket",
                detail: "Finder-style folders, Quick Look previews, and fast search."),
        Feature(symbol: "arrow.up.circle.fill", tint: Color.accentColor, title: "Drag, drop, done",
                detail: "Drop files or whole folders to upload. The public link is copied for you."),
        Feature(symbol: "menubar.rectangle", tint: .purple, title: "Always in your menu bar",
                detail: "Drop files on the menu bar icon to upload without opening a window."),
        Feature(symbol: "externaldrive.fill", tint: .green, title: "Your bucket in Finder",
                detail: "Mount a bucket as a drive. Files stream on demand and use no disk space."),
    ]
#else
    private static let features: [Feature] = [
        Feature(symbol: "folder.fill", tint: .blue, title: "Browse every bucket",
                detail: "Folders, previews, and search for everything in R2."),
        Feature(symbol: "photo.on.rectangle.angled", tint: Color.accentColor, title: "Upload photos and files",
                detail: "Send photos, videos, and documents. The public link is copied for you."),
        Feature(symbol: "chart.pie.fill", tint: .purple, title: "See what's using space",
                detail: "The dashboard breaks your storage down by file type and size."),
        Feature(symbol: "lock.shield.fill", tint: .green, title: "Private by design",
                detail: "Your keys stay in the Keychain and only ever go to Cloudflare."),
    ]
#endif
}

// MARK: - Building Blocks

/// A rounded, gradient-filled square holding a white SF Symbol, like a Settings icon.
private struct IconTile: View {
    let symbol: String
    let tint: Color
    var size: CGFloat = 40

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.44, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(
                RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
                    .fill(tint.gradient)
            )
            .accessibilityHidden(true)
    }
}

private struct TipCard: View {
    let symbol: String
    let tint: Color
    let title: String
    let detail: String

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            IconTile(symbol: symbol, tint: tint, size: 40)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.headline)
                Text(detail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
        .modifier(CardStyle())
    }
}

private struct CardStyle: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
            )
    }
}

/// Fades and lifts content in, one item after another, the first time a page appears.
private struct EntranceModifier: ViewModifier {
    let index: Int
    let isVisible: Bool
    let reduceMotion: Bool

    func body(content: Content) -> some View {
        content
            .opacity(isVisible ? 1 : 0)
            .offset(y: isVisible || reduceMotion ? 0 : 14)
            .animation(
                .spring(response: 0.55, dampingFraction: 0.85).delay(0.08 * Double(index)),
                value: isVisible
            )
    }
}

/// The app icon, as shown in the Dock or on the Home Screen.
private struct AppIconView: View {
    var body: some View {
#if os(macOS)
        if let icon = NSImage(named: NSImage.applicationIconName) {
            Image(nsImage: icon)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
        } else {
            fallback
        }
#else
        if let icon = Self.homeScreenIcon {
            Image(uiImage: icon)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        } else {
            fallback
        }
#endif
    }

    private var fallback: some View {
        GeometryReader { proxy in
            IconTile(symbol: "externaldrive.badge.icloud", tint: Color.accentColor, size: proxy.size.width)
        }
    }

#if os(iOS)
    private static var homeScreenIcon: UIImage? {
        guard let icons = Bundle.main.infoDictionary?["CFBundleIcons"] as? [String: Any],
              let primary = icons["CFBundlePrimaryIcon"] as? [String: Any],
              let files = primary["CFBundleIconFiles"] as? [String],
              let name = files.last else {
            return nil
        }
        return UIImage(named: name)
    }
#endif
}

/// A warm glow in the app's accent color behind the walkthrough.
private struct OnboardingBackground: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ZStack {
#if os(macOS)
            Color(nsColor: .windowBackgroundColor)
#else
            Color(uiColor: .systemBackground)
#endif
            RadialGradient(
                colors: [Color.accentColor.opacity(colorScheme == .dark ? 0.32 : 0.22), .clear],
                center: UnitPoint(x: 0.5, y: -0.15),
                startRadius: 0,
                endRadius: 560
            )
            RadialGradient(
                colors: [Color(red: 1, green: 0.42, blue: 0.5).opacity(colorScheme == .dark ? 0.14 : 0.1), .clear],
                center: .bottomLeading,
                startRadius: 0,
                endRadius: 460
            )
        }
        .ignoresSafeArea()
    }
}

#Preview {
    OnboardingView()
        .environment(AppViewModel())
        .accentColor(Color(red: 0xF8/255, green: 0x69/255, blue: 0x36/255))
}
