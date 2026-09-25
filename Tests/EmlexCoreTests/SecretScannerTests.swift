import Testing
@testable import EmlexCore

@Suite struct SecretScannerTests {
    func kinds(_ text: String) -> [String] { SecretScanner.ruleFindings(EvalHarness.expandFixtures(text)).map(\.kind) }

    @Test func curlBearerTokenIsCaught() {
        #expect(kinds("curl -H 'Authorization: Bearer {{opaque40}}' https://api.example.com/v1") == ["auth_header"])
        #expect(kinds("curl -H \"Authorization: Bearer {{anthropic}}\" https://api.anthropic.com") == ["anthropic"])
        #expect(kinds("fetch(url, { headers: { Authorization: 'Bearer {{opaque40}}' } })") == ["auth_header"])
        #expect(kinds("wget --header='Authorization: token {{github}}' https://api.github.com/user") == ["github"])
    }
    @Test func referencesAndPlaceholdersAreNot() {
        #expect(kinds("curl -H \"Authorization: Bearer $API_TOKEN\" https://api.example.com").isEmpty)
        #expect(kinds("curl -H 'Authorization: Bearer ${TOKEN}' https://x.dev").isEmpty)
        #expect(kinds("curl -H 'Authorization: Bearer <your-token>' https://x.dev").isEmpty)
        #expect(kinds("export ANTHROPIC_API_KEY=$(security find-generic-password -s emlex-anthropic -w)").isEmpty)
        #expect(kinds("password: required").isEmpty)
        #expect(kinds("token = getToken()").isEmpty)
        #expect(kinds("the password field doesn't validate").isEmpty)
    }
    @Test func vendorKeysAreNamed() {
        for (name, kind) in [("anthropic", "anthropic"), ("openai", "openai"), ("github", "github"), ("aws", "aws"), ("google", "google"),
                             ("slack", "slack"), ("hf", "huggingface"), ("stripe", "stripe"), ("npm", "npm"), ("jwt", "jwt")] {
            #expect(kinds("here: {{\(name)}} thanks") == [kind], "\(name)")
        }
    }
    @Test func credentialsInUrlsCurlAndAssignments() {
        #expect(kinds("connect to postgres://admin:{{pw}}@db.internal:5432/app") == ["url_credentials"])
        #expect(kinds("curl -u deploy:{{pw}} https://ci.example.com") == ["curl_user"])
        #expect(kinds("DATABASE_PASSWORD={{pw}}") == ["assignment"])
        #expect(kinds("password: {{pw}}") == ["password"])
        #expect(kinds("-----BEGIN OPENSSH PRIVATE KEY-----\nb3BlbnNzaA==\n-----END OPENSSH PRIVATE KEY-----") == ["private_key"])
    }
    @Test func redactionRemovesEverySecret() {
        let text = EvalHarness.expandFixtures("curl -H 'Authorization: Bearer {{opaque40}}' -u a:{{pw}} https://x.dev")
        let found = SecretScanner.ruleFindings(text)
        let red = SecretScanner.redact(text, found)
        #expect(!red.contains(EvalHarness.fixture("opaque40")) && !red.contains(EvalHarness.fixture("pw")))
        #expect(red.contains("[REDACTED]"))
        #expect(SecretScanner.ruleFindings(red).isEmpty)
    }
    @Test func previewNeverShowsTheWholeSecret() {
        let f = SecretScanner.ruleFindings(EvalHarness.expandFixtures("key {{anthropic}}"))[0]
        #expect(!f.preview.contains(f.value))
        #expect(f.preview.hasPrefix("sk-a"))
    }
    @Test func modelOnlyRunsWhenSecretsAreMentioned() {
        #expect(SecretScanner.mentionsSecrets("my password is hunter2"))
        #expect(!SecretScanner.mentionsSecrets("refactor AppController into smaller types"))
    }
}
