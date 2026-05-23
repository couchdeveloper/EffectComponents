import SwiftUI
import EffectView
import Foundation

enum Movies {
    enum Views {}
    enum Transducer {}
}

// MARK: - Model

extension Movies {
    struct Movie: Equatable, Identifiable {
        let id: UUID
        let title: String
    }
}

// MARK: - Environment

extension Movies {
    
    struct MovieFetch: Sendable {
        var fetch: @Sendable () async throws -> [Movie]
        
        func callAsFunction() async throws -> [Movie] {
            try await fetch()
        }
    }
    
}

extension EnvironmentValues {
    @Entry var movieListViewEnv: Movies.Transducer.Env = .init(
        movieFetch: .init(fetch: {
            try await Task.sleep(nanoseconds: 2_000_000_000)
            return [
                Movies.Movie(id: UUID(), title: "The Shawshank Redemption"),
                Movies.Movie(id: UUID(), title: "Moby Dick"),
                Movies.Movie(id: UUID(), title: "Severance"),
                Movies.Movie(id: UUID(), title: "Einer flog über das Kuckucksnest"),
            ]
        })
    )
}


// MARK: - Transducer
extension Movies.Transducer: Transducer {
    
    typealias Movie = Movies.Movie

    struct State {
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
            case .loading: return true
            default: return false
            }
        }

        var isRefreshing: Bool {
            if case .refreshing = mode { return true }
            return false
        }
    }

    public enum Event {
        case load
        case refresh
        case loaded([Movie])
        case loadFailed(Error)
        case cancel
        case dismiss
    }
    
    struct Env: Sendable {
        public var movieFetch: Movies.MovieFetch
    }
    
    static func update(_ state: inout State, event: Event) -> Effect? {
        switch event {
        case .load:
            // Guard against refresh: can only race with programmatic load triggers
            // (e.g. .onAppear, timers). UI pull-to-refresh is serialised by SwiftUI.
            guard !state.isRefreshing else { return nil }
            guard !state.isLoading else { return nil }
            state.mode = .loading
            return loadMovies()

        case .refresh:
            // Always supersedes a pending load; named task cancels any prior refresh.
            state.mode = .refreshing
            return sequence([cancel("load"), refreshMovies()])

        case .loaded(let movies):
            state.mode = .idle
            state.content = .content(movies)
            return nil

        case .loadFailed(let error):
            state.mode = .failed(error)
            return nil

        case .cancel:
            state.mode = .idle
            return cancel("load")

        case .dismiss:
            state.mode = .idle
            return nil
        }
    }
    
    
    static func loadMovies() -> Effect {
        run(id: "load") { input, env in
            do {
                let movies = try await env.movieFetch()
                input(.loaded(movies))
            } catch {
                input(.loadFailed(error))
            }
        }
    }

    static func refreshMovies() -> Effect {
        // Note: a refresh action
        run(id: "refresh") { input, env in
            do {
                let movies = try await env.movieFetch()
                input(.loaded(movies))
            } catch {
                input(.loadFailed(error))
            }
        }
    }
}

// MARK: - Views
extension Movies.Views {
    
    struct ContentView: View {
        var body: some View {
            EnvReader(\.movieListViewEnv) { env in
                MovieListView(env: env)
            }
        }
    }
    
    struct MovieListView: View {
        typealias Transducer = Movies.Transducer
        typealias Env = Transducer.Env
        typealias ViewState = Transducer.State
        
        let env: Env
        
        @State private var state = ViewState()
        
        var body: some View {
            EffectView(
                of: Transducer.self,
                state: $state,
                initialEvent: .load,
                initialEnv: env
            ) { state, input in
                ZStack {
                    switch state.content {
                    case .empty:
                        if #available(iOS 17.0, *) {
                            ContentUnavailableView("No Movies", systemImage: "film")
                        } else {
                            VStack(spacing: 12) {
                                Image(systemName: "film")
                                    .font(.system(size: 48))
                                    .foregroundColor(.secondary)
                                Text("No Movies")
                                    .font(.headline)
                                    .foregroundColor(.secondary)
                            }
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                        }
                    case .content(let movies):
                        List(movies, rowContent: MovieRow.init)
                            .refreshable {
                                try? await input.request(.refresh)
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
                    Button("OK") { input(.dismiss) }
                } message: { error in
                    Text(error.localizedDescription)
                }
            }
        }
    }
    
}

extension Movies.Views.MovieListView {
    
    typealias Movie = Movies.Movie

    struct MovieRow: View {
        let movie: Movie

        var body: some View {
            Text(movie.title)
        }
    }
}

// MARK: - Previews

#Preview {
    EnvReader(\.movieListViewEnv) { env in
        Movies.Views.MovieListView(env: env)
    }
}
