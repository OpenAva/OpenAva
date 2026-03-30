import XCTest
@testable import OpenAva

final class TextImageRenderServiceTests: XCTestCase {
    private var service: TextImageRenderService!

    override func setUp() {
        super.setUp()
        service = TextImageRenderService()
    }

    override func tearDown() {
        service = nil
        super.tearDown()
    }

    func testRenderShortTextProducesSinglePage() throws {
        let request = TextImageRenderService.Request(
            text: "这是一段短文，用于验证单页渲染效果。",
            title: "测试标题",
            theme: "notes",
            width: 1080,
            aspectRatio: "3:4",
            maxPages: 6
        )

        let result = try service.render(request: request)

        XCTAssertEqual(result.pages.count, 1)
        XCTAssertFalse(result.truncated)
        XCTAssertEqual(result.pages.first?.width, 1080)
        XCTAssertEqual(result.pages.first?.height, 1440)
        XCTAssertEqual(result.pages.first?.format, "png")
        XCTAssertGreaterThan(result.pages.first?.data.count ?? 0, 0)
    }

    func testRenderLongTextRespectsMaxPagesAndReportsTruncation() throws {
        let longText = Array(repeating: "这是一段用于分页测试的文本，它应该在图片中自动换行并在超过页数限制后被截断。", count: 220)
            .joined(separator: "\n")

        let request = TextImageRenderService.Request(
            text: longText,
            title: "超长文本",
            theme: "notes",
            width: 1080,
            aspectRatio: "4:5",
            maxPages: 2
        )

        let result = try service.render(request: request)

        XCTAssertEqual(result.pages.count, 2)
        XCTAssertTrue(result.truncated)
        XCTAssertEqual(result.pages[0].index, 1)
        XCTAssertEqual(result.pages[1].index, 2)
        XCTAssertFalse(result.pages[0].text.isEmpty)
        XCTAssertFalse(result.pages[1].text.isEmpty)
    }

    func testDefaultConfigUsesPortraitFourByFiveRatio() throws {
        let request = TextImageRenderService.Request(
            text: "默认配置应为通用竖版比例。",
            title: nil,
            theme: nil,
            width: nil,
            aspectRatio: nil,
            maxPages: 1
        )

        let result = try service.render(request: request)
        let page = try XCTUnwrap(result.pages.first)

        XCTAssertEqual(page.width, 1080)
        XCTAssertEqual(page.height, 1350)
    }
}
