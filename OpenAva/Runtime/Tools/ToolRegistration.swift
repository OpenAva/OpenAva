import Foundation

/// Registers all available tools with the central registry at app startup.
/// This function should be called once during app initialization.
@MainActor
private var didRegisterAllTools = false

@MainActor
func registerAllTools() async {
    guard !didRegisterAllTools else { return }
    didRegisterAllTools = true
    let registry = ToolRegistry.shared

    // Register device tools with platform-aware filtering (e.g. Catalyst limitations).
    await registry.register(provider: DeviceToolDefinitions(platform: .current))

    // Register web tools
    await registry.register(provider: WebFetchService())
    await registry.register(provider: WebSearchService())
    await registry.register(provider: ImageSearchService())
    await registry.register(provider: YouTubeTranscriptService())
    await registry.register(provider: WebViewService.shared)
    await registry.register(provider: TextImageRenderService())

    // Register file system tools
    await registry.register(provider: FileSystemService())

    // Register memory tools
    await registry.register(provider: MemoryToolDefinitions())

    // Register skill tools
    await registry.register(provider: SkillToolDefinitions())

    // Register weather tool
    await registry.register(provider: WeatherService())

    // Register Yahoo Finance tool
    await registry.register(provider: YahooFinanceService())

    // Register A-share market tool
    await registry.register(provider: AShareMarketService())
}
