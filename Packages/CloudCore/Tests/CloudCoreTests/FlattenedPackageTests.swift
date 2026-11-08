// Apache 2 license - developer@infinitecontext.com

import CloudCore
import Testing

@Suite struct FlattenedPackageTests {
    @Test func onlyTheEndingMakesOne() {
        #expect(FlattenedPackage.isFlattened("Report.numbers.pkgf"))
        #expect(FlattenedPackage.isFlattened("Plain.pkgf"))
        #expect(!FlattenedPackage.isFlattened("Report.numbers"))
        #expect(!FlattenedPackage.isFlattened("Report.pkgf.txt"))
        #expect(!FlattenedPackage.isFlattened(".pkgf"))
    }

    @Test func peopleSeeTheNameOnTheDisk() {
        #expect(FlattenedPackage.shownName("Report.numbers.pkgf") == "Report.numbers")
        #expect(FlattenedPackage.shownName("Report.numbers") == "Report.numbers")
        #expect(FlattenedPackage.shownName(".pkgf") == ".pkgf")
    }

    @Test func eachNameKnowsItsTwin() {
        #expect(FlattenedPackage.twin(of: "Report.numbers") == "Report.numbers.pkgf")
        #expect(FlattenedPackage.twin(of: "Report.numbers.pkgf") == "Report.numbers")
    }

    @Test func flattenedBytesKeepTheirSuffix() {
        #expect(FlattenedPackage.renamed("Old.numbers.pkgf", to: "New.numbers") == "New.numbers.pkgf")
        #expect(FlattenedPackage.renamed("Old.numbers.pkgf", to: "New.numbers.pkgf") == "New.numbers.pkgf")
    }

    /// A `.numbers` document can be a plain file, and it has to stay one.
    @Test func aPlainFileIsLeftAlone() {
        #expect(FlattenedPackage.renamed("Old.numbers", to: "New.numbers") == "New.numbers")
    }
}
