import SwiftUI
import WidgetKit

@main
struct FiaxeLiveActivityExtensionBundle: WidgetBundle {
    var body: some Widget {
#if os(iOS)
        UploadLiveActivityWidget()
#else
        MacPlaceholderWidget()
#endif
    }
}

#if !os(iOS)
private struct MacPlaceholderWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "MacPlaceholderWidget", provider: Provider()) { _ in
            EmptyView()
        }
        .configurationDisplayName("Uploads")
        .description("Placeholder widget for unsupported platforms.")
        .supportedFamilies([.systemSmall])
    }
}

private struct Provider: TimelineProvider {
    func placeholder(in context: Context) -> Entry {
        Entry(date: .now)
    }

    func getSnapshot(in context: Context, completion: @escaping (Entry) -> Void) {
        completion(Entry(date: .now))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<Entry>) -> Void) {
        completion(Timeline(entries: [Entry(date: .now)], policy: .never))
    }
}

private struct Entry: TimelineEntry {
    let date: Date
}
#endif
