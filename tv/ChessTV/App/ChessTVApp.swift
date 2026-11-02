import SwiftUI

@main struct ChessTVApp: App {
  var body: some Scene { WindowGroup { AppRoot() } }
}

private struct AppRoot: View {
  @Environment(\.scenePhase) private var scenePhase
  @State private var session: TVSession?
  @State private var configurationError: String?
  var body: some View {
    Group {
      if let session {
        QuietBoardHost(session: session)
      } else {
        VStack(spacing: 24) {
          Text("Chess TV").font(.largeTitle)
          Text(configurationError ?? "Starting…").multilineTextAlignment(.center)
        }.padding(80)
      }
    }
    .task {
      guard session == nil else { return }
      do {
        let model = TVSession(configuration: try .bundled())
        session = model
        model.setActive(scenePhase == .active)
      } catch { configurationError = error.localizedDescription }
    }
    .onChange(of: scenePhase) { _, phase in session?.setActive(phase == .active) }
  }
}

private struct QuietBoardHost: UIViewControllerRepresentable {
  let session: TVSession

  func makeUIViewController(context: Context) -> BoardFocusHostingController<ContentView> {
    BoardFocusHostingController(rootView: ContentView(session: session))
  }

  func updateUIViewController(_ controller: BoardFocusHostingController<ContentView>, context: Context) {
    controller.rootView = ContentView(session: session)
  }
}

final class BoardFocusHostingController<Content: View>: UIHostingController<Content> {
  func isBoardSquare(_ item: (any UIFocusItem)?) -> Bool {
    guard let item else { return false }
    var environment: (any UIFocusEnvironment)? = item
    while let current = environment {
      if let container = current.focusItemContainer {
        let frame = container.coordinateSpace.convert(item.frame, to: view)
        return boardRegions(in: view).contains { region in
          region.convert(region.bounds, to: view).contains(CGPoint(x: frame.midX, y: frame.midY))
        }
      }
      environment = current.parentFocusEnvironment
    }
    return false
  }

  private func boardRegions(in view: UIView) -> [BoardFocusRegionView] {
    if let region = view as? BoardFocusRegionView { return [region] }
    return view.subviews.flatMap { boardRegions(in: $0) }
  }

  override func soundIdentifierForFocusUpdate(in context: UIFocusUpdateContext) -> UIFocusSoundIdentifier? {
    if isBoardSquare(context.nextFocusedItem) { return UIFocusSoundIdentifier.none }
    // This optional UIFocusEnvironment callback has no superclass implementation.
    // Defer to the parent for controls outside the board.
    return nil
  }
}


// A public UIKit coordinate-space marker scopes sound suppression to the grid.
// SwiftUI focus items are not necessarily UIViews.
struct BoardFocusRegion: UIViewRepresentable {
  func makeUIView(context: Context) -> BoardFocusRegionView {
    let view = BoardFocusRegionView()
    view.isUserInteractionEnabled = false
    return view
  }
  func updateUIView(_ view: BoardFocusRegionView, context: Context) {}
}

final class BoardFocusRegionView: UIView {}
