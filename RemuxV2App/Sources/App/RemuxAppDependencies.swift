@preconcurrency import Citadel
import Foundation

struct RemuxAppDependencies {
    let profileRepository: any ConnectionProfileRepository
    let passwordStore: any PasswordStore
    let trustedHostStore: TrustedHostStore

    static func live() throws -> RemuxAppDependencies {
        let root = try ApplicationStorage.remuxRoot()
        return RemuxAppDependencies(
            profileRepository: FileBackedConnectionProfileRepository(rootURL: root),
            passwordStore: KeychainPasswordStore(),
            trustedHostStore: TrustedHostStore(rootURL: root)
        )
    }

    func makeTransport(for target: TmuxConnectionTarget) -> any TmuxControlTransport {
        SSHTmuxControlTransport(
            configuration: SSHTmuxControlConfiguration(
                host: target.server.host,
                port: target.server.port,
                authenticationMethod: {
                    .passwordBased(
                        username: target.server.username,
                        password: target.password
                    )
                },
                hostKeyValidator: trustedHostStore.validator(for: target.server),
                sessionName: target.workspace.sessionName
            )
        )
    }

#if DEBUG
    @discardableResult
    func seedDebugConnectionIfRequested() async throws -> Bool {
        try await DebugConnectionProfileSeeder.seedIfRequested(
            profileRepository: profileRepository,
            passwordStore: passwordStore
        )
    }
#endif
}
