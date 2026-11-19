// Apache 2 license - developer@infinitecontext.com

import CloudCore
import Testing

@Suite struct ShortNameTests {
    @Test func theEnginesShortFormIsRecognised() {
        #expect(ShortName.isShortForm("Informe anual de la comisión~k3j4h5g6f7.pdf"))
        #expect(ShortName.isShortForm("aaaa~abcdefghij"))
    }

    @Test func anOrdinaryNameIsNot() {
        #expect(!ShortName.isShortForm("Notes.txt"))
        #expect(!ShortName.isShortForm("backup~1.txt"))
        #expect(!ShortName.isShortForm("Report~ABCDEFGHIJ.pdf"))
    }
}
