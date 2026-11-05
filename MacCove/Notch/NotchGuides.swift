//
//  NotchGuides.swift
//  MacCove
//
//  Created by Justin Hoang on 11/4/26.
//

import SwiftUI
import Observation

/// What MacCove has to tell you, shown in the notch instead of an alert:
/// the rest of a setup that takes more than one step, with each step
/// ticking off, or a notice such as an error or a new version. It opens by
/// itself and stays until it's finished or dismissed; any that come while
/// one is showing wait their turn.
struct NotchGuide: Identifiable {
    enum Icon {
        case tool(ToolIcon.Tool)
        /// MacCove's own.
        case app
        case symbol(String, color: Color)
    }

    enum Tone {
        case normal
        /// Something went wrong: the title's in red.
        case error
    }

    struct Step: Identifiable {
        let id: String
        let text: String
        var detail: String?
        var isDone = false
        /// MacCove is looking out for it, or doing it: a spinner until
        /// it's done.
        var isWatching = false
    }

    struct Action: Identifiable {
        var id: String { title }
        let title: String
        var isPrimary = false
        /// Most finish the guide; Copy and the like leave it up.
        var finishes = true
        let perform: () -> Void
    }

    /// One guide of each kind at a time: showing it again replaces it.
    let id: String
    var icon: Icon
    var title: String
    var subtitle: String?
    /// A few lines more, for an error's reason or a release's notes.
    var message: String?
    var steps: [Step] = []
    var actions: [Action] = []
    var tone: Tone = .normal

    var doneCount: Int {
        steps.filter(\.isDone).count
    }

    /// Something to say, with Dismiss.
    static func notice(id: String, icon: Icon, title: String, message: String?, tone: Tone = .normal) -> NotchGuide {
        NotchGuide(id: id, icon: icon, title: title, message: message, actions: [Action(title: "Dismiss") {}], tone: tone)
    }

    /// What went wrong setting something up, or taking it out.
    static func error(id: String, icon: Icon, title: String, _ error: Error) -> NotchGuide {
        notice(id: id, icon: icon, title: title, message: error.localizedDescription, tone: .error)
    }
}

@Observable
final class NotchGuides {
    enum Event {
        /// A guide is at the front: the notch opens to it.
        case shown
        /// None left.
        case ended
    }

    static let shared = NotchGuides()

    private(set) var queue: [NotchGuide] = []

    /// The one showing.
    var current: NotchGuide? {
        queue.first
    }

    @ObservationIgnored var onEvent: ((Event) -> Void)?

    func show(_ guide: NotchGuide) {
        if let index = queue.firstIndex(where: { $0.id == guide.id }) {
            queue[index] = guide
        } else {
            queue.append(guide)
        }
        if queue.first?.id == guide.id {
            onEvent?(.shown)
        }
    }

    func isShowing(_ id: String) -> Bool {
        queue.contains { $0.id == id }
    }

    func update(_ id: String, _ change: (inout NotchGuide) -> Void) {
        guard let index = queue.firstIndex(where: { $0.id == id }) else { return }
        change(&queue[index])
    }

    /// Ticks a step off.
    func complete(step: String, in id: String) {
        update(id) { guide in
            guard let index = guide.steps.firstIndex(where: { $0.id == step }) else { return }
            guide.steps[index].isDone = true
            guide.steps[index].isWatching = false
        }
    }

    /// Puts a spinner on a step while MacCove gets on with it.
    func watch(step: String, in id: String) {
        update(id) { guide in
            guard let index = guide.steps.firstIndex(where: { $0.id == step }) else { return }
            guide.steps[index].isWatching = true
        }
    }

    func finish(_ id: String) {
        let wasFront = queue.first?.id == id
        queue.removeAll { $0.id == id }
        guard wasFront else { return }
        onEvent?(queue.isEmpty ? .ended : .shown)
    }

    func perform(_ action: NotchGuide.Action, in guide: NotchGuide) {
        action.perform()
        if action.finishes {
            finish(guide.id)
        }
    }
}
