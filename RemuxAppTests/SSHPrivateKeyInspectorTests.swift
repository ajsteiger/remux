@preconcurrency import Crypto
import XCTest
@testable import Remux

final class SSHPrivateKeyInspectorTests: XCTestCase {
    func testInspectsUnencryptedEd25519Key() throws {
        let inspection = try SSHPrivateKeyInspector.inspect(Self.ed25519Key)

        XCTAssertEqual(inspection.keyType, .ed25519)
        XCTAssertEqual(inspection.publicFingerprint, "SHA256:ut9xpxBjkrwDyq3o7dO0r/opPmzTsBSslfZtdaBGYWk")
        XCTAssertTrue(inspection.publicKeyLine.hasPrefix("ssh-ed25519 "))
        XCTAssertEqual(inspection.normalizedPEM, Self.ed25519Key)
    }

    func testInspectsEncryptedEd25519KeyWithoutPassphrase() throws {
        let inspection = try SSHPrivateKeyInspector.inspect(Self.encryptedEd25519Key)

        XCTAssertEqual(inspection.keyType, .ed25519)
        XCTAssertEqual(inspection.publicFingerprint, "SHA256:yEWIQVesP93YESnAgn/VLQP2EVeTWHpXrwGeFZs/doQ")
    }

    func testInspectsUnencryptedRSAKey() throws {
        let inspection = try SSHPrivateKeyInspector.inspect(Self.rsaKey)

        XCTAssertEqual(inspection.keyType, .rsa)
        XCTAssertEqual(inspection.publicFingerprint, "SHA256:Uws9SA2STf78Yr7GkJ9XeWMtf8zR+7/fQ5gkUnVTaP0")
        XCTAssertTrue(inspection.publicKeyLine.hasPrefix("ssh-rsa "))
    }

    func testGeneratesInspectableEd25519Key() throws {
        let generated = SSHPrivateKeyInspector.generateEd25519(comment: "remux-test")
        let inspection = try SSHPrivateKeyInspector.inspect(generated.privateKeyPEM)

        XCTAssertEqual(inspection.keyType, .ed25519)
        XCTAssertEqual(inspection.publicKeyLine, generated.publicKeyLine)
        XCTAssertEqual(inspection.publicFingerprint, generated.publicFingerprint)
        XCTAssertTrue(generated.publicKeyLine.hasPrefix("ssh-ed25519 "))
    }

    func testGeneratedEd25519KeyLoadsThroughConnectionParser() throws {
        let generated = SSHPrivateKeyInspector.generateEd25519(comment: "remux-test")
        let inspection = try SSHPrivateKeyInspector.inspect(generated.privateKeyPEM)

        let privateKey = try Curve25519.Signing.PrivateKey(
            sshEd25519: inspection.normalizedPEM,
            decryptionKey: nil
        )

        XCTAssertEqual(privateKey.publicKey.rawRepresentation.count, 32)
    }

    func testRejectsEmptyKey() {
        XCTAssertThrowsError(try SSHPrivateKeyInspector.inspect("   \n")) { error in
            XCTAssertEqual(error as? SSHPrivateKeyInspectionError, .empty)
        }
    }

    func testRejectsInvalidOpenSSHKey() {
        XCTAssertThrowsError(try SSHPrivateKeyInspector.inspect("not a key")) { error in
            XCTAssertEqual(error as? SSHPrivateKeyInspectionError, .invalidOpenSSHPrivateKey)
        }
    }

    private static let ed25519Key = """
    -----BEGIN OPENSSH PRIVATE KEY-----
    b3BlbnNzaC1rZXktdjEAAAAABG5vbmUAAAAEbm9uZQAAAAAAAAABAAAAMwAAAAtzc2gtZW
    QyNTUxOQAAACBrnioq6neTEO1xxGFen/fsHyajOA4is61ZfPpaD/dzkQAAAJhUdIMJVHSD
    CQAAAAtzc2gtZWQyNTUxOQAAACBrnioq6neTEO1xxGFen/fsHyajOA4is61ZfPpaD/dzkQ
    AAAEAuFkLHR6BO6DpN/zM9hdy3psHOh+8TxQMwJaNEWacIvmueKirqd5MQ7XHEYV6f9+wf
    JqM4DiKzrVl8+loP93ORAAAAEnJlbXV4LXRlc3QtZWQyNTUxOQECAw==
    -----END OPENSSH PRIVATE KEY-----
    """

    private static let encryptedEd25519Key = """
    -----BEGIN OPENSSH PRIVATE KEY-----
    b3BlbnNzaC1rZXktdjEAAAAACmFlczI1Ni1jdHIAAAAGYmNyeXB0AAAAGAAAABD87oA8AF
    9fpLEAQtTWMZZwAAAAGAAAAAEAAAAzAAAAC3NzaC1lZDI1NTE5AAAAIIuwDbwcjxPpUNPA
    PkZgyQ9jnCXaboZMHs+AWOqtGxO0AAAAoA9no2kroZ7q7MIpSQ6+Gs5N/KMrm/eFRfWf4K
    iLGRTczk+WQycDp1YidTw8kH9IwJle5ulywHf+5iLCVaolx8vYErJfKsJ1DRRx0qMzZObI
    AHd8pT6MnuDISadNzI+lZgn1dbCZ6/aWPVFO3pFpmREscRgolzFcvSOtLiT/5U1wWUhwPo
    KGvU4Tmf5I5hGQCbKhx4g4z7aJfILg2ErdGPQ=
    -----END OPENSSH PRIVATE KEY-----
    """

    private static let rsaKey = """
    -----BEGIN OPENSSH PRIVATE KEY-----
    b3BlbnNzaC1rZXktdjEAAAAABG5vbmUAAAAEbm9uZQAAAAAAAAABAAABFwAAAAdzc2gtcn
    NhAAAAAwEAAQAAAQEAvHwbXstzv7i97hp/QLB+mOdUFRdkx1t5qUNH10SprpeID3gLAWYB
    bJaRs9uTtVj4oChmmAV3nAJtSLQirDrgFrvGNsrk8rQUdvynWoN8g7VKeuIP27ZBCTN3pp
    nX3oneXDSDvk/Z/+qEp0GPxtJYfka8Ff2dtx63bgoF7j/okqunRoJKLRyXWGG4RcXSjC4T
    KRyDAdRe79eORz4Fc+3yWjbrifEvHR4GumNNcJrfpyU3AOpF1aRfIaQ+tpwMovta/V1y1p
    KXJ8Z337pXSgLVwPXolyjwyvzdCmohStkQSwJGiqfSUCyBeaobSNDl6F/66u1VowW/gwhT
    ysNVKQ6Y6QAAA8hwane2cGp3tgAAAAdzc2gtcnNhAAABAQC8fBtey3O/uL3uGn9AsH6Y51
    QVF2THW3mpQ0fXRKmul4gPeAsBZgFslpGz25O1WPigKGaYBXecAm1ItCKsOuAWu8Y2yuTy
    tBR2/Kdag3yDtUp64g/btkEJM3emmdfeid5cNIO+T9n/6oSnQY/G0lh+RrwV/Z23HrduCg
    XuP+iSq6dGgkotHJdYYbhFxdKMLhMpHIMB1F7v145HPgVz7fJaNuuJ8S8dHga6Y01wmt+n
    JTcA6kXVpF8hpD62nAyi+1r9XXLWkpcnxnffuldKAtXA9eiXKPDK/N0KaiFK2RBLAkaKp9
    JQLIF5qhtI0OXoX/rq7VWjBb+DCFPKw1UpDpjpAAAAAwEAAQAAAQAVjYN7tXwI4lEllvYS
    KZxwU5NzzfcCLN2ek0j1vq5AfqdaTXnEsStchWMn0+XyCLh1Z+lDXOyudECW3bJRS3IwZ0
    xlG5JOhnUInh9s5Dgqv2JC5vK1RwPsz2vRKypaEh3RIVgnPO5Kq0B7960/KPJhjikXwqZ0
    OBj1hkPjWH95teCGpC6WHJk5G820KmngVwqcR/TF4iQ4qddOl7O3U5jun2tzoq2Hpva2oW
    /OfS6DjaPp55kNg/SKYJTA/e0DZLeyIwaGx8ctmJYr9hsAhD6rclWZVTEVAMLR36Pofzej
    bYgLSn+PSNfrsLeY6tgr/jmKCV7EBE5g+9n+GSOgw/thAAAAgQCeDKd91bg5RJ38bdA/2f
    m3Cl8w2OK28oGrlaZVGnPcrS9QLvnRgqrB5HfGOSxgnsYwmrdiRmafK7k9wz0XjtPjhDRR
    L00qOCxtwSLrL+IWZtJPA06xkgxD46uTnTs4Qt3Vc8NRTjT1pJ3+YzuyPyJ/Z2EbHCnTQg
    FFce73mrBUKQAAAIEA+axWwVHCEde05ARuP8h2HMJHaAgoXirnjikOJ4kIfIUSU8VVp1VW
    eEcml96bVl/NIgDEI1LGn89OY9U+tZwietN1352FsnZwkJUqYJ8WvLZ/mXZdBgbo3tIkeR
    RAC93/paVW271i856Wza7AAQFp6fpSvWACBuf5BrK+UqVf1V0AAACBAMFC1Mr7Wxc99VvO
    SPN7VcCWbtxUggzVrJF9qmy+CF0XvoSrmPZzHM8YkdKcAfYoY6WEBpsg7WQZ7pU1CPaDEI
    Uy5fslboaiuQuwFBBnT1QDQQ0SoITS6MBvh0DFJVg76mR4vDLXGEmVo59CHxFZy7kR2GXu
    DfSvNOmwIetJ0+z9AAAADnJlbXV4LXRlc3QtcnNhAQIDBA==
    -----END OPENSSH PRIVATE KEY-----
    """
}
