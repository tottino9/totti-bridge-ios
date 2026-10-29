import com.android.apksig.ApkVerifier;
import com.android.apksig.ApkSigner;
import java.io.File;
import java.security.KeyStore;
import java.security.MessageDigest;
import java.security.PrivateKey;
import java.security.cert.X509Certificate;
import java.util.HexFormat;
import java.util.List;

public class ApkGuard {
    static String digest(X509Certificate cert) throws Exception {
        return HexFormat.of().formatHex(MessageDigest.getInstance("SHA-256").digest(cert.getEncoded()));
    }
    static String verify(File apk) throws Exception {
        var r = new ApkVerifier.Builder(apk).build().verify();
        if (!r.isVerified() || r.getSignerCertificates().size() != 1)
            throw new IllegalStateException("APK signature invalid or multiple signers");
        return digest(r.getSignerCertificates().get(0));
    }
    public static void main(String[] args) throws Exception {
        if (args.length == 2 && args[0].equals("verify")) {
            System.out.println(verify(new File(args[1]))); return;
        }
        if (args.length != 5 || !args[0].equals("sign"))
            throw new IllegalArgumentException("verify APK | sign INPUT OUTPUT DEBUG_KEYSTORE EXPECTED_CERT");
        File out = new File(args[2]);
        if (out.exists()) throw new IllegalStateException("Output already exists");
        // Only the standard locally configured Android debug key is supported.
        // No key/password is uploaded, exported, printed or persisted.
        var store = KeyStore.getInstance(new File(args[3]), "android".toCharArray());
        var certificate = (X509Certificate) store.getCertificate("androiddebugkey");
        if (certificate == null || !digest(certificate).equals(args[4]))
            throw new IllegalStateException("Local debug signing certificate does not match installed APK");
        var key = (PrivateKey) store.getKey("androiddebugkey", "android".toCharArray());
        if (key == null) throw new IllegalStateException("Debug signing key unavailable");
        var signer = new ApkSigner.SignerConfig.Builder("androiddebugkey", key, List.of(certificate)).build();
        new ApkSigner.Builder(List.of(signer)).setInputApk(new File(args[1])).setOutputApk(out)
            .setMinSdkVersion(28).setV1SigningEnabled(true).setV2SigningEnabled(true).setV3SigningEnabled(true).build().sign();
        if (!verify(out).equals(args[4])) throw new IllegalStateException("Resigned output certificate mismatch");
        System.out.println(args[4]);
    }
}
