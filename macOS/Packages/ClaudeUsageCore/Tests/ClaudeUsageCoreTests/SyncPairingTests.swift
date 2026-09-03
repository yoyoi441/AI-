import Testing
@testable import ClaudeUsageCore

struct SyncPairingTests {
    @Test func normalizesFormattedCode() {
        #expect(SyncPairing.normalize("abcd-efgh-jklm-npqr") == "ABCDEFGHJKLMNPQR")
        #expect(SyncPairing.formatted("ABCDEFGHJKLMNPQR") == "ABCD-EFGH-JKLM-NPQR")
    }

    @Test func rejectsShortOrAmbiguousCodes() {
        #expect(SyncPairing.normalize("AB12CD34") == nil)
        #expect(SyncPairing.normalize("ABCD-EFGH-IJKL-MNOP") == nil)
    }

    @Test func generatedCodesHaveEightyBitsOfAlphabetEntropy() {
        let code = SyncPairing.generateNewSyncId()
        #expect(code.count == 16)
        #expect(SyncPairing.normalize(code) == code)
    }
}
