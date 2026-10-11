import Testing
@testable import Core

@Suite struct SecretRedactorTests {

    @Test func masksKnownTokenShapes() {
        let text = """
        let aws = "AKIAIOSFODNN7EXAMPLE"
        client = Anthropic(api_key="sk-ant-api03-abcdefghijklmnopqrstuvwxyz012345")
        GITHUB = ghp_abcdefghijklmnopqrstuvwxyz0123456789
        slack: xoxb-123456789012-abcdefghijkl
        jwt eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.SflKxwRJSMeKKF2QT4fwpMeJf36POk6yJV
        """
        let (redacted, count) = SecretRedactor.redact(text)
        #expect(!redacted.contains("AKIAIOSFODNN7EXAMPLE"))
        #expect(!redacted.contains("sk-ant-api03"))
        #expect(!redacted.contains("ghp_abcdef"))
        #expect(!redacted.contains("xoxb-1234"))
        #expect(!redacted.contains("eyJhbGci"))
        #expect(count >= 5)
        #expect(redacted.contains("let aws = \"[secret]\""))
    }

    @Test func masksPrivateKeyBlocks() {
        let text = "before\n-----BEGIN RSA PRIVATE KEY-----\nMIIEow\nabc\n-----END RSA PRIVATE KEY-----\nafter"
        let (redacted, count) = SecretRedactor.redact(text)
        #expect(redacted == "before\n[secret]\nafter")
        #expect(count == 1)
    }

    @Test func masksEnvLinesAndURLPasswordsButKeepsNames() {
        let text = """
        DATABASE_URL=postgres://admin:hunter2pass@db.internal:5432/app
        export STRIPE_SECRET_KEY=whsec_live_value_123
        DB_PASSWORD="hunter22"
        """
        let (redacted, _) = SecretRedactor.redact(text)
        #expect(redacted.contains("postgres://admin:[secret]@db.internal"))
        #expect(redacted.contains("export STRIPE_SECRET_KEY=[secret]"))
        #expect(redacted.contains("DB_PASSWORD=[secret]"))
        #expect(!redacted.contains("hunter2"))
    }

    @Test func masksQuotedSecretsInCode() {
        let (redacted, count) = SecretRedactor.redact(#"const config = { apiKey: "abcd1234efgh", password: 'opensesame' }"#)
        #expect(redacted == #"const config = { apiKey: "[secret]", password: '[secret]' }"#)
        #expect(count == 2)
    }

    @Test func leavesOrdinaryCodeAlone() {
        let code = """
        let tokens = tokenizer.encode(text)
        token = get_token()
        MAX_TOKENS = 1000
        func passwordStrength(_ password: String) -> Int { password.count }
        let sha = "3f1c2a9e8b7d6c5b4a3f2e1d0c9b8a7f6e5d4c3b"
        """
        let (redacted, count) = SecretRedactor.redact(code)
        #expect(redacted == code)
        #expect(count == 0)
    }

    @Test func neverCountsTheSameSecretTwice() {
        let (redacted, count) = SecretRedactor.redact("OPENAI_API_KEY=sk-proj-abcdefghijklmnopqrstuvwx")
        #expect(redacted == "OPENAI_API_KEY=[secret]")
        #expect(count == 1)
    }
}
