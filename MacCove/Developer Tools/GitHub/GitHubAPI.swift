//
//  GitHubAPI.swift
//  MacCove
//
//  Created by Justin Hoang on 11/3/26.
//

import Foundation

/// A pull request as the notch shows it: yours, with its checks, or one
/// someone asked you to review.
nonisolated struct GitHubPullRequest: Equatable, Identifiable, Sendable {
    nonisolated struct Check: Equatable, Identifiable, Sendable {
        nonisolated enum Status: Equatable, Sendable {
            case running
            case passed
            case failed
        }

        let id: String
        let name: String
        var status: Status
        let startedAt: Date?
        /// The check's page, which has its logs.
        let url: URL?
        /// The GitHub Actions run behind it, which Re-run Failed restarts.
        /// `nil` for other apps' checks and commit statuses.
        let workflowRunID: Int?
    }

    /// A review someone left: approved, changes requested or comments.
    nonisolated struct Review: Equatable, Identifiable, Sendable {
        nonisolated enum Verdict: Equatable, Sendable {
            case approved
            case changesRequested
            case commented
        }

        let id: String
        let verdict: Verdict
        let author: String
        let avatarURL: URL?
        /// What they wrote, on one line: the review's own text or, for a
        /// review that's only comments on the code, the first of those.
        let text: String
        /// The file the first comment is on, when `text` is one.
        let path: String?
        /// The review on the pull request's page.
        let url: URL?
        let submittedAt: Date?
    }

    /// GraphQL's node ID, which merging takes.
    let id: String
    let number: Int
    let title: String
    let url: URL
    /// "duclingg/MacCove".
    let repository: String
    let headSHA: String?
    let isDraft: Bool
    var checks: [Check]
    /// APPROVED, CHANGES_REQUESTED, REVIEW_REQUIRED, or `nil` where the
    /// repository asks for no reviews.
    let reviewDecision: String?
    let approvals: Int
    /// MERGEABLE, CONFLICTING or UNKNOWN.
    let mergeable: String?
    let additions: Int
    let deletions: Int
    let changedFiles: Int
    /// The viewer can write to the repository, so Merge can work.
    let canMerge: Bool
    /// What the repository's settings allow. The base branch's rulesets
    /// can narrow it further; see `GitHubBranchRules`.
    let mergeMethods: [GitHubMergeMethod]
    /// What GitHub's own button would do.
    let defaultMergeMethod: GitHubMergeMethod?
    /// The branch it merges into, whose rulesets apply.
    let baseBranch: String
    /// The last few reviews, oldest first; only for your own.
    var reviews: [Review] = []
    /// When anything about it last changed: a push, a comment, a review,
    /// a reviewer asked for.
    var updatedAt: Date?

    /// "MacCove", without the owner.
    var repositoryName: String {
        repository.split(separator: "/").last.map(String.init) ?? repository
    }
}

nonisolated enum GitHubMergeMethod: String, CaseIterable, Sendable {
    case merge = "MERGE"
    case squash = "SQUASH"
    case rebase = "REBASE"
}

/// What the rulesets on a branch say about merging into it.
nonisolated struct GitHubBranchRules: Equatable, Sendable {
    /// `nil` when no ruleset limits them.
    var allowedMergeMethods: Set<GitHubMergeMethod>?
    var requiresLinearHistory = false
    /// Pull requests go through the merge queue rather than straight in.
    var usesMergeQueue = false
}

/// What one poll found.
nonisolated struct GitHubSnapshot: Sendable {
    let login: String
    /// Your open pull requests, most recently updated first.
    let authored: [GitHubPullRequest]
    /// Open pull requests waiting on your review.
    let reviewRequested: [GitHubPullRequest]
}

/// GitHub's GraphQL API for the polling, and REST for re-running Actions.
/// One query a poll covers every pull request, its checks and its reviews,
/// for a few points of the 5,000 an hour GitHub allows.
nonisolated struct GitHubAPI: Sendable {
    nonisolated enum Failure: LocalizedError {
        /// The token was revoked, expired or never worked.
        case unauthorized
        case status(Int)
        case graphQL(String)

        var errorDescription: String? {
            switch self {
            case .unauthorized: "GitHub didn’t accept the token."
            case let .status(code): "GitHub answered with HTTP \(code)."
            case let .graphQL(message): message
            }
        }
    }

    let token: String

    private static let graphQLURL = URL(string: "https://api.github.com/graphql")!

    // MARK: - Reading

    func viewerLogin() async throws -> String {
        let response: ViewerResponse = try await graphQL("query { viewer { login } }", variables: [:])
        return response.viewer.login
    }

    func snapshot() async throws -> GitHubSnapshot {
        let response: SnapshotResponse = try await graphQL(Self.snapshotQuery, variables: [
            "reviewQuery": "is:open is:pr user-review-requested:@me archived:false",
        ])
        return GitHubSnapshot(
            login: response.viewer.login,
            authored: response.viewer.pullRequests.nodes.compactMap { $0?.pullRequest },
            reviewRequested: response.reviewRequests.nodes.compactMap { $0?.pullRequest }
        )
    }

    // MARK: - Acting

    /// The rulesets that apply to a branch, the organization's included.
    func branchRules(repository: String, branch: String) async throws -> GitHubBranchRules {
        let branchPath = branch.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? branch
        let url = URL(string: "https://api.github.com/repos/\(repository)/rules/branches/\(branchPath)?per_page=100")!
        let (data, response) = try await URLSession.shared.data(for: request(url))
        try Self.check(response)
        var rules = GitHubBranchRules()
        for rule in try Self.decoder.decode([BranchRule].self, from: data) {
            switch rule.type {
            case "pull_request":
                guard let names = rule.parameters?.allowed_merge_methods else { continue }
                let methods = Set(names.compactMap { GitHubMergeMethod(rawValue: $0.uppercased()) })
                rules.allowedMergeMethods = rules.allowedMergeMethods.map { $0.intersection(methods) } ?? methods
            case "required_linear_history":
                rules.requiresLinearHistory = true
            case "merge_queue":
                rules.usesMergeQueue = true
            default:
                break
            }
        }
        return rules
    }

    /// Merges only the commit whose checks were shown passing.
    func merge(_ pullRequest: GitHubPullRequest, method: GitHubMergeMethod) async throws {
        var variables: [String: Any] = ["id": pullRequest.id, "method": method.rawValue]
        if let sha = pullRequest.headSHA {
            variables["head"] = sha
        }
        let _: MergeResponse = try await graphQL("""
            mutation($id: ID!, $method: PullRequestMergeMethod!, $head: GitObjectID) {
              mergePullRequest(input: {pullRequestId: $id, mergeMethod: $method, expectedHeadOid: $head}) {
                pullRequest { merged }
              }
            }
            """, variables: variables)
    }

    /// Adds it to the base branch's merge queue, which merges it the way
    /// the queue is set up to.
    func enqueue(_ pullRequest: GitHubPullRequest) async throws {
        var variables: [String: Any] = ["id": pullRequest.id]
        if let sha = pullRequest.headSHA {
            variables["head"] = sha
        }
        let _: MergeResponse = try await graphQL("""
            mutation($id: ID!, $head: GitObjectID) {
              enqueuePullRequest(input: {pullRequestId: $id, expectedHeadOid: $head}) {
                mergeQueueEntry { id }
              }
            }
            """, variables: variables)
    }

    /// Asks whether a REST resource, such as "repos/owner/name/pulls/6",
    /// has changed since `etag`. Returns its new ETag if it has, `nil` if
    /// not. GitHub doesn't count an unchanged answer (a 304) against the
    /// rate limit, so this can run every few seconds.
    func changeTag(of path: String, since etag: String?) async throws -> String? {
        var request = request(URL(string: "https://api.github.com/" + path)!)
        if let etag {
            request.setValue(etag, forHTTPHeaderField: "If-None-Match")
        }
        let (_, response) = try await Self.uncachedSession.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode != 304 else { return nil }
        try Self.check(response)
        return http.value(forHTTPHeaderField: "ETag")
    }

    /// Without a local cache, which would answer a 304 with a stale 200.
    private static let uncachedSession: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: configuration)
    }()

    /// Restarts only the jobs that failed in an Actions run.
    func rerunFailedJobs(repository: String, runID: Int) async throws {
        let url = URL(string: "https://api.github.com/repos/\(repository)/actions/runs/\(runID)/rerun-failed-jobs")!
        var request = request(url)
        request.httpMethod = "POST"
        let (_, response) = try await URLSession.shared.data(for: request)
        try Self.check(response)
    }

    // MARK: - Plumbing

    private func request(_ url: URL) -> URLRequest {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        request.setValue("bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue("MacCove", forHTTPHeaderField: "User-Agent")
        return request
    }

    private func graphQL<Response: Decodable>(_ query: String, variables: [String: Any]) async throws -> Response {
        var request = request(Self.graphQLURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["query": query, "variables": variables])
        let (data, response) = try await URLSession.shared.data(for: request)
        try Self.check(response)
        let envelope = try Self.decoder.decode(Envelope<Response>.self, from: data)
        if let message = envelope.errors?.first?.message {
            throw Failure.graphQL(message)
        }
        guard let result = envelope.data else { throw Failure.graphQL("GitHub sent back nothing.") }
        return result
    }

    private static func check(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else { return }
        switch http.statusCode {
        case 200 ..< 300: return
        case 401: throw Failure.unauthorized
        default: throw Failure.status(http.statusCode)
        }
    }

    private static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    /// Your ten most recently updated open pull requests with up to 40
    /// checks each, and ten review requests, which need no checks.
    private static let snapshotQuery = """
        query($reviewQuery: String!) {
          viewer {
            login
            pullRequests(states: OPEN, first: 10, orderBy: {field: UPDATED_AT, direction: DESC}) {
              nodes { ...Authored }
            }
          }
          reviewRequests: search(query: $reviewQuery, type: ISSUE, first: 10) {
            nodes { ... on PullRequest { ...Basics } }
          }
        }

        fragment Basics on PullRequest {
          id number title url isDraft additions deletions changedFiles updatedAt
          baseRefName
          repository {
            nameWithOwner viewerPermission viewerDefaultMergeMethod
            mergeCommitAllowed squashMergeAllowed rebaseMergeAllowed
          }
        }

        fragment Authored on PullRequest {
          ...Basics
          reviewDecision mergeable
          latestOpinionatedReviews(first: 10) { nodes { state } }
          reviews(last: 5, states: [APPROVED, CHANGES_REQUESTED, COMMENTED]) {
            nodes {
              id state url submittedAt body
              author { login avatarUrl(size: 96) }
              comments(first: 1) { nodes { body path } }
            }
          }
          commits(last: 1) {
            nodes {
              commit {
                oid
                statusCheckRollup {
                  contexts(first: 40) {
                    nodes {
                      __typename
                      ... on CheckRun {
                        id name status conclusion startedAt detailsUrl
                        checkSuite { app { slug } workflowRun { databaseId } }
                      }
                      ... on StatusContext { id context state targetUrl createdAt }
                    }
                  }
                }
              }
            }
          }
        }
        """
}

// MARK: - Responses

nonisolated private struct Envelope<Payload: Decodable>: Decodable {
    nonisolated struct Message: Decodable {
        let message: String
    }

    let data: Payload?
    let errors: [Message]?
}

nonisolated private struct ViewerResponse: Decodable {
    nonisolated struct Viewer: Decodable {
        let login: String
    }

    let viewer: Viewer
}

nonisolated private struct MergeResponse: Decodable {}

/// One rule from the rules-for-a-branch endpoint.
nonisolated private struct BranchRule: Decodable {
    nonisolated struct Parameters: Decodable {
        // As the REST API spells it.
        let allowed_merge_methods: [String]?
    }

    let type: String
    let parameters: Parameters?
}

nonisolated private struct Nodes<Node: Decodable>: Decodable {
    let nodes: [Node?]
}

nonisolated private struct SnapshotResponse: Decodable {
    nonisolated struct Viewer: Decodable {
        let login: String
        let pullRequests: Nodes<PullRequestNode>
    }

    let viewer: Viewer
    let reviewRequests: Nodes<PullRequestNode>
}

nonisolated private struct PullRequestNode: Decodable {
    nonisolated struct Repository: Decodable {
        let nameWithOwner: String
        let viewerPermission: String?
        let viewerDefaultMergeMethod: String?
        let mergeCommitAllowed: Bool?
        let squashMergeAllowed: Bool?
        let rebaseMergeAllowed: Bool?
    }

    nonisolated struct Review: Decodable {
        let state: String
    }

    nonisolated struct FullReview: Decodable {
        nonisolated struct Author: Decodable {
            let login: String
            let avatarUrl: URL?
        }

        nonisolated struct Comment: Decodable {
            let body: String
            let path: String?
        }

        let id: String
        let state: String
        let url: URL?
        let submittedAt: Date?
        let body: String
        let author: Author?
        let comments: Nodes<Comment>?

        var review: GitHubPullRequest.Review? {
            let verdict: GitHubPullRequest.Review.Verdict
            switch state {
            case "APPROVED": verdict = .approved
            case "CHANGES_REQUESTED": verdict = .changesRequested
            case "COMMENTED": verdict = .commented
            default: return nil
            }
            let comment = comments?.nodes.first ?? nil
            let ownText = Self.oneLine(body)
            let text = ownText.isEmpty ? Self.oneLine(comment?.body ?? "") : ownText
            // A comment review with nothing in it says nothing.
            guard verdict != .commented || !text.isEmpty else { return nil }
            return GitHubPullRequest.Review(
                id: id,
                verdict: verdict,
                author: author?.login ?? "Someone",
                avatarURL: author?.avatarUrl,
                text: text,
                path: ownText.isEmpty ? comment?.path : nil,
                url: url,
                submittedAt: submittedAt
            )
        }

        /// Markdown's line breaks and indents as single spaces.
        private static func oneLine(_ text: String) -> String {
            text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        }
    }

    nonisolated struct Commit: Decodable {
        nonisolated struct Rollup: Decodable {
            let contexts: Nodes<Context>
        }

        let oid: String
        let statusCheckRollup: Rollup?
    }

    nonisolated struct CommitNode: Decodable {
        let commit: Commit
    }

    /// A check run from an app such as GitHub Actions, or an older commit
    /// status, told apart by `__typename`.
    nonisolated struct Context: Decodable {
        nonisolated struct CheckSuite: Decodable {
            nonisolated struct App: Decodable {
                let slug: String?
            }

            nonisolated struct WorkflowRun: Decodable {
                let databaseId: Int?
            }

            let app: App?
            let workflowRun: WorkflowRun?
        }

        let __typename: String
        let id: String?
        // CheckRun
        let name: String?
        let status: String?
        let conclusion: String?
        let startedAt: Date?
        let detailsUrl: URL?
        let checkSuite: CheckSuite?
        // StatusContext
        let context: String?
        let state: String?
        let targetUrl: URL?
        let createdAt: Date?

        var check: GitHubPullRequest.Check? {
            guard let id else { return nil }
            switch __typename {
            case "CheckRun":
                let result: GitHubPullRequest.Check.Status = switch (status, conclusion) {
                case ("COMPLETED"?, "SUCCESS"?), ("COMPLETED"?, "NEUTRAL"?), ("COMPLETED"?, "SKIPPED"?), ("COMPLETED"?, "STALE"?): .passed
                case ("COMPLETED"?, _): .failed
                default: .running
                }
                let isActions = checkSuite?.app?.slug == "github-actions"
                return GitHubPullRequest.Check(
                    id: id,
                    name: name ?? "Check",
                    status: result,
                    startedAt: startedAt,
                    url: detailsUrl,
                    workflowRunID: isActions ? checkSuite?.workflowRun?.databaseId : nil
                )
            case "StatusContext":
                let result: GitHubPullRequest.Check.Status = switch state {
                case "SUCCESS"?: .passed
                case "PENDING"?, "EXPECTED"?: .running
                default: .failed
                }
                return GitHubPullRequest.Check(
                    id: id,
                    name: context ?? "Status",
                    status: result,
                    startedAt: createdAt,
                    url: targetUrl,
                    workflowRunID: nil
                )
            default:
                return nil
            }
        }
    }

    // The search can turn up issues too, which have none of these.
    let id: String?
    let number: Int?
    let title: String?
    let url: URL?
    let isDraft: Bool?
    let additions: Int?
    let deletions: Int?
    let changedFiles: Int?
    let updatedAt: Date?
    let repository: Repository?
    let baseRefName: String?
    let reviewDecision: String?
    let mergeable: String?
    let latestOpinionatedReviews: Nodes<Review>?
    let reviews: Nodes<FullReview>?
    let commits: Nodes<CommitNode>?

    var pullRequest: GitHubPullRequest? {
        guard let id, let number, let title, let url, let repository else { return nil }
        let commit = commits?.nodes.last??.commit
        let checks = commit?.statusCheckRollup?.contexts.nodes.compactMap { $0?.check } ?? []
        let canMerge = ["ADMIN", "MAINTAIN", "WRITE"].contains(repository.viewerPermission ?? "")
        var mergeMethods: [GitHubMergeMethod] = []
        if repository.mergeCommitAllowed == true { mergeMethods.append(.merge) }
        if repository.squashMergeAllowed == true { mergeMethods.append(.squash) }
        if repository.rebaseMergeAllowed == true { mergeMethods.append(.rebase) }
        return GitHubPullRequest(
            id: id,
            number: number,
            title: title,
            url: url,
            repository: repository.nameWithOwner,
            headSHA: commit?.oid,
            isDraft: isDraft ?? false,
            checks: checks,
            reviewDecision: reviewDecision,
            approvals: latestOpinionatedReviews?.nodes.filter { $0?.state == "APPROVED" }.count ?? 0,
            mergeable: mergeable,
            additions: additions ?? 0,
            deletions: deletions ?? 0,
            changedFiles: changedFiles ?? 0,
            canMerge: canMerge,
            mergeMethods: mergeMethods,
            defaultMergeMethod: repository.viewerDefaultMergeMethod.flatMap(GitHubMergeMethod.init),
            baseBranch: baseRefName ?? "",
            reviews: reviews?.nodes.compactMap { $0?.review } ?? [],
            updatedAt: updatedAt
        )
    }
}
