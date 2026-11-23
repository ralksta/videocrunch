import XCTest
@testable import VideoCrunch

final class MediaInspectionTests: XCTestCase {
    func testDecodesInspectionReportAndFormatsSummary() throws {
        let json = #"""
        {
          "filename": "IMG_1438.mov",
          "path": "/v/IMG_1438.mov",
          "container": "MOV",
          "size_bytes": 15000000,
          "duration_sec": 10.0,
          "video": {
            "codec": "hevc",
            "profile": "Main 10",
            "width": 2160,
            "height": 3840,
            "fps": 60,
            "pix_fmt": "yuv420p10le",
            "bit_depth": 10,
            "color_space": "bt2020nc",
            "color_transfer": "arib-std-b67",
            "color_primaries": "bt2020",
            "hdr_label": "HLG HDR",
            "is_hdr": true,
            "rotation": -90,
            "kbps": 11500.0
          },
          "streams": [
            {"index": 0, "type": "video", "codec": "hevc", "detail": "2160×3840 · 60 fps · 10-Bit", "language": null, "kept": true},
            {"index": 1, "type": "audio", "codec": "aac", "detail": "stereo · 48 kHz · 192 kbit/s", "language": "deu", "kept": true},
            {"index": 2, "type": "data", "codec": "mebx", "detail": "mebx", "language": null, "kept": false}
          ],
          "metadata": {
            "creation_time": "2024-10-10T13:44:56+0200",
            "camera": "Apple iPhone 15 Pro",
            "location": "+53.5511+009.9937/",
            "chapters": 2
          },
          "warnings": {
            "dolby_vision": {"profile": "8.4", "kept_as": "HLG"},
            "dropped": ["1 data track (mebx): metadata mp4 cannot hold"]
          },
          "bitrate": {
            "avg_kbps": 11000.0,
            "max_kbps": 32000.0,
            "min_kbps": 4000.0,
            "is_vbr": true,
            "samples_kbps": [5000, 32000, 11000, 4000],
            "hotspots_sec": [1.0, 5.0]
          }
        }
        """#
        let data = try XCTUnwrap(json.data(using: .utf8))
        let report = try JSONDecoder().decode(MediaInspection.self, from: data)
        XCTAssertTrue(report.warnings.hasAny)
        XCTAssertEqual(report.streams.count, 3)
        XCTAssertEqual(report.bitrate.samples_kbps.count, 4)

        let summary = report.plainTextSummary()
        XCTAssertTrue(summary.contains("IMG_1438.mov"))
        XCTAssertTrue(summary.contains("Dolby Vision 8.4 → HLG"))
        XCTAssertTrue(summary.contains("mebx"))
        XCTAssertTrue(summary.contains("Apple iPhone 15 Pro"))
        XCTAssertTrue(summary.contains("Kapitel: 2"))
    }
}
