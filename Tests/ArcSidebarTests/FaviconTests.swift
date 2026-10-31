import Foundation
import Testing
@testable import ArcSidebar

struct FaviconTests {
    @Test func pageIconsAreFoundLargestFirst() {
        let html = """
        <head><link rel="icon" href="/favicon-16.png" sizes="16x16">
        <LINK REL='apple-touch-icon' HREF='https://cdn.x.de/touch.png'>
        <link rel="shortcut icon" href="img/fav.ico">
        <link rel="mask-icon" href="/mask.svg"><link rel="stylesheet" href="a.css">
        <link rel="icon" type="image/png" sizes="96x96" href="/icons/96.png?v=1&amp;b=2"></head>
        """
        let links = Favicons.iconLinks(in: html, base: URL(string: "https://moodle.uni.de/my/")!)
        #expect(links == ["https://cdn.x.de/touch.png", "https://moodle.uni.de/icons/96.png?v=1&b=2",
                          "https://moodle.uni.de/my/img/fav.ico", "https://moodle.uni.de/favicon-16.png"])
    }

    @Test @MainActor func aSiteWithoutIconShowsItsLetter() {
        #expect(FaviconView.letter("www.webspeiseplan.de") == "W")
        #expect(FaviconView.letter("moodle.example.edu") == "M")
        #expect(FaviconView.letter("123.example") == "E")
        #expect(FaviconView.letter(nil) == nil)
    }
}
