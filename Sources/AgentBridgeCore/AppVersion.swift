/// The one place the version and build number are written. The CLI reports
/// `marketing`, and `scripts/package-app.sh` reads both values from this file for
/// the app's Info.plist, so they cannot drift apart.
public enum AppVersion {
    public static let marketing = "0.11.1"
    public static let build = 12
}
