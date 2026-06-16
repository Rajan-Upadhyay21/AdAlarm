# AdAlarm ⏰

An iOS alarm app inspired by the iPhone Clock app — with a twist: **multi-alarm "bubbles"** that group several alarms under a single switch.

## The Bubble feature

Setting many alarms one at a time is tedious. AdAlarm lets you create a **bubble** — a group of up to **5 full alarms** that all turn on or off together with one toggle.

- Up to **5 alarms per bubble**, each a complete alarm (time, repeat days, label, sound, snooze).
- Up to **3 bubbles** total.
- Tap a bubble to open it and edit each alarm individually.
- The "add" options disappear automatically once you hit the limits (5 alarms / 3 bubbles) and reappear when you remove one.
- Bubbles use the iOS 26 **Liquid Glass** look, with the on/off toggle on the side.

## Features

- Multi-alarm bubbles (the headline feature)
- Classic single alarms, like the stock Clock app
- Full alarm options: time, repeat days, label, sound, snooze + snooze duration
- Working snooze via notification actions
- Alarms and bubbles are **saved** and survive app restarts
- Functional **World Clock**, **Stopwatch**, and **Timer** tabs

## Running it

1. Open the project in **Xcode 26** or later.
2. Select an iPhone simulator (or your own device).
3. Press **Run** (⌘R).
4. Tap **Allow** when the notifications prompt appears.

## Requirements

- iOS 26.0 or later
- Xcode 26 or later
- Swift / SwiftUI

## Note on alarm ringing

Alarms currently fire as local notifications (banner + sound + snooze). True system-alarm behavior — ringing continuously and breaking through silent mode like the stock Clock app — requires Apple's **AlarmKit**, which needs an additional entitlement and a widget-extension target. That's a planned next step.

## Author

Rajan Upadhyay
