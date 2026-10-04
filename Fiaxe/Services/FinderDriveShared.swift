import Foundation
#if os(macOS)
import FileProvider
#endif

/// Constants shared between the app and the R2VaultFileProvider extension.
/// This file is a member of both targets.
nonisolated enum FinderDrive {
    /// Bucket prefix holding items moved to the Finder Trash. The app hides it when browsing.
    static let trashPrefix = ".r2vault-trash/"

    /// Items in the drive's Trash are purged after this many days.
    static let trashRetentionDays = 30

    /// Key in a drive's domain `userInfo` naming the account/bucket it was created for.
    /// The extension refuses credentials for any other bucket.
    static let bucketIdentityKey = "bucketIdentity"

    /// Buckets with the same name in different jurisdictions are different buckets.
    /// Default-jurisdiction identities keep their original form so existing drives stay as they are.
    static func bucketIdentity(of credentials: R2Credentials) -> String {
        let identity = "\(credentials.accountId)/\(credentials.bucketName)"
        return credentials.jurisdiction == .auto ? identity : "\(identity)@\(credentials.jurisdiction.rawValue)"
    }

#if os(macOS)
    /// XPC service the extension vends on the root item so the app can hand it credentials.
    static let controlServiceName = NSFileProviderServiceName("fiaxe.r2vault.finder-drive.control")

    static func domainIdentifier(for credentialsID: UUID) -> NSFileProviderDomainIdentifier {
        NSFileProviderDomainIdentifier(rawValue: credentialsID.uuidString)
    }
#endif
}

#if os(macOS)
/// XPC interface exported by the extension. The app calls it through
/// `NSFileProviderManager.service(named:for:)` on the domain's root item.
@objc protocol FinderDriveControlProtocol {
    /// `payload` is a JSON-encoded `R2Credentials`.
    func updateCredentials(_ payload: Data, reply: @escaping (NSError?) -> Void)

    /// Re-lists the folders currently open in Finder and publishes any remote changes.
    func refresh(reply: @escaping (NSError?) -> Void)
}
#endif
