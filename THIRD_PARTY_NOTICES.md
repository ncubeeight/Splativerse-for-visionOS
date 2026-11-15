# Third-party notices

## MetalSplatter

Source: https://github.com/scier/MetalSplatter
Pinned commit: `464eb37c55d90d7362a79120fdf8b50d4ae03296`
License: MIT, reproduced in `Vendor/MetalSplatter/LICENSE`.

The renderer, PLYIO, and SplatIO sources are vendored. The compositor frame lifecycle in `VisionScanRenderer.swift` was adapted from its SampleApp.

Integration changes:

- App-only package manifest, local SPZ dependency, and bundled source resources. The upstream `Resources` folder is named `ShaderSources` to keep the flat visionOS resource bundle valid for code signing.
- Runtime compilation of the original Metal shader source via `SplativerseShaderLibrary.swift`; Gaussian covariance projection and SH color evaluation are preserved; a distance-based opacity fade is added over the outer 5 m of the adjustable live radius. Initialization errors are thrown rather than terminating with `fatalError`.
- Bounded lossless backpressure and producer cancellation in PLY, SPZ, and SPLAT readers.
- Splat PLY decoding propagates stream errors and validates the declared point count. ASCII PLY detects truncated input.
- Three regression tests for those reader changes.
- Distance-range filtering before sorting, conservative spatial-block rejection, movement-triggered sorting, deferred initial sorts, cancellation/stop handling, and a shared head-centre sort position for both eyes.
- Cached six-face distant-scene capture and stereo panorama sampling in `SplatPanorama.swift`; premultiplied compositing over the background and a configurable color load action.
- Bubble geometry, shader layout, sorter-region, and panorama capture regression tests in `SplativerseTests`.

## spz-swift

Source: https://github.com/scier/spz-swift
Version: `2.1.0`
Pinned commit: `e2410c91bceba2539c11157ad92e488ef6e16416`
License: MIT, reproduced in `Vendor/spz-swift/LICENSE`.

The unused upstream test target was removed from the local package manifest. The decoder implements SPZ versions 1–3. It is a Swift port of Niantic’s SPZ format implementation.

Additional MetalSplatter integration changes (2026-11-14): SplatProcessing uses
full-precision screen projection, a stable covariance discriminant/eigenvalue
clamp, finite-value rejection, and bounded SDR color/opacity. Both fragment paths
discard zero/near-zero-alpha quad corners and invalid color before blend/depth
writes. A GPU regression covers very large projected splats and overflowing
packed covariances; it skips when Metal is unavailable. These changes do not
claim to confirm resolution of reported black boxes on hardware.

Additional sorter lifecycle changes (2026-11-14): surface index-buffer allocation
failure to prepare(), check stop requests during spatial traversal and index
writes, and provide stop-and-wait cleanup so replacement scans wait for sorter
workers to release their references. The CPU sort itself finishes before its
worker can drain.

2026-11-15: SplatPLYSceneReader type-mismatch errors now include the declared and expected property types. A regression verifies the unsupported x-coordinate error and successful reading of a subsequent valid file. Supported file types/conversion behavior are unchanged.
