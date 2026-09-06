import Foundation
import Security

public enum RequirementError: Error, CustomStringConvertible {
    /// A Security call failed; the code is unsigned, or not on disk.
    case security(call: String, status: OSStatus)
    /// The designated requirement did not open with an identifier clause.
    case unexpectedShape(String)

    public var description: String {
        switch self {
        case .security(let call, let status):
            let text = SecCopyErrorMessageString(status, nil) as String? ?? "OSStatus \(status)"
            return "code signing: \(call) failed: \(text)"
        case .unexpectedShape(let requirement):
            return "code signing: designated requirement has no identifier clause: \(requirement)"
        }
    }
}

/// The code-signing requirement both ends of the wire enforce, derived
/// from the CURRENT process's own signature: `SecCodeCopySelf` ->
/// `SecCodeCopyStaticCode` -> `SecCodeCopyDesignatedRequirement` ->
/// `SecRequirementCopyString`. One signed bundle, one Team ID, no
/// hardcoded string.
///
/// A designated requirement names its own code first: `identifier
/// "chilld" and anchor apple generic and certificate 1[...] and
/// certificate leaf[...] and certificate leaf[subject.OU] = TEAM`. Applied
/// verbatim to the peer, that clause rejects the sibling executable in the
/// same bundle (`chill` is not `chilld`), so the identifier clause is
/// dropped and everything after it, the certificate chain down to the
/// Team ID, is the requirement. The clause order is what
/// `SecCodeCopyDesignatedRequirement` composes for signed code. The
/// identifier is quoted only when it needs quoting (`"garden.untitled.chill"`
/// has dots, `chilld` has none), so the opener is `identifier <token> and `
/// with either spelling; a string that does not open that way is an
/// error, not a guess.
public func requirementString() throws -> String {
    func check(_ call: String, _ status: OSStatus) throws {
        guard status == errSecSuccess else {
            throw RequirementError.security(call: call, status: status)
        }
    }
    var code: SecCode?
    try check("SecCodeCopySelf", SecCodeCopySelf([], &code))
    var staticCode: SecStaticCode?
    try check("SecCodeCopyStaticCode", SecCodeCopyStaticCode(code!, [], &staticCode))
    var requirement: SecRequirement?
    try check(
        "SecCodeCopyDesignatedRequirement",
        SecCodeCopyDesignatedRequirement(staticCode!, [], &requirement))
    var text: CFString?
    try check("SecRequirementCopyString", SecRequirementCopyString(requirement!, [], &text))
    let designated = text! as String
    let opener = "identifier "
    guard designated.hasPrefix(opener) else {
        throw RequirementError.unexpectedShape(designated)
    }
    let afterOpener = designated[opener.endIndex...]
    let separator = afterOpener.hasPrefix("\"") ? "\" and " : " and "
    guard let close = afterOpener.range(of: separator) else {
        throw RequirementError.unexpectedShape(designated)
    }
    return String(designated[close.upperBound...])
}
