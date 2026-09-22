/// Home and chrome policy for Theater Minimize.
/// The board leaves the stage; Listen stays. Open Theater / Show Theater bring it back.
enum TheaterMinimize {
    enum HomeAction: Equatable {
        case open
        case show
        case close
    }

    static func homeAction(windowEnabled: Bool, minimized: Bool) -> HomeAction {
        if windowEnabled, minimized { return .show }
        if windowEnabled { return .close }
        return .open
    }

    static func shouldOrderFront(minimized: Bool) -> Bool {
        !minimized
    }

    static func homeTitle(for action: HomeAction) -> String {
        switch action {
        case .open: return TheaterReadiness.gettingStartedOpen
        case .show: return TheaterReadiness.showTheater
        case .close: return TheaterReadiness.closeTheater
        }
    }

    static func homeSystemImage(for action: HomeAction) -> String {
        switch action {
        case .open: return "captions.bubble"
        case .show: return "rectangle.expand.vertical"
        case .close: return "xmark"
        }
    }

    static func homeHelp(for action: HomeAction) -> String {
        switch action {
        case .open: return TheaterReadiness.openTheaterHelp
        case .show: return TheaterReadiness.showTheaterHelp
        case .close: return TheaterReadiness.closeTheaterHelp
        }
    }
}
