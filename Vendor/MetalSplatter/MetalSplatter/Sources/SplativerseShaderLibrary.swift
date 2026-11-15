// Splativerse integration: compile the unmodified renderer shaders on the target GPU.
// No separate downloadable Xcode Metal Toolchain is required to build this project.
import Foundation
import Metal

enum SplativerseShaderLibrary {
    static func make(device: MTLDevice) throws -> MTLLibrary {
        let names = ["ShaderCommon.h", "SplatProcessing.h", "SplatProcessing.metal", "SingleStageRenderPath.metal", "MultiStageRenderPath.metal"]
        let root = Bundle.module.resourceURL!.appendingPathComponent("ShaderSources", isDirectory: true)
        let source = try names.map { name in
            let text = try String(contentsOf: root.appendingPathComponent(name), encoding: .utf8)
            // Local headers occur once at the front; system Metal headers remain intact.
            return text.components(separatedBy: .newlines).filter { line in
                !line.contains("\"ShaderCommon.h\"") && !line.contains("\"SplatProcessing.h\"")
            }.joined(separator: "\n")
        }.joined(separator: "\n\n")
        let options = MTLCompileOptions()
        options.languageVersion = .version3_1
        return try device.makeLibrary(source: source, options: options)
    }
}
