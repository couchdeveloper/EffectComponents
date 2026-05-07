import SwiftUI
import EffectView
import Foundation

// MARK: - Model

struct Movie: Equatable, Identifiable {
    let id: UUID
    let title: String
}

// MARK: - Actions

struct MovieFetch: Sendable {
    var fetch: @Sendable () async throws -> [Movie]

    func callAsFunction() async throws -> [Movie] {
        try await fetch()
    }
}

extension EnvironmentValues {
    @Entry var movieListViewEnv: MovieListView.Env = .init(
        movieFetch: .init(fetch: {
            try await Task.sleep(for: .milliseconds(2000))
            return [
                Movie(id: UUID(), title: "The Shawshank Redemption"),
                Movie(id: UUID(), title: "Moby Dick"),
                Movie(id: UUID(), title: "Severance"),
                Movie(id: UUID(), title: "Einer flog über's Kuckuksnest"),
            ]
        })
    )
}


// MARK: - Content

enum Empty {
    case blank
}

enum Content<Value> {
    case empty(Empty)
    case content(Value)
}

// MARK: - MovieList

@MainActor
struct MovieListView: View {
    let env: Env

    @State private var state = ViewState()

    var body: some View {
        EffectView(state: $state, initialEvent: .load, initialEnv: env, update: Self.update) { state, input in
            ZStack {
                switch state.content {
                case .empty:
                    ContentUnavailableView("No Movies", systemImage: "film")
                case .content(let movies):
                    List(movies, rowContent: MovieRow.init)
                        .refreshable {
                            await input.perform(.refresh)
                        }
                }

                if state.isLoading {
                    ProgressView()
                }
            }
            .alert(
                "Error",
                isPresented: .constant(state.error != nil),
                presenting: state.error
            ) { _ in
                Button("OK") { input.send(.dismiss) }
            } message: { error in
                Text(error.localizedDescription)
            }
        }
    }
}

extension MovieListView {

    struct ViewState {
        var mode: Mode
        var content: Content<[Movie]>

        enum Mode {
            case idle
            case loading
            case refreshing
            case failed(Error)
        }

        init() {
            mode = .idle
            content = .empty(.blank)
        }

        var error: Error? {
            if case .failed(let error) = mode { return error }
            return nil
        }   

        var isLoading: Bool {
            switch mode {
            case .loading, .refreshing: return true
            default: return false
            }
        }

        var isRefreshing: Bool {
            if case .refreshing = mode { return true }
            return false
        }
    }

    enum Event {
        case load
        case refresh
        case loaded([Movie])
        case loadFailed(Error)
        case cancel
        case dismiss
    }

    struct Env: Sendable {
        var movieFetch: MovieFetch
    }

    static func update(state: inout ViewState, event: Event) -> Effect<Event, Env>? {
        switch event {
        case .load:
            // Guard against refresh: can only race with programmatic load triggers
            // (e.g. .onAppear, timers). UI pull-to-refresh is serialised by SwiftUI.
            guard !state.isRefreshing else { return nil }
            guard !state.isLoading else { return nil }
            state.mode = .loading
            return .loadMovies()

        case .refresh:
            // Always supersedes a pending load; named task cancels any prior refresh.
            state.mode = .refreshing
            return .sequence([.cancel("load"), .refreshMovies()])

        case .loaded(let movies):
            state.mode = .idle
            state.content = .content(movies)
            return nil

        case .loadFailed(let error):
            state.mode = .failed(error)
            return nil

        case .cancel:
            state.mode = .idle
            return .cancel("load")

        case .dismiss:
            state.mode = .idle
            return nil
        }
    }

}

extension MovieListView {
    struct MovieRow: View {
        let movie: Movie

        var body: some View {
            Text(movie.title)
        }
    }
}

extension Effect where Event == MovieListView.Event, Env == MovieListView.Env {
    static func loadMovies() -> Self {
        .task(name: "load") { input, env in
            do {
                let movies = try await env.movieFetch()
                input(.loaded(movies))
            } catch {
                input(.loadFailed(error))
            }
        }
    }

    static func refreshMovies() -> Self {
        // Note: a refresh action
        .task(name: "refresh") { input, env in
            do {
                let movies = try await env.movieFetch()
                input(.loaded(movies))
            } catch {
                input(.loadFailed(error))
            }
        }
    }
}

// MARK: - Previews

#Preview {
    EnvReader(\.movieListViewEnv) { env in
        MovieListView(env: env)
    }
    
}
