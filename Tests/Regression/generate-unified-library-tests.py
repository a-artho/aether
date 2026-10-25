"""Exercise the production artifact lineage and combined-row deletion rules."""
import pathlib
import sys

repo = pathlib.Path(__file__).resolve().parents[2]
source = (repo / 'Aether/Backend/Observable/LibraryArtifactIndex.swift').read_text()
model = source[source.index('struct LibraryArtifactLineage:'):source.index('\n@MainActor')]
tests = r'''
final class UnifiedLibraryLineageTests: XCTestCase {
 func testFirstSignedCopyInheritsDownloadAndImportIdentity() {
  var lineage = LibraryArtifactLineage()
  lineage.recordSigned(uuid:"signed", sourceUUID:"original", sourceIsSigned:false)
  XCTAssertEqual(lineage.rowID(forSigned:"signed"),"app:original")
  XCTAssertEqual(lineage.signedOrigins["signed"]?.originalUUID,"original")
 }
 func testUnrelatedImportsNeverCollapse() {
  var lineage = LibraryArtifactLineage()
  lineage.recordSigned(uuid:"a", sourceUUID:"import-a", sourceIsSigned:false)
  lineage.recordSigned(uuid:"b", sourceUUID:"import-b", sourceIsSigned:false)
  XCTAssertNotEqual(lineage.rowID(forSigned:"a"),lineage.rowID(forSigned:"b"))
  XCTAssertEqual(lineage.originalUUIDsToDelete(deletingSigned:["a"],existingSigned:["a","b"]),["import-a"])
 }
 func testResigningTransfersTheActiveRowAndKeepsEveryVariant() {
  var lineage = LibraryArtifactLineage()
  lineage.recordSigned(uuid:"signed-0", sourceUUID:"original", sourceIsSigned:false)
  for i in 1...20 {
   let source="signed-\(i-1)", output="signed-\(i)", activeID=lineage.rowID(forSigned:"signed-\(i-1)")
   lineage.recordSigned(uuid:output,sourceUUID:source,sourceIsSigned:true)
   XCTAssertEqual(lineage.rowID(forSigned:output),activeID)
   XCTAssertNotEqual(lineage.rowID(forSigned:source),activeID)
  }
  XCTAssertEqual(lineage.signedOrigins.count,21)
  XCTAssertEqual(Set(lineage.signedOrigins.values.map(\.rowID)).count,21)
  XCTAssertTrue(lineage.signedOrigins.values.allSatisfy {$0.originalUUID=="original"})
 }
 func testLastCombinedVariantOwnsOriginalDeletion() {
  var lineage = LibraryArtifactLineage()
  lineage.recordSigned(uuid:"a",sourceUUID:"original",sourceIsSigned:false)
  lineage.recordSigned(uuid:"b",sourceUUID:"original",sourceIsSigned:false)
  XCTAssertNotEqual(lineage.rowID(forSigned:"a"),lineage.rowID(forSigned:"b"))
  XCTAssertTrue(lineage.originalUUIDsToDelete(deletingSigned:["a"],existingSigned:["a","b"]).isEmpty)
  XCTAssertEqual(lineage.originalUUIDsToDelete(deletingSigned:["a","b"],existingSigned:["a","b"]),["original"])
  lineage.remove(uuid:"a",isSigned:true)
  XCTAssertEqual(lineage.originalUUIDsToDelete(deletingSigned:["b"],existingSigned:["b"]),["original"])
 }
 func testShowOriginalIsPersistentAndSplitDeletionKeepsOriginal() throws {
  var lineage = LibraryArtifactLineage()
  lineage.recordSigned(uuid:"signed",sourceUUID:"original",sourceIsSigned:false)
  lineage.originalDates["original"]=Date(timeIntervalSince1970:123)
  lineage.reveal(originalUUID:"original")
  let restored=try JSONDecoder().decode(LibraryArtifactLineage.self,from:JSONEncoder().encode(lineage))
  XCTAssertEqual(restored,lineage)
  XCTAssertEqual(restored.rowID(forSigned:"signed"),"app:signed")
  XCTAssertTrue(restored.originalUUIDsToDelete(deletingSigned:["signed"],existingSigned:["signed"]).isEmpty)
 }
 func testReSigningSplitVariantKeepsItsRowIdentity() {
  var lineage = LibraryArtifactLineage()
  lineage.recordSigned(uuid:"a",sourceUUID:"original",sourceIsSigned:false)
  lineage.reveal(originalUUID:"original")
  let activeID=lineage.rowID(forSigned:"a")
  lineage.recordSigned(uuid:"b",sourceUUID:"a",sourceIsSigned:true)
  XCTAssertEqual(lineage.rowID(forSigned:"b"),activeID)
  XCTAssertNotEqual(lineage.rowID(forSigned:"a"),activeID)
  lineage.recordSigned(uuid:"c",sourceUUID:"original",sourceIsSigned:false)
  XCTAssertNotEqual(lineage.rowID(forSigned:"c"),"app:original")
 }
 func testDeletingUnsignedCopyPreservesSignedRowsAndSplitLink() {
  var lineage = LibraryArtifactLineage()
  lineage.recordSigned(uuid:"signed",sourceUUID:"original",sourceIsSigned:false)
  lineage.reveal(originalUUID:"original")
  let previousID=lineage.rowID(forSigned:"signed")
  lineage.remove(uuid:"original",isSigned:false)
  XCTAssertEqual(lineage.rowID(forSigned:"signed"),previousID)
  XCTAssertEqual(lineage.signedOrigins["signed"]?.originalUUID,"original")
  XCTAssertTrue(lineage.revealedOriginals.contains("original"))
  XCTAssertTrue(lineage.originalUUIDsToDelete(deletingSigned:["signed"],existingSigned:["signed"]).isEmpty)
 }
 func testUnlinkedSignedAppsRemainIndependent() {
  var lineage = LibraryArtifactLineage()
  lineage.recordSigned(uuid:"signed",sourceUUID:nil,sourceIsSigned:false)
  XCTAssertEqual(lineage.rowID(forSigned:"signed"),"app:signed")
  XCTAssertEqual(lineage.rowID(forSigned:"legacy"),"app:legacy")
  XCTAssertNil(lineage.signedOrigins["signed"]?.originalUUID)
 }
 func testSignAfterRevealUsesStableSignedOperationRow() {
  var lineage = LibraryArtifactLineage()
  lineage.reveal(originalUUID:"original")
  let requestID=UUID(), rowID=LibraryArtifactLineage.signedResultRowID(for:requestID)
  lineage.recordSigned(uuid:"signed",sourceUUID:"original",sourceIsSigned:false,rowID:rowID)
  XCTAssertEqual(lineage.rowID(forSigned:"signed"),rowID)
  XCTAssertTrue(lineage.revealedOriginals.contains("original"))
 }
 func testDeletingEitherSplitCopyLeavesTheOtherIndependent() {
  var lineage = LibraryArtifactLineage()
  lineage.recordSigned(uuid:"signed",sourceUUID:"original",sourceIsSigned:false)
  lineage.reveal(originalUUID:"original")
  XCTAssertTrue(lineage.originalUUIDsToDelete(deletingSigned:["signed"],existingSigned:["signed"]).isEmpty)
  lineage.remove(uuid:"signed",isSigned:true)
  lineage.recordSigned(uuid:"signed-again",sourceUUID:"original",sourceIsSigned:false)
  lineage.reveal(originalUUID:"original")
  lineage.remove(uuid:"original",isSigned:false)
  XCTAssertEqual(lineage.signedOrigins["signed-again"]?.originalUUID,"original")
  XCTAssertTrue(lineage.revealedOriginals.contains("original"))
 }
 func testLegacyLineageDecodesAndPreservesSplitLink() throws {
  let data = #"{"signedOrigins":{"signed":{"originalUUID":"original","rowID":"app:original"}},"revealedOriginals":["original"],"originalDates":{}}"#.data(using:.utf8)!
  let lineage=try JSONDecoder().decode(LibraryArtifactLineage.self,from:data)
  XCTAssertEqual(lineage.signedOrigins["signed"]?.originalUUID,"original")
 }
}
'''
output = pathlib.Path(sys.argv[1]) / 'UnifiedLibraryLineageTests.swift'
output.write_text('import Foundation\nimport XCTest\n' + model + '\n' + tests)
