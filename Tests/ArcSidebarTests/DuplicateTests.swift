import Testing
@testable import ArcSidebar

struct DuplicateTests {
    @Test func appsAndTheirWebsitesMatch() {
        #expect(Duplicates.matches(appName: "Notion", bundleID: "notion.id", url: "https://www.notion.so/x"))
        #expect(Duplicates.matches(appName: "Superfocus", bundleID: "me.superfocus.desktop", url: "https://app.superfocus.me"))
        #expect(Duplicates.matches(appName: "Spotify", bundleID: "com.spotify.client", url: "https://open.spotify.com"))
        #expect(Duplicates.matches(appName: "Zoom", bundleID: "us.zoom.xos", url: "https://zoom.us/j/1"))
        #expect(Duplicates.matches(appName: "WhatsApp", bundleID: "net.whatsapp.WhatsApp", url: "https://web.whatsapp.com"))
    }

    @Test func prefixesOfFiveLettersOrMoreCount() {
        #expect(Duplicates.matches(appName: "RemNote", bundleID: "io.remnote", url: "https://remnote.com"))
        #expect(Duplicates.matches(appName: "Figma Desktop", bundleID: "com.figma.Desktop", url: "https://figmaland.example"))
    }

    @Test func genericWordsAndShortWordsNeverMatch() {
        #expect(!Duplicates.matches(appName: "Mail", bundleID: "com.apple.mail", url: "https://mail.google.com"))
        #expect(!Duplicates.matches(appName: "Google Docs", bundleID: "com.google.docs", url: "https://google.com"))
        #expect(!Duplicates.matches(appName: "Notes", bundleID: "com.apple.Notes", url: "https://notion.so"))
        #expect(!Duplicates.matches(appName: "Arc", bundleID: "company.thebrowser.Browser", url: "https://arc.net"))
    }

    @Test func notAWebsiteNeverMatches() {
        #expect(!Duplicates.matches(appName: "Notion", bundleID: "notion.id", url: "not a url"))
        #expect(!Duplicates.matches(appName: "Notion", bundleID: "notion.id", url: ""))
    }

    @Test func keywords() {
        #expect(Duplicates.keywords(url: "https://app.superfocus.me") == ["superfocus"])
        #expect(Duplicates.keywords(appName: "Visual Studio Code", bundleID: "com.microsoft.VSCode") == ["visual", "studio", "code", "microsoft", "vscode"])
    }
}
