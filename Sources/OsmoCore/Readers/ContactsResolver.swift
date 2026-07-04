import Foundation
#if canImport(Contacts)
import Contacts
#endif

/// A name + photo resolved from the macOS address book.
public struct ResolvedContact: Sendable, Equatable {
    public var name: String
    public var imageData: Data?
    public init(name: String, imageData: Data?) { self.name = name; self.imageData = imageData }
}

/// Builds a handle → (name, photo) index from the user's macOS Contacts so
/// iMessage/SMS threads show real names + avatars instead of raw phone numbers.
/// Keyed by `HandleNormalizer` value (phone last-10 / lowercased email), which is
/// exactly how message handles are keyed — so the two line up. Requires the
/// Contacts permission; returns empty if denied (import still works, just without
/// names). Needs `NSContactsUsageDescription` in Info.plist.
public enum ContactsResolver {
    public static func buildIndex() -> [String: ResolvedContact] {
        #if canImport(Contacts)
        let store = CNContactStore()
        if CNContactStore.authorizationStatus(for: .contacts) == .notDetermined {
            let sem = DispatchSemaphore(value: 0)
            store.requestAccess(for: .contacts) { _, _ in sem.signal() }
            sem.wait()
        }
        // .authorized (and macOS 14's .limited) can read; anything else → no names.
        let status = CNContactStore.authorizationStatus(for: .contacts)
        guard status == .authorized || "\(status)" == "limited" else { return [:] }

        var index: [String: ResolvedContact] = [:]
        let keys: [CNKeyDescriptor] = [
            CNContactGivenNameKey, CNContactFamilyNameKey, CNContactOrganizationNameKey,
            CNContactNicknameKey, CNContactPhoneNumbersKey, CNContactEmailAddressesKey,
            CNContactThumbnailImageDataKey,
        ].map { $0 as CNKeyDescriptor }
        let request = CNContactFetchRequest(keysToFetch: keys)

        try? store.enumerateContacts(with: request) { contact, _ in
            let nameParts = [contact.givenName, contact.familyName].filter { !$0.isEmpty }
            let name = !nameParts.isEmpty ? nameParts.joined(separator: " ")
                : (!contact.nickname.isEmpty ? contact.nickname : contact.organizationName)
            guard !name.isEmpty else { return }
            let resolved = ResolvedContact(name: name, imageData: contact.thumbnailImageData)

            for phone in contact.phoneNumbers {
                index[HandleNormalizer.normalize(phone.value.stringValue).value] = resolved
            }
            for email in contact.emailAddresses {
                index[HandleNormalizer.normalize(email.value as String).value] = resolved
            }
        }
        return index
        #else
        return [:]
        #endif
    }
}
