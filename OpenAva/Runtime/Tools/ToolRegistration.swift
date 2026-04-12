import Foundation

/// Registers all available tools with the central registry at app startup.
/// This function should be called once during app initialization.
@MainActor
private var didRegisterAllTools = false

@MainActor
func registerAllTools() async {
    guard !didRegisterAllTools else { return }
    didRegisterAllTools = true
    // Tool registration is now driven by LocalToolInvokeService.registerProvidersWithRegistry()
    // which has access to all service instances. The old per-provider registration here
    // has been replaced by that centralized method.
    //
    // This function is kept as a gateway called from LocalToolInvokeService.makeDefault().
    // Actual registration happens via LocalToolInvokeService.registerProvidersWithRegistry().
}
