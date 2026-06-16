//
//  ContentView.swift
//  AdAlarm
//
//  An alarm app inspired by the iPhone Clock app, plus a "Bubble"
//  feature: group up to 5 full alarms (time, repeat days, label,
//  sound, snooze) into one Liquid Glass bubble with a single switch.
//  Max 3 bubbles. Add options hide at the limits.
//
//  This final version adds:
//   • Persistence — bubbles & alarms are saved and survive app restarts.
//   • Working snooze — alarm notifications have a Snooze action.
//   • Functional World Clock, Stopwatch and Timer tabs.
//
//  NOTE: True system-alarm ringing (breaking through silent mode,
//  ringing continuously) requires Apple's AlarmKit, which needs extra
//  Xcode project setup (an entitlement + a widget-extension target).
//  See the chat for how to add that as a next step.
//

import SwiftUI
import UserNotifications
import Combine

// MARK: - Models

struct AlarmTime: Identifiable, Codable, Equatable {
    var id = UUID()
    var hour: Int
    var minute: Int
    var label: String = "Alarm"
    var repeatDays: Set<Int> = []      // Calendar weekdays: 1 = Sun ... 7 = Sat
    var sound: String = "Reflection"
    var snoozeEnabled: Bool = true
    var snoozeDuration: Int = 9         // minutes

    var asDate: Date {
        Calendar.current.date(bySettingHour: hour, minute: minute, second: 0, of: Date()) ?? Date()
    }
    var displayTime: String { Self.fmt("h:mm a", asDate) }
    var hourMinute: String { Self.fmt("h:mm", asDate) }
    var period: String { Self.fmt("a", asDate) }

    private static func fmt(_ pattern: String, _ date: Date) -> String {
        let f = DateFormatter(); f.dateFormat = pattern; return f.string(from: date)
    }

    var repeatSummary: String {
        let names = [1: "Sun", 2: "Mon", 3: "Tue", 4: "Wed", 5: "Thu", 6: "Fri", 7: "Sat"]
        if repeatDays.isEmpty { return "Never" }
        if repeatDays.count == 7 { return "Every day" }
        if repeatDays == [2, 3, 4, 5, 6] { return "Weekdays" }
        if repeatDays == [1, 7] { return "Weekends" }
        return repeatDays.sorted().compactMap { names[$0] }.joined(separator: " ")
    }
}

struct AlarmBubble: Identifiable, Codable {
    var id = UUID()
    var name: String
    var times: [AlarmTime] = []
    var isOn: Bool = false
}

struct SingleAlarm: Identifiable, Codable {
    var id = UUID()
    var time: AlarmTime
    var isOn: Bool = true
}

/// Wrapper used to save everything in one blob.
private struct SavedData: Codable {
    var bubbles: [AlarmBubble]
    var alarms: [SingleAlarm]
}

let availableSounds = ["Reflection", "Radar", "Beacon", "Chimes", "Waves", "Bulletin", "Cosmic"]

// MARK: - Notification delegate (handles Snooze / foreground display)

final class NotificationDelegate: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationDelegate()

    // show the alert even when the app is open
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound, .list])
    }

    // respond when the user taps Snooze
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        if response.actionIdentifier == "SNOOZE" {
            let oldContent = response.notification.request.content
            let minutes = (oldContent.userInfo["snooze"] as? Int) ?? 9

            let content = UNMutableNotificationContent()
            content.title = oldContent.title
            content.body = "Snoozed — \(minutes) min"
            content.sound = .default
            content.categoryIdentifier = "ALARM_CATEGORY"
            content.userInfo = oldContent.userInfo

            let trigger = UNTimeIntervalNotificationTrigger(timeInterval: Double(minutes * 60), repeats: false)
            center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: trigger))
        }
        completionHandler()
    }
}

// MARK: - Store (data + persistence + scheduling)

@Observable
class AlarmStore {
    var bubbles: [AlarmBubble] = []
    var alarms: [SingleAlarm] = []

    let maxBubbles = 3
    let maxTimesPerBubble = 5
    private let saveKey = "AdAlarmData"

    init() { load() }

    func requestPermission() {
        let center = UNUserNotificationCenter.current()
        center.delegate = NotificationDelegate.shared

        // register the Snooze / Stop actions
        let snooze = UNNotificationAction(identifier: "SNOOZE", title: "Snooze", options: [])
        let stop = UNNotificationAction(identifier: "STOP", title: "Stop", options: [.destructive])
        let category = UNNotificationCategory(identifier: "ALARM_CATEGORY",
                                              actions: [snooze, stop],
                                              intentIdentifiers: [])
        center.setNotificationCategories([category])

        center.requestAuthorization(options: [.alert, .sound, .badge]) { granted, error in
            if let error { print("Permission error:", error) }
            print("Notifications granted:", granted)
        }
    }

    var canAddBubble: Bool { bubbles.count < maxBubbles }

    // MARK: Persistence

    private func save() {
        let data = SavedData(bubbles: bubbles, alarms: alarms)
        if let encoded = try? JSONEncoder().encode(data) {
            UserDefaults.standard.set(encoded, forKey: saveKey)
        }
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: saveKey),
              let decoded = try? JSONDecoder().decode(SavedData.self, from: data) else { return }
        bubbles = decoded.bubbles
        alarms = decoded.alarms
    }

    // MARK: Bubble actions

    func addBubble(_ bubble: AlarmBubble) {
        guard canAddBubble else { return }
        bubbles.append(bubble)
        save()
    }

    func deleteBubble(_ bubble: AlarmBubble) {
        cancelNotifications(for: bubble)
        bubbles.removeAll { $0.id == bubble.id }
        save()
    }

    func toggleBubble(_ bubble: AlarmBubble) {
        guard let i = bubbles.firstIndex(where: { $0.id == bubble.id }) else { return }
        bubbles[i].isOn.toggle()
        if bubbles[i].isOn { scheduleNotifications(for: bubbles[i]) }
        else { cancelNotifications(for: bubbles[i]) }
        save()
    }

    func updateBubble(_ bubble: AlarmBubble) {
        guard let i = bubbles.firstIndex(where: { $0.id == bubble.id }) else { return }
        cancelNotifications(for: bubbles[i])
        bubbles[i] = bubble
        if bubbles[i].isOn { scheduleNotifications(for: bubbles[i]) }
        save()
    }

    // MARK: Single alarm actions

    func addAlarm(_ alarm: SingleAlarm) {
        alarms.append(alarm)
        if alarm.isOn { scheduleNotification(for: alarm.time, title: alarm.time.label) }
        save()
    }

    func updateAlarm(_ alarm: SingleAlarm) {
        guard let i = alarms.firstIndex(where: { $0.id == alarm.id }) else { return }
        cancelNotification(for: alarms[i].time)
        alarms[i] = alarm
        if alarms[i].isOn { scheduleNotification(for: alarms[i].time, title: alarms[i].time.label) }
        save()
    }

    func deleteAlarm(_ alarm: SingleAlarm) {
        cancelNotification(for: alarm.time)
        alarms.removeAll { $0.id == alarm.id }
        save()
    }

    func toggleAlarm(_ alarm: SingleAlarm) {
        guard let i = alarms.firstIndex(where: { $0.id == alarm.id }) else { return }
        alarms[i].isOn.toggle()
        if alarms[i].isOn { scheduleNotification(for: alarms[i].time, title: alarms[i].time.label) }
        else { cancelNotification(for: alarms[i].time) }
        save()
    }

    // MARK: Notification scheduling

    private func notificationIDs(for time: AlarmTime) -> [String] {
        if time.repeatDays.isEmpty { return [time.id.uuidString] }
        return time.repeatDays.map { "\(time.id.uuidString)-\($0)" }
    }

    private func scheduleNotifications(for bubble: AlarmBubble) {
        for time in bubble.times {
            scheduleNotification(for: time, title: bubble.name.isEmpty ? "Alarm" : bubble.name)
        }
    }

    private func makeContent(_ time: AlarmTime, _ title: String) -> UNMutableNotificationContent {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = time.label.isEmpty ? "It's \(time.displayTime)" : time.label
        content.sound = .default
        if time.snoozeEnabled {
            content.categoryIdentifier = "ALARM_CATEGORY"
            content.userInfo = ["snooze": time.snoozeDuration]
        }
        return content
    }

    private func scheduleNotification(for time: AlarmTime, title: String) {
        let center = UNUserNotificationCenter.current()
        if time.repeatDays.isEmpty {
            var comps = DateComponents(); comps.hour = time.hour; comps.minute = time.minute
            let trigger = UNCalendarNotificationTrigger(dateMatching: comps, repeats: true)
            center.add(UNNotificationRequest(identifier: time.id.uuidString,
                                             content: makeContent(time, title), trigger: trigger))
        } else {
            for day in time.repeatDays {
                var comps = DateComponents(); comps.weekday = day; comps.hour = time.hour; comps.minute = time.minute
                let trigger = UNCalendarNotificationTrigger(dateMatching: comps, repeats: true)
                center.add(UNNotificationRequest(identifier: "\(time.id.uuidString)-\(day)",
                                                 content: makeContent(time, title), trigger: trigger))
            }
        }
    }

    private func cancelNotifications(for bubble: AlarmBubble) {
        let ids = bubble.times.flatMap { notificationIDs(for: $0) }
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: ids)
    }

    private func cancelNotification(for time: AlarmTime) {
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: notificationIDs(for: time))
    }
}

// MARK: - Root View (Clock-style tab bar)

struct ContentView: View {
    @State private var store = AlarmStore()

    var body: some View {
        TabView {
            WorldClockView()
                .tabItem { Label("World Clock", systemImage: "globe") }

            AlarmView(store: store)
                .tabItem { Label("Alarms", systemImage: "alarm.fill") }

            StopwatchView()
                .tabItem { Label("Stopwatch", systemImage: "stopwatch") }

            CountdownView()
                .tabItem { Label("Timers", systemImage: "timer") }
        }
        .onAppear { store.requestPermission() }
    }
}

// MARK: - Alarm Tab

struct AlarmView: View {
    var store: AlarmStore
    @State private var showingAddBubble = false
    @State private var showingAddAlarm = false
    @State private var editingBubble: AlarmBubble? = nil
    @State private var editingAlarm: SingleAlarm? = nil

    var body: some View {
        NavigationStack {
            List {
                // ---- Liquid Glass multi-alarm bubbles ----
                Section {
                    if store.bubbles.isEmpty {
                        Text("Tap the ◎ button to create a bubble — group up to 5 full alarms under one switch.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    ForEach(store.bubbles) { bubble in
                        BubbleCard(bubble: bubble, store: store, onEdit: { editingBubble = bubble })
                            .listRowSeparator(.hidden)
                            .listRowBackground(Color.clear)
                            .listRowInsets(EdgeInsets(top: 6, leading: 12, bottom: 6, trailing: 12))
                            .swipeActions {
                                Button(role: .destructive) { store.deleteBubble(bubble) } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                                Button { editingBubble = bubble } label: { Label("Edit", systemImage: "pencil") }.tint(.blue)
                            }
                    }
                } footer: {
                    if !store.canAddBubble {
                        Text("You've reached 3 bubbles. Delete one to add another.")
                    }
                }

                // ---- Classic single alarms ----
                Section("Alarms") {
                    if store.alarms.isEmpty {
                        Text("No alarms yet.").font(.footnote).foregroundStyle(.secondary)
                    }
                    ForEach(store.alarms) { alarm in
                        Button { editingAlarm = alarm } label: {
                            HStack {
                                VStack(alignment: .leading) {
                                    Text(alarm.time.displayTime)
                                        .font(.system(size: 34, weight: .light)).foregroundStyle(.primary)
                                    Text("\(alarm.time.label), \(alarm.time.repeatSummary)")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Toggle("", isOn: Binding(get: { alarm.isOn }, set: { _ in store.toggleAlarm(alarm) }))
                                    .labelsHidden()
                            }
                        }
                        .swipeActions {
                            Button(role: .destructive) { store.deleteAlarm(alarm) } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                    }
                }
            }
            .navigationTitle("Alarms")
            .toolbar {
                // bubble button — only while under the 3-bubble limit
                ToolbarItem(placement: .topBarTrailing) {
                    if store.canAddBubble {
                        Button { showingAddBubble = true } label: {
                            Image(systemName: "circle.circle").font(.title3)
                        }
                        .accessibilityLabel("Add bubble")
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showingAddAlarm = true } label: { Image(systemName: "plus") }
                        .accessibilityLabel("Add alarm")
                }
            }
            .sheet(isPresented: $showingAddBubble) { BubbleEditorView(store: store) }
            .sheet(item: $editingBubble) { bubble in BubbleEditorView(store: store, existing: bubble) }
            .sheet(isPresented: $showingAddAlarm) {
                AlarmDetailView(title: "Add Alarm") { newTime in store.addAlarm(SingleAlarm(time: newTime)) }
            }
            .sheet(item: $editingAlarm) { alarm in
                AlarmDetailView(alarm: alarm.time, title: "Edit Alarm") { edited in
                    var a = alarm; a.time = edited; store.updateAlarm(a)
                }
            }
        }
    }
}

// MARK: - Liquid Glass Bubble Card

struct BubbleCard: View {
    let bubble: AlarmBubble
    var store: AlarmStore
    var onEdit: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 7) {
                    Image(systemName: "circle.circle.fill").foregroundStyle(.tint)
                    Text(bubble.name).font(.headline)
                    Spacer()
                    Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary)
                }

                // all alarm chips on one line, equal width so up to 5 fit
                HStack(spacing: 6) {
                    ForEach(bubble.times) { t in
                        VStack(spacing: 0) {
                            Text(t.hourMinute).font(.system(size: 13, weight: .semibold))
                            Text(t.period).font(.system(size: 9)).foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                        .glassEffect(.regular, in: .rect(cornerRadius: 10))
                    }
                }
            }
            .contentShape(Rectangle())
            .onTapGesture { onEdit() }

            Toggle("", isOn: Binding(get: { bubble.isOn }, set: { _ in store.toggleBubble(bubble) }))
                .labelsHidden()
        }
        .padding(16)
        .glassEffect(.regular.tint(bubble.isOn ? .orange.opacity(0.25) : .clear).interactive(),
                     in: .rect(cornerRadius: 14))
    }
}

// MARK: - Bubble Editor (New / Edit)

struct BubbleEditorView: View {
    var store: AlarmStore
    var existing: AlarmBubble?
    @Environment(\.dismiss) private var dismiss

    @State private var name: String
    @State private var times: [AlarmTime]
    @State private var addingAlarm = false
    @State private var editingTime: AlarmTime? = nil

    init(store: AlarmStore, existing: AlarmBubble? = nil) {
        self.store = store
        self.existing = existing
        _name = State(initialValue: existing?.name ?? "")
        _times = State(initialValue: existing?.times ?? [])
    }

    private var isEditing: Bool { existing != nil }
    private var canAddMore: Bool { times.count < store.maxTimesPerBubble }

    var body: some View {
        NavigationStack {
            Form {
                Section("Bubble Name") {
                    TextField("e.g. Morning Routine", text: $name)
                }

                Section {
                    ForEach(times) { t in
                        Button { editingTime = t } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(t.displayTime).font(.title3).foregroundStyle(.primary)
                                    Text("\(t.label), \(t.repeatSummary)").font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                            }
                            .frame(height: 56)
                            .contentShape(Rectangle())
                        }
                    }
                    .onDelete { times.remove(atOffsets: $0) }

                    // "Add alarm" only appears while under the 5-alarm limit
                    if canAddMore {
                        Button { addingAlarm = true } label: {
                            Label("Add alarm", systemImage: "plus.circle.fill")
                        }
                    }
                } header: {
                    Text("Alarms in this bubble (\(times.count)/\(store.maxTimesPerBubble))")
                } footer: {
                    if !canAddMore { Text("Maximum of 5 alarms reached. Remove one to add another.") }
                }
            }
            .navigationTitle(isEditing ? "Edit Bubble" : "New Bubble")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }.disabled(name.isEmpty || times.isEmpty)
                }
            }
            .sheet(isPresented: $addingAlarm) {
                AlarmDetailView(title: "Add Alarm") { newTime in if canAddMore { times.append(newTime) } }
            }
            .sheet(item: $editingTime) { t in
                AlarmDetailView(alarm: t, title: "Edit Alarm") { edited in
                    if let i = times.firstIndex(where: { $0.id == edited.id }) { times[i] = edited }
                }
            }
        }
    }

    private func save() {
        if var updated = existing {
            updated.name = name; updated.times = times
            store.updateBubble(updated)
        } else {
            store.addBubble(AlarmBubble(name: name, times: times))
        }
        dismiss()
    }
}

// MARK: - Full Alarm Detail (mirrors the real "Add Alarm" screen)

struct AlarmDetailView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var alarm: AlarmTime
    private var onSave: (AlarmTime) -> Void
    private var title: String

    init(alarm: AlarmTime = AlarmTime(hour: 7, minute: 0), title: String = "Add Alarm",
         onSave: @escaping (AlarmTime) -> Void) {
        _alarm = State(initialValue: alarm)
        self.title = title
        self.onSave = onSave
    }

    private var timeBinding: Binding<Date> {
        Binding(
            get: { Calendar.current.date(bySettingHour: alarm.hour, minute: alarm.minute, second: 0, of: Date()) ?? Date() },
            set: { d in
                let c = Calendar.current.dateComponents([.hour, .minute], from: d)
                alarm.hour = c.hour ?? 0; alarm.minute = c.minute ?? 0
            }
        )
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    DatePicker("", selection: timeBinding, displayedComponents: .hourAndMinute)
                        .datePickerStyle(.wheel).labelsHidden().frame(maxWidth: .infinity)
                }
                Section {
                    WeekdayPicker(selected: $alarm.repeatDays)
                } header: {
                    HStack { Text("Repeat"); Spacer(); Text(alarm.repeatSummary).foregroundStyle(.secondary) }
                }
                Section {
                    HStack {
                        Text("Label"); Spacer()
                        TextField("Alarm", text: $alarm.label)
                            .multilineTextAlignment(.trailing).foregroundStyle(.secondary)
                    }
                    Picker("Sound", selection: $alarm.sound) {
                        ForEach(availableSounds, id: \.self) { Text($0) }
                    }
                    Toggle("Snooze", isOn: $alarm.snoozeEnabled)
                    if alarm.snoozeEnabled {
                        Picker("Snooze Duration", selection: $alarm.snoozeDuration) {
                            ForEach([5, 9, 10, 15, 20], id: \.self) { Text("\($0) min") }
                        }
                    }
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button { dismiss() } label: { Image(systemName: "xmark") }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button { onSave(alarm); dismiss() } label: { Image(systemName: "checkmark") }
                }
            }
        }
    }
}

// MARK: - Weekday Picker (S M T W T F S circles)

struct WeekdayPicker: View {
    @Binding var selected: Set<Int>
    private let days = [1, 2, 3, 4, 5, 6, 7]
    private let labels = ["S", "M", "T", "W", "T", "F", "S"]

    var body: some View {
        HStack(spacing: 8) {
            ForEach(Array(days.enumerated()), id: \.offset) { index, day in
                let isOn = selected.contains(day)
                Button {
                    if isOn { selected.remove(day) } else { selected.insert(day) }
                } label: {
                    Text(labels[index])
                        .font(.subheadline.bold())
                        .frame(width: 34, height: 34)
                        .background(isOn ? Color.accentColor : Color.gray.opacity(0.25))
                        .foregroundStyle(isOn ? .white : .primary)
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
            }
        }
        .frame(maxWidth: .infinity).padding(.vertical, 4)
    }
}

// MARK: - World Clock Tab

struct WorldClockView: View {
    private let cities: [(name: String, tz: String)] = [
        ("Cupertino", "America/Los_Angeles"),
        ("New York", "America/New_York"),
        ("London", "Europe/London"),
        ("Dubai", "Asia/Dubai"),
        ("Mumbai", "Asia/Kolkata"),
        ("Tokyo", "Asia/Tokyo"),
        ("Sydney", "Australia/Sydney")
    ]

    var body: some View {
        NavigationStack {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                List(cities, id: \.name) { city in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(offsetLabel(city.tz, now: context.date))
                                .font(.caption).foregroundStyle(.secondary)
                            Text(city.name).font(.title3)
                        }
                        Spacer()
                        Text(timeString(city.tz, now: context.date))
                            .font(.system(size: 40, weight: .thin))
                            .monospacedDigit()
                    }
                    .padding(.vertical, 4)
                }
            }
            .navigationTitle("World Clock")
        }
    }

    private func timeString(_ tz: String, now: Date) -> String {
        let f = DateFormatter(); f.dateFormat = "h:mm"; f.timeZone = TimeZone(identifier: tz)
        return f.string(from: now)
    }
    private func offsetLabel(_ tz: String, now: Date) -> String {
        guard let zone = TimeZone(identifier: tz) else { return "" }
        let hours = zone.secondsFromGMT(for: now) / 3600
        let local = TimeZone.current.secondsFromGMT(for: now) / 3600
        let diff = hours - local
        if diff == 0 { return "Today" }
        return diff > 0 ? "Today, +\(diff)HRS" : "Today, \(diff)HRS"
    }
}

// MARK: - Stopwatch Tab

struct StopwatchView: View {
    @State private var running = false
    @State private var startDate = Date()
    @State private var accumulated: TimeInterval = 0
    @State private var laps: [TimeInterval] = []
    @State private var now = Date()
    private let tick = Timer.publish(every: 0.03, on: .main, in: .common).autoconnect()

    private var elapsed: TimeInterval {
        accumulated + (running ? now.timeIntervalSince(startDate) : 0)
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 30) {
                Text(format(elapsed))
                    .font(.system(size: 64, weight: .thin)).monospacedDigit()
                    .padding(.top, 40)

                HStack {
                    Button(running ? "Lap" : "Reset") {
                        if running { laps.insert(elapsed, at: 0) }
                        else { accumulated = 0; laps = [] }
                    }
                    .frame(width: 84, height: 84)
                    .background(Color.gray.opacity(0.25)).clipShape(Circle())
                    .foregroundStyle(.primary)

                    Spacer()

                    Button(running ? "Stop" : "Start") {
                        if running { accumulated = elapsed; running = false }
                        else { startDate = Date(); running = true }
                    }
                    .frame(width: 84, height: 84)
                    .background((running ? Color.red : Color.green).opacity(0.3)).clipShape(Circle())
                    .foregroundStyle(running ? .red : .green)
                }
                .padding(.horizontal, 40)

                List {
                    ForEach(Array(laps.enumerated()), id: \.offset) { i, lap in
                        HStack {
                            Text("Lap \(laps.count - i)").foregroundStyle(.secondary)
                            Spacer()
                            Text(format(lap)).monospacedDigit()
                        }
                    }
                }
                .listStyle(.plain)
            }
            .onReceive(tick) { t in if running { now = t } }
            .navigationTitle("Stopwatch")
        }
    }

    private func format(_ t: TimeInterval) -> String {
        let cs = Int((t * 100).truncatingRemainder(dividingBy: 100))
        let s = Int(t) % 60
        let m = Int(t) / 60
        return String(format: "%02d:%02d.%02d", m, s, cs)
    }
}

// MARK: - Timer (Countdown) Tab

struct CountdownView: View {
    @State private var hours = 0
    @State private var minutes = 5
    @State private var seconds = 0
    @State private var remaining: Int = 0
    @State private var running = false
    @State private var now = Date()
    private let tick = Timer.publish(every: 0.2, on: .main, in: .common).autoconnect()

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                if running {
                    Text(clock(remaining))
                        .font(.system(size: 70, weight: .thin)).monospacedDigit()
                        .padding(.top, 50)
                } else {
                    HStack(spacing: 0) {
                        wheel($hours, range: 0...23, unit: "hours")
                        wheel($minutes, range: 0...59, unit: "min")
                        wheel($seconds, range: 0...59, unit: "sec")
                    }
                    .frame(height: 160)
                }

                Button(running ? "Cancel" : "Start") {
                    if running { cancelTimer() } else { startTimer() }
                }
                .font(.title3)
                .frame(width: 120, height: 50)
                .background((running ? Color.red : Color.green).opacity(0.3))
                .foregroundStyle(running ? .red : .green)
                .clipShape(Capsule())
                .disabled(!running && total == 0)

                Spacer()
            }
            .onReceive(tick) { _ in if running { updateRemaining() } }
            .navigationTitle("Timers")
        }
    }

    private var total: Int { hours * 3600 + minutes * 60 + seconds }
    @State private var endDate = Date()

    private func startTimer() {
        guard total > 0 else { return }
        endDate = Date().addingTimeInterval(Double(total))
        remaining = total
        running = true
        scheduleDoneNotification(after: total)
    }

    private func cancelTimer() {
        running = false
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: ["countdown-timer"])
    }

    private func updateRemaining() {
        let left = Int(endDate.timeIntervalSinceNow.rounded())
        if left <= 0 { remaining = 0; running = false }
        else { remaining = left }
    }

    private func scheduleDoneNotification(after seconds: Int) {
        let content = UNMutableNotificationContent()
        content.title = "Timer"
        content.body = "Time's up!"
        content.sound = .default
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: Double(seconds), repeats: false)
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: "countdown-timer", content: content, trigger: trigger))
    }

    private func clock(_ secs: Int) -> String {
        String(format: "%02d:%02d:%02d", secs / 3600, (secs % 3600) / 60, secs % 60)
    }

    private func wheel(_ value: Binding<Int>, range: ClosedRange<Int>, unit: String) -> some View {
        HStack(spacing: 2) {
            Picker("", selection: value) {
                ForEach(range, id: \.self) { Text("\($0)").tag($0) }
            }
            .pickerStyle(.wheel).frame(width: 60)
            Text(unit).font(.caption).foregroundStyle(.secondary)
        }
    }
}

#Preview {
    ContentView()
}
