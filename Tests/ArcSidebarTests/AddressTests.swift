import Testing
@testable import ArcSidebar

@MainActor
struct AddressTests {
    private func url(_ input: String) -> String? { BrowserModel.url(fromInput: input) }
    private var search: String { Settings.shared.searchEngine.base }

    @Test func plainDomainsBecomeHTTPS() {
        #expect(url("github.com") == "https://github.com")
        #expect(url("www.apple.com/de") == "https://www.apple.com/de")
        #expect(url("example.co.uk/path?q=1") == "https://example.co.uk/path?q=1")
        #expect(url("  github.com  ") == "https://github.com")
    }

    @Test func fullAddressesStayAsTheyAre() {
        #expect(url("https://example.com/a?b=c") == "https://example.com/a?b=c")
        #expect(url("http://intranet/x") == "http://intranet/x")
        #expect(url("about:blank") == "about:blank")
        #expect(url("mailto:a@b.de") == "mailto:a@b.de")
    }

    @Test func localAddressesUseHTTP() {
        #expect(url("localhost:3000") == "http://localhost:3000")
        #expect(url("localhost") == "http://localhost")
        #expect(url("192.168.1.1/admin") == "http://192.168.1.1/admin")
        #expect(url("nas.local:5000") == "http://nas.local:5000")
    }

    @Test func textIsSearched() {
        #expect(url("how to cook rice") == search + "how%20to%20cook%20rice")
        #expect(url("v1.2") == search + "v1.2")
        #expect(url("what is 3.5 kg in lb")?.hasPrefix(search) == true)
    }

    @Test func searchesKeepSpecialCharacters() {
        // & + # ? = must not end or split the search.
        #expect(url("c++ & rust") == search + "c%2B%2B%20%26%20rust")
        #expect(BrowserModel.searchURL("a=b#c?") == search + "a%3Db%23c%3F")
    }

    @Test func emptyInputIsNothing() {
        #expect(url("") == nil)
        #expect(url("   ") == nil)
    }

    @Test func tabCloserHostsAndExceptions() {
        #expect(TabCloser.host("www.gmail.com") == "gmail.com")
        #expect(TabCloser.host("https://mail.google.com/x") == "mail.google.com")
        #expect(TabCloser.host("") == nil)
        let closer = TabCloser()
        closer.siteRules = ["google.com": 0]
        #expect(closer.siteRule(for: "https://mail.google.com/mail") == 0)
        #expect(closer.siteRule(for: "https://example.com") == nil)
        #expect(closer.siteRule(for: "http://localhost:3000") == nil)
    }
}
