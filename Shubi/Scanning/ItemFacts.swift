import Foundation
import UniformTypeIdentifiers

nonisolated struct Fact: Hashable, Sendable {
    /// What the deletion verdict reads. Labels and values are localized, so the verdict never compares them.
    enum Signal: Hashable, Sendable {
        case bundleID(String)
        case fromAppStore(Bool)
        /// The value lists the components; system and kernel extensions are the ones that break things when left behind.
        case systemComponents(hasExtensions: Bool)
        case inICloud
        case downloadSource(String)
        case simulatorsUsingRuntime(Int)
    }

    let label: String
    let value: String
    var signal: Signal?
}

/// Facts read straight from the file system and bundle, plus what the scanner already knows.
nonisolated enum ItemFacts {
    @concurrent static func facts(for item: ScanItem) async -> [Fact] {
        var facts: [Fact] = []
        func add(_ label: LocalizedStringResource, _ value: String?, signal: Fact.Signal? = nil) {
            if let value, !value.isEmpty { facts.append(Fact(label: String(localized: label.shown), value: value, signal: signal)) }
        }
        let values = try? item.url.resourceValues(forKeys: [.contentTypeKey, .creationDateKey, .isUbiquitousItemKey])

        add("이름", item.url.lastPathComponent)
        add("종류", item.kind.label ?? values?.contentType?.localizedDescription)
        switch item.kind {
        case .app:
            let info = Bundle(url: item.url)?.infoDictionary ?? [:]
            let bundleID = info["CFBundleIdentifier"] as? String
            add("Bundle ID", bundleID, signal: bundleID.map(Fact.Signal.bundleID))
            add("버전", info["CFBundleShortVersionString"] as? String)
            add("저작권 표기", info["NSHumanReadableCopyright"] as? String)
            add("카테고리", (info["LSApplicationCategoryType"] as? String)?.replacing("public.app-category.", with: ""))
            let receipt = item.url.appending(path: "Contents/_MASReceipt/receipt").path(percentEncoded: false)
            let fromAppStore = FileManager.default.fileExists(atPath: receipt)
            add("설치 경로", fromAppStore ? "App Store" : String(localized: "App Store 외부", bundle: .shown, locale: .shown), signal: .fromAppStore(fromAppStore))
            let components = [
                ("Contents/Library/SystemExtensions", String(localized: "시스템 확장", bundle: .shown, locale: .shown), true),
                ("Contents/Library/Extensions", String(localized: "커널 확장", bundle: .shown, locale: .shown), true),
                ("Contents/Library/LaunchDaemons", String(localized: "백그라운드 데몬", bundle: .shown, locale: .shown), false),
                ("Contents/Library/LaunchServices", String(localized: "권한 도우미", bundle: .shown, locale: .shown), false),
            ].filter { FileManager.default.fileExists(atPath: item.url.appending(path: $0.0).path(percentEncoded: false)) }
            add("시스템 구성요소", components.map(\.1).joined(separator: ", "),
                signal: .systemComponents(hasExtensions: components.contains(where: \.2)))
            let library = FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library").path(percentEncoded: false)
            add("남은 데이터", item.leftovers.map { "~/Library" + $0.path(percentEncoded: false).dropFirst(library.count) }.joined(separator: "\n"))
        case .browserCache, .cache:
            add("앱 설치 상태", item.isOrphaned ? String(localized: "삭제됨", bundle: .shown, locale: .shown) : item.isOwnerUnknown ? String(localized: "알 수 없음", bundle: .shown, locale: .shown) : String(localized: "설치됨", bundle: .shown, locale: .shown))
            add("들어 있는 항목", String(localized: "\(item.targets.count)개", bundle: .shown, locale: .shown))
        // The AI scanner puts the tool, its install state and the project into `details`.
        case .simulator, .appData, .runtime, .deviceSupport, .derivedData, .previews, .packageCache, .archive, .log, .aiData:
            break
        case .document, .largeFile:
            add("만든 날짜", values?.creationDate?.formatted(Date.FormatStyle(date: .abbreviated, time: .omitted, locale: .shown)))
            add("iCloud", values?.isUbiquitousItem == true ? String(localized: "동기화됨", bundle: .shown, locale: .shown) : nil, signal: .inICloud)
            let source = (NSMetadataItem(url: item.url)?.value(forAttribute: NSMetadataItemWhereFromsKey) as? [String])?.first
            add("다운로드 출처", source, signal: source.map(Fact.Signal.downloadSource))
        }
        facts += item.details
        add("크기", item.size.formatted(.byteCount(style: .file).locale(.shown)))
        add("마지막 사용", item.lastUsed.map { date in
            let days = Calendar.current.dateComponents([.day], from: date, to: .now).day ?? 0
            return String(localized: "\(date.formatted(Date.FormatStyle(date: .abbreviated, time: .omitted, locale: .shown))) (\(days)일 전)", bundle: .shown, locale: .shown)
        } ?? String(localized: "기록 없음", bundle: .shown, locale: .shown))
        if item.isRunning { add("상태", String(localized: "실행 중", bundle: .shown, locale: .shown)) }
        add("경로", item.url.path(percentEncoded: false))
        return facts
    }

    private static let installerExtensions: Set<String> = ["dmg", "pkg", "mpkg", "iso", "xip"]
    /// Device management, security and VPN vendors: removing these can lock the user out of work systems.
    private static let managedBundlePrefixes = [
        "com.jamf", "com.kandji", "io.kandji", "com.mosyle", "com.microsoft.intune", "com.crowdstrike",
        "com.sentinelone", "com.paloaltonetworks", "com.cisco", "com.zscaler", "com.fortinet", "com.okta",
        "com.nordvpn", "com.expressvpn", "com.malwarebytes", "com.objective-see", "com.tailscale", "com.wireguard",
    ]

    /// Decided in code, not by the model: the on-device model invents data-loss claims (e.g. "Slack messages are gone").
    /// Titles state facts rather than "go ahead": whether the user still needs the item is their call.
    static func risk(for item: ScanItem, facts: [Fact]) -> DeletionRisk {
        var bundleID = "", fromAppStore = false, inICloud = false, downloadSource: String?, simulatorsUsingRuntime = 0
        var components: (list: String, hasExtensions: Bool)?
        for fact in facts {
            switch fact.signal {
            case .bundleID(let id): bundleID = id.lowercased()
            case .fromAppStore(let value): fromAppStore = value
            case .systemComponents(let hasExtensions): components = (fact.value, hasExtensions)
            case .inICloud: inICloud = true
            case .downloadSource(let source): downloadSource = source
            case .simulatorsUsingRuntime(let count): simulatorsUsingRuntime = count
            case nil: break
            }
        }

        switch item.kind {
        case .browserCache:
            let base = String(localized: "로그인, 북마크, 방문 기록, 비밀번호는 캐시와 따로 저장돼서 그대로 남아요.", bundle: .shown, locale: .shown)
            return item.isOrphaned
                ? DeletionRisk(level: .safe, title: "앱이 이미 삭제된 캐시예요",
                               reason: "다시 쓰일 일이 없는 공간이에요. \(base)")
                : DeletionRisk(level: .safe, title: "다시 생기는 임시 파일이에요",
                               reason: "\(base) 지운 뒤 처음 여는 사이트만 잠깐 느릴 수 있어요.")
        case .cache:
            return item.isOrphaned
                ? DeletionRisk(level: .safe, title: "앱이 이미 삭제된 캐시예요", reason: "다시 쓰일 일이 없는 공간이에요.")
                : DeletionRisk(level: .safe, title: "다시 생기는 임시 파일이에요",
                               reason: "앱이 필요할 때 다시 만들어요. 처음 열 때 잠깐 느리거나 오프라인 콘텐츠를 다시 받을 수 있어요.")
        case .appData:
            return DeletionRisk(level: .caution, title: "삭제된 앱이 남긴 데이터예요",
                                reason: "설정, 로그인 정보, 앱 안에 저장한 작업물이 있을 수 있어요. 그 앱을 다시 쓰지 않을 때만 지우세요.")
        case .simulator:
            return item.isOrphaned
                ? DeletionRisk(level: .caution, title: "런타임이 지워져 지금은 실행할 수 없어요",
                               reason: "설치한 앱과 데이터가 함께 지워져요. 지우지 않고 런타임을 다시 받으면 이 기기를 다시 쓸 수 있어요.")
                : DeletionRisk(level: .caution, title: "테스트 앱과 데이터가 함께 지워져요",
                               reason: "설치한 앱과 데이터가 사라져요. 같은 기기는 Xcode에서 언제든 다시 만들 수 있어요.")
        case .runtime:
            let users = String(localized: "\(simulatorsUsingRuntime)개", bundle: .shown, locale: .shown)
            return DeletionRisk(level: simulatorsUsingRuntime == 0 ? .safe : .caution, title: "다시 받으려면 몇 GB를 내려받아야 해요",
                                reason: "이 런타임을 쓰는 시뮬레이터 \(users)를 쓸 수 없게 돼요. Xcode 설정의 Components가 이 버전을 제공하면 다시 받을 수 있어요.")
        case .deviceSupport:
            return DeletionRisk(level: .safe, title: "기기를 연결하면 다시 만들어져요",
                                reason: "실제 기기 디버깅용 심볼이에요. 이 버전의 기기를 다시 연결하면 몇 분 동안 다시 준비해요.")
        case .derivedData:
            return DeletionRisk(level: .safe, title: "다음 빌드 때 다시 만들어져요",
                                reason: "지운 뒤 첫 빌드와 코드 인덱싱만 느려져요.")
        case .previews:
            return DeletionRisk(level: .safe, title: "다음 미리보기 때 다시 만들어져요",
                                reason: "지운 뒤 처음 여는 미리보기만 조금 느려져요.")
        case .packageCache:
            // `--prune=all` also uninstalls every version of a formula but the one in use.
            if item.command?.hasPrefix("brew cleanup") == true {
                return DeletionRisk(level: .caution, title: "설치된 패키지의 이전 버전도 지워져요",
                                    reason: "brew cleanup은 내려받은 파일과 함께 설치된 패키지의 이전 버전을 지워요. 지금 쓰는 버전은 그대로예요.")
            }
            return DeletionRisk(level: .safe, title: "필요할 때 다시 내려받아요",
                                reason: "프로젝트에 설치된 패키지는 그대로예요. 다음 설치만 조금 느려질 수 있어요.")
        case .app:
            if managedBundlePrefixes.contains(where: bundleID.hasPrefix) {
                return DeletionRisk(level: .risky, title: "회사 관리·보안 앱이에요",
                                    reason: "지우면 업무 시스템 접속이나 보안 정책에 문제가 생길 수 있어요. 회사 기기라면 관리자에게 먼저 확인하세요.")
            }
            if let components, components.hasExtensions {
                return DeletionRisk(level: .risky, title: "앱만 지우면 시스템 구성요소가 남아요",
                                    reason: "앱이 설치한 구성요소(\(components.list))가 있어서 네트워크나 장치 동작이 꼬일 수 있어요. 앱 안의 제거 기능이나 개발사 제거 프로그램을 쓰세요.")
            }
            // Cleaner removes the bundle; the ~/Library folders named after its bundle ID go only if the user opts in on the sheet.
            let kept = item.leftovers.isEmpty
                ? String(localized: "설정과 데이터는 남아서 다시 설치하면 이어 쓸 수 있어요.", bundle: .shown, locale: .shown)
                : String(localized: "앱이 남긴 데이터 \(item.leftovers.count)곳은 기본으로 남겨요. 삭제할 때 함께 지울 수도 있어요.", bundle: .shown, locale: .shown)
            if let components {
                return DeletionRisk(level: .caution, title: "백그라운드 도우미가 남을 수 있어요",
                                    reason: "시스템 폴더의 구성요소(\(components.list))는 앱을 지워도 남을 수 있어요. \(kept)")
            }
            if fromAppStore {
                return DeletionRisk(level: .safe, title: "App Store에서 다시 받을 수 있어요", reason: "\(kept)")
            }
            return DeletionRisk(level: .caution, title: "다시 쓰려면 직접 설치해야 해요",
                                reason: "개발사 사이트에서 다시 받아야 하고, 유료 앱이면 라이선스 키가 필요할 수 있어요. \(kept)")
        case .archive:
            return DeletionRisk(level: .caution, title: "배포한 빌드의 심볼이 들어 있어요",
                                reason: "이 빌드의 크래시 로그를 읽는 데 필요한 dSYM이 들어 있어요. 따로 백업해 두지 않았다면 지운 뒤 되살릴 수 없어요.")
        case .log:
            return DeletionRisk(level: .safe, title: "30일 넘게 지난 로그예요",
                                reason: "최근 30일 안의 로그는 남겨 둬요.")
        case .aiData(let entry):
            return entry.risk(isOrphaned: item.isOrphaned)
        case .document, .largeFile:
            if inICloud {
                return DeletionRisk(level: .caution, title: "iCloud Drive에서도 지워져요",
                                    reason: "다른 기기에서도 사라져요. iCloud.com의 '최근 삭제된 항목'에서 30일 동안 되살릴 수 있어요.")
            }
            if installerExtensions.contains(item.url.pathExtension.lowercased()) {
                return DeletionRisk(level: .safe, title: "설치 파일이에요",
                                    reason: "이미 설치했다면 지워도 앱은 그대로 남아요.")
            }
            if let source = downloadSource.flatMap({ URL(string: $0)?.host() }) {
                return DeletionRisk(level: .safe, title: "다시 받을 수 있는 파일이에요",
                                    reason: "\(source)에서 받은 파일이에요. 링크가 살아 있는지 확인해 보세요.")
            }
            return DeletionRisk(level: .caution, title: "유일한 원본일 수 있어요",
                                reason: "출처가 기록되지 않은 파일이에요. 백업이 있는지 먼저 확인하세요.")
        }
    }
}

nonisolated struct DeletionRisk: Sendable {
    enum Level: Sendable { case safe, caution, risky }

    let level: Level
    let title: String
    let reason: String

    /// The only init, so literal titles and reasons are always looked up in the string catalog.
    init(level: Level, title: LocalizedStringResource, reason: LocalizedStringResource) {
        self.level = level
        self.title = String(localized: title.shown)
        self.reason = String(localized: reason.shown)
    }
}

extension ScanItem.Kind {
    /// Shown as "종류"; nil means the file's own type description is used.
    nonisolated var label: String? {
        switch self {
        case .browserCache: String(localized: "브라우저 캐시 폴더", bundle: .shown, locale: .shown)
        case .cache: String(localized: "앱 캐시 폴더", bundle: .shown, locale: .shown)
        case .appData: String(localized: "앱 데이터 폴더", bundle: .shown, locale: .shown)
        case .simulator: String(localized: "iOS 시뮬레이터", bundle: .shown, locale: .shown)
        case .runtime: String(localized: "시뮬레이터 런타임", bundle: .shown, locale: .shown)
        case .deviceSupport: String(localized: "기기 디버깅 심볼", bundle: .shown, locale: .shown)
        case .derivedData: String(localized: "Xcode 빌드 데이터", bundle: .shown, locale: .shown)
        case .previews: String(localized: "SwiftUI Preview 시뮬레이터", bundle: .shown, locale: .shown)
        case .packageCache: String(localized: "패키지 캐시", bundle: .shown, locale: .shown)
        case .archive: String(localized: "Xcode 아카이브", bundle: .shown, locale: .shown)
        case .log: String(localized: "로그", bundle: .shown, locale: .shown)
        case .aiData(let entry): entry.categoryName
        case .app, .document, .largeFile: nil
        }
    }
}
