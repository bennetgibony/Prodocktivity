import Foundation
import Testing
@testable import ArcSidebar

struct UpdaterTests {
    @Test func versionsCompareByNumber() {
        #expect(Updater.isNewer("0.2", than: "0.1"))
        #expect(Updater.isNewer("v1.10", than: "1.9"))
        #expect(Updater.isNewer("1.0.1", than: "1.0"))
        #expect(!Updater.isNewer("1.0", than: "1.0.0"))
        #expect(!Updater.isNewer("0.9", than: "1.0"))
    }

    @Test func aGitHubReleaseIsRead() throws {
        let json = """
        {"tag_name":"v0.3","html_url":"https://github.com/o/r/releases/tag/v0.3","draft":false,"prerelease":false,"body":"Notes",
         "assets":[{"name":"Setup Guide.html","browser_download_url":"https://x/a.html"},
                   {"name":"proDOCKtivity.zip","browser_download_url":"https://x/proDOCKtivity.zip"}]}
        """
        let release = try #require(Updater.release(fromGitHub: Data(json.utf8)))
        #expect(release.version == "0.3" && release.download.absoluteString == "https://x/proDOCKtivity.zip" && release.notes == "Notes")
        #expect(Updater.release(fromGitHub: Data(#"{"tag_name":"v1","html_url":"https://g","assets":[]}"#.utf8)) == nil)
        #expect(Updater.release(fromGitHub: Data(#"{"tag_name":"v1","html_url":"https://g","prerelease":true,"assets":[{"name":"a.zip","browser_download_url":"https://x/a.zip"}]}"#.utf8)) == nil)
    }
}
