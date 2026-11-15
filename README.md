# Splativerse for Apple Vision Pro

A native SwiftUI and Metal app for entering large Gaussian-splat environments. This is an Xcode source project, not an App Store release or a signed installable IPA.

## Run on your Vision Pro

1. Open `Splativerse.xcodeproj` in Xcode 26 or newer with the visionOS SDK installed. The project was compiled here with Xcode 27.2.
2. Select the **Splativerse** target → **Signing & Capabilities**. Choose your Apple development team and change `com.splativerse.vision` to a bundle identifier your team owns.
3. Pair your Vision Pro with Xcode, enable Developer Mode on the headset, and select it as the run destination. The app requires **visionOS 26 or newer**.
4. Run the **Splativerse** scheme. It defaults to Release for scan-loading and rendering performance.
5. Follow first-run setup in the headset. Go inside **Downloads** in either iCloud Drive or On My Apple Vision Pro when Files opens, then select **Open** in the upper-right corner. Leave individual files unselected; Open confirms the folder.
6. Choose a scan, set its source units and up direction, then select **Enter this space**.

All dependencies are included in `Vendor/`; opening the project does not require fetching a package from GitHub. The generated Xcode project is included, so XcodeGen is not required. If you change `project.yml`, regenerate with `xcodegen generate`.

## Updating after the resource-bundle signing fix

The renderer now copies its shader files into `ShaderSources`, avoiding an invalid bundle layout caused by a top-level `Resources` folder. If you built an earlier copy, choose **Product → Clean Build Folder** (Shift–Command–K) before rebuilding, so the old copied folder is removed. For a physical headset, select your team under **Splativerse target → Signing & Capabilities** and keep automatic signing enabled.

## First-run storage and Downloads

At launch the app creates its own `Documents/Scans` directory. With file sharing enabled, this is exposed in Files as **On My Apple Vision Pro → Splativerse → Scans**. The app’s sandbox makes this folder unique to Splativerse; no arbitrary shared Downloads path is assumed.

visionOS does not let an app silently search all Downloads folders. First-run setup asks you to select the intended Downloads folder through the system Files picker. The resulting security-scoped bookmark is saved privately for later launches. Splativerse recursively copies `.ply`, `.spz`, and `.splat` files from that folder into its own library. Originals are never moved or deleted.

The folder is scanned again on launch. **Files → Scan Downloads again** performs another scan while the app is open. This is not a background file watcher. If access expires or the provider is unavailable, choose the folder again. A first-run **Set up later** option allows individual imports without granting folder access.

Individual **Files → Import scans…** supports multiple selection. You can also place scans directly in Splativerse’s Scans folder and select **Refresh library**. Imports use file-provider coordination, a temporary copy, atomic renaming, and content hashes. Identical content is skipped; different files with the same name are kept under distinct filenames. Partial failures are reported per file. Cloud-hosted files may need time to download.

The library catalog, scale settings, and Downloads bookmark live in Application Support, separate from the user-visible scan files. Relative filenames are stored so app-container changes do not break the catalog.

## Immersive behavior

- Full immersive stereo rendering through Compositor Services, using ARKit device poses and per-eye projection matrices.
- Real anisotropic Gaussian splats with covariance, opacity, sorting, and spherical harmonics through degree 3. There is no sampled-point fallback.
- Light blue opaque background (`#CCE6FA`).
- Source dimensions retained. Choose metres, centimetres, or millimetres; nothing is fitted onto a plinth or miniature platform.
- Up-axis choices: Y down, Y up, or Z up. Y down is the default for typical 3DGS PLY exports and the SPZ reader’s RDF coordinate convention.
- Initial entry near the densest local scan region. A bounded sample of up to 65,536 splats finds the densest neighborhood using 4 m grid cells and their neighbors. A local low-height percentile estimates the floor; eye height starts at 1.65 m. If the centre appears occupied, a nearby opening is preferred and the view faces back toward the dense region.
- Physical head movement and walking move the view inside the scan. Native buttons provide 1 m steps relative to your current gaze, 30° snap turns around your current position, 25 cm vertical steps, and **Return to start**, which restores the estimated entry position and heading.
- The library window remains the control panel. **Leave space** is available while loading as well as during viewing. The system Home/Digital Crown controls remain available.

A Gaussian scan does not provide a collision mesh. Movement is unconstrained, and the estimated entry point may still be inside captured geometry; use the step and height controls to adjust. The original capture-camera pose cannot be reliably recovered from Gaussian geometry alone. Scene scale and orientation are editable after leaving the space.

## Single-stick flight and adjustable panel

Allow **Hand Tracking** when entering a scan. One solid silver joystick sits on a metallic panel, with a separate horizontal brass **MOVE PANEL** handle. Pinch the joystick with either hand to fly:

- Push forward to move along the headset's **current viewing direction**. Pull backward to reverse along that direction. Looking up/down changes the direction of travel, without the control adding camera pitch or roll.
- Move the stick right/left for gradual right/left yaw turning. Head direction updates throughout the gesture, rather than being locked when grabbed.
- Return the stick to neutral or release to stop immediately, without inertia. Full input is 6.5 cm of hand travel, with a 1 cm neutral zone. Maximum speed is 2 m/s and maximum turn rate is 45°/s.

The initial grip sits 28 cm ahead and 29 cm below eye level. **The panel remains fixed in physical tracking space**, including when idle, when looking around, and while virtually flying. Physical walking can move you away from it. Placement is local to the current immersive session; a new session starts with the panel in front of you.

### Position the panel while seated or standing

Release the flight stick, then pinch the horizontal brass handle with either hand and move it up/down, closer/farther, or sideways. Release to leave the panel there. It stays level and turns radially to face the headset during a drag, keeping the grasp point attached to your hand. Releasing fixes both its position and orientation. The brass rail is lowered close to the panel surface. The handle lights green and its label changes while placing. Placement never moves the virtual camera, and a fresh pinch is required before flying again.

The control window provides **Raise / Lower 5 cm**, **Closer / Farther 5 cm**, and **Bring panel here**. The latter resets placement in front of your current seated/standing position and facing direction and shows the panel if hidden. Nudges stop active flight/placement, adjust the requested dimension, and turn the panel toward the headset. Nudge limits are 18–85 cm of horizontal reach and a panel surface 15–85 cm below current eye height. Direct dragging allows flexible placement beyond those nudge limits.

Tracking loss, pause, hiding the panel, manual navigation, and flight release stop interaction without changing the last placement. Hand samples expire after 150 ms. Invalid or sudden jumping hand input during placement releases the handle and leaves the last valid position. Use **Bring panel here** if the panel is out of reach. Button navigation remains available if hand tracking is unavailable or denied; enable Hand Tracking in Settings and re-enter to retry.

Flight-panel startup and drawing failures now show the underlying error in the menu and log it under `ScanLifecycle`, distinguishing graphics preparation from hand-tracking startup. The button-label shader keeps its sampled color and tint in half precision. Compiling the previous expression with Apple Metal reproduced the vector-type error; the corrected and updated shader compiles and links for visionOS device and simulator.

Opaque metallic surfaces use view-dependent highlights and simulated environment reflections. In-headset rendering, reach, grasp comfort, and static placement after real tracking interruptions still require a headset trial with this update.

## Menu, Exit, and other apps

A large **Hide Menu** button appears at the top of the library window while immersed. It closes only that window; scan rendering and hand controls continue. It is enabled once the flight panel is ready and shown, so there is a way to bring the window back.

Compact rectangular gold controls protrude 1 cm above the metallic panel face. Instructions are black lettering with transparent backgrounds, appearing printed directly on the metal. On the left, **Menu** toggles the settings/library window; **Exit**, immediately below it, stops flight and returns to the library. On the right, **Previous** sits above **Next**. These browse the imported main Scans library in the same natural filename order shown in the window, relative to the scan currently being rendered. They do not wrap at the endpoints: unavailable directions are dimmed and inactive. Look at a button and pinch near your body to press it; release to activate it once. It highlights while pressed. Moving off the button or cancelling the gesture cancels the action. Direct touches and surface pinches use the same action path. System spatial events provide the selection ray; joystick flight and handle placement continue to use physical hand tracking. Scene monitoring belongs to the immersive space, so Menu, Exit, load errors, and system dismissal work even when the library window is closed. Manual closing of the library window uses the same recovery path.

Previous/Next keep the same immersive space open and preserve panel placement. Flight and scan browsing pause while the outgoing scan, sort workers, and GPU commands drain; the panel shows **Loading scan**, with Menu and Exit still available. Each incoming scan uses its own saved scale, orientation, radius, and estimated spawn. The window shows loading stages and updates its selection to the incoming scan.

Splativerse continues to request full immersion. visionOS hides other apps' windows while the immersive space is open; exiting returns to the shared space without closing those apps. Splativerse's own library is managed separately by Hide Menu. See [Apple's window and space documentation](https://developer.apple.com/documentation/visionos/presenting-windows-and-spaces).

## Adjustable live rendering bubble

The immersive renderer keeps Gaussian splats within an adjustable **60–360 m radius** of your head (default **60 m**) as live stereo geometry. The sphere follows physical walking and the app's navigation steps in all directions. It uses your scan's source-units setting; choose the correct metres, centimetres, or millimetres before entering.

Use **Live detail radius** before entering or in the control window while inside a scan. The slider applies when released; slider and presets offer 60, 120, 180, 240, 300, and 360 m. The choice is saved per scan, and old saved radii below 60 m migrate to 60 m while preserving scan units, orientation, and floor settings. Saved 420 m radii from the previous version migrate to 360 m. A radius change prepares a new render region and distant panorama before switching both eyes together. The current view stays visible during preparation. If memory is insufficient for a live change, leave the space and re-enter with the saved radius.

Distant geometry is captured into a six-face, 1024 × 1024 per-face panorama, shown as the inside of a sky sphere. Head turns sample this cached image instead of redrawing the city. The background refreshes asynchronously after moving the overlap distance (**5 m** at the default radius), or when you select **Refresh distant scenery**. The previous complete panorama stays visible until all six new faces finish. Nearby splats fade over the outer 5 m with an overlapping distant capture: **55–60 m** at the default and **355–360 m** at the maximum.

Distance filtering happens before sorting and drawing. Spatial block bounds reject distant regions, and head rotation alone does not trigger another distance sort. The window reports the number of live splats versus the total. Both renderers share the original GPU splat buffers; source scans are not cropped or modified.

The background has no binocular parallax and can shift when refreshed; the overlap can show ghosting while moving. This is an approximation intended to reduce continuous rendering work. It does **not** reduce the full scan's resident storage, guarantee a frame rate, or cap the density of splats inside the chosen radius. Larger radii can draw substantially more splats and increase lag; the distance change alone does not repair corrupted rendering. Initial panorama capture and later refreshes still render the distant scene. On-headset appearance and performance remain to be measured.

## Rendering-artifact hardening

The shader now keeps projected axes/deltas in full floating-point precision, uses a stable nonnegative covariance eigensolve, clamps SDR color/opacity, rejects nonfinite attributes, and discards transparent quad corners before blending/depth writes. This addresses numerical paths that can create invalid or black fragments for very large or close-up splats. Covariances that overflow packed storage are culled rather than allowed to contaminate blending. These guards can leave missing geometry for invalid splats; source data remains unchanged.

The reported black boxes have not been reproduced here. A new GPU pixel regression covers large projected splats and invalid packed covariance, but this host has no accessible Metal device, so the regression is skipped. A headset retry is needed to confirm whether the reported artifacts are resolved.

## File compatibility and large scans

PLY must contain Gaussian-splat attributes (position, scale, opacity, rotation, and color or spherical harmonics), not just an arbitrary mesh or XYZ point cloud. The included SPZ decoder supports format versions **1–3**; newer unsupported versions report a load error. Standard 32-byte `.splat` files are also supported.

Unlike the design preview, the app has no 128 MB import limit. Import hashing releases temporary read buffers after each 1 MiB chunk to avoid accumulating large scans in memory. Loading uses bounded, lossless decode queues and GPU chunks of up to 250,000 splats. The app checks a conservative GPU working-set budget and reports allocation/format failures instead of intentionally downsampling a scan. The SPZ codec still decompresses its packed payload in memory, and the renderer retains the scene and sort buffers in memory. This is **not an out-of-core or level-of-detail streaming engine**; the largest workable scan depends on headset memory, SH degree, and scene complexity. Frame rate and thermal behavior must be measured on the target headset.

The renderer’s original shader source is bundled and compiled by Metal on the device at load time. This avoids requiring Xcode’s separate downloadable Metal Toolchain for the project build. First entry may take additional time for shader compilation. Compilation errors are surfaced in the app.

## Loading recovery and diagnostics

Each immersive session has an ID: shutdown from an old scene cannot stop a new one. New sessions wait for previous loading, sorting, background capture, and GPU work to drain. In-place Previous/Next switches also release the outgoing scan before starting the next allocation. Sort-buffer allocation failures throw an error instead of leaving initial capture waiting indefinitely. A persistent **Scan could not stay open** card records a load error or unexpected startup dismissal and its last loading stage.

Console logs under subsystem `com.splativerse.vision`, categories `ScanLifecycle` and `PanelMenu`, include load/cleanup Metal allocation counts, errors, and menu visibility changes. No recent headset crash report was available here, so memory pressure or caching has not been confirmed as the cause of the reported opening/closing flicker. A system process kill can still prevent an in-app error from being recorded. No imported scans or user caches are deleted by these changes.

## Validation performed

- Release build for generic Apple Vision Pro, unsigned: **passed**.
- Release build for visionOS Simulator with ad-hoc signing enabled: **passed**. App and renderer bundle passed strict signature verification; all five shader files were verified unchanged in the app.
- Core library/navigation/radius/spawn/flight unit tests: **52 passed** (including look-and-pinch targeting of rotated/raised buttons, direct touches, one action per release, cancelled gestures, drag-off, invalid rays, disabled endpoints, legacy catalog decoding, radius persistence and limits, sparse outlier rejection, nearby opening selection, bounded deterministic sampling, return-to-start heading, flight directions and speed limits, neutral/release behavior, pinch hysteresis, tracking loss, pause, either-hand ownership, live headset-directed travel, no artificial pitch/roll, static placement, radial facing and off-center grasp retention, lower rail separation, scan endpoints, loading controls, session cleanup gating, exclusive panel dragging, height/distance controls, recovery at seated height, rigid lever tilt, invalid samples, and frame-rate-independent movement). File-provider coordination and bookmark creation use an injected local adapter in these host tests; the actual system boundary remains an on-device check.
- Additional AppModel/RenderControl integration check with a temporary folder: next/previous queued the correct files in `Room1 → Room2 → Room10` natural order and back, preserved the immersive session ID, synchronized the selected record, rejected endpoint navigation, and ignored unrelated menu-row selection. This tests command routing; actual file rendering remains a headset check.
- Upstream PLY/SPZ/SPLAT I/O tests: **28 passed**.
- Added slow-consumer/backpressure and truncated-PLY tests: **3 passed**.
- Bubble geometry, unit conversion, cube-face alignment, and shader uniform layout: **5 passed**. Three Metal-dependent checks (moving sort subset, six-face pixel capture, and large/invalid splat pixel regression) are skipped when the host has no accessible Metal device.
- No Vision Pro was attached. The flight-panel shader passed offline compilation and linking for device and simulator with Apple Metal 32023.922. Actual pipeline creation, stereo appearance, system-delivered gaze/pinch events, Files provider access, and performance have **not** been verified on a headset.

`python3 Scripts/check-flight-shader.py` compiles and links the exact embedded panel shader for device and simulator, treating warnings as errors. If a restricted command-line environment cannot resolve the installed compiler through `xcrun`, pass `--toolchain /path/to/Metal.xctoolchain`. Xcode Components confirmed Metal Toolchain 27.2 was already installed; invoking its mounted compiler directly allowed both checks to pass. The earlier ‘missing toolchain’ message reflected command-line service access, not an absent download.

`Scripts/build.sh` performs an unsigned device build; `Scripts/test.sh` runs the host test suites. Signing and installation must be done with your development team in Xcode. The simulator can help inspect UI, but headset tracking and renderer behavior must be checked on hardware.

Before using your largest scan, try `Samples/Splativerse-Demo.ply` and `Samples/Splativerse-Demo.spz` in the headset Downloads folder. Both contain the same generated Gaussian-splat room for checking the import and navigation flow, not a real-world capture.

## On-device acceptance checks

1. Launch cleanly and confirm the Splativerse/Scans folder appears in Files.
2. Choose a Downloads folder containing one PLY and one SPZ; verify copies appear and originals remain.
3. Scan Downloads again and verify identical files are skipped. Relaunch and confirm the chosen folder can be read again.
4. Enter a scan; confirm stereo depth and correct world scale. Translate your head and walk a small distance; the scan should stay anchored.
5. Check steps, height changes, Return to start, and turning in place. Confirm the starting point is near the dense region on a city-scale scan and adjust source units/up direction if needed. Exit during a large load and reopen another scan.
6. Try a malformed file and an unavailable cloud file; verify a recoverable error is shown.
7. Verify the live splat count changes when walking or stepping; turning in place must not refresh the panorama.
8. At the default 60 m radius, move at least 5 m and check that the distant capture refreshes while nearby splats remain live. Check all six directions, stereo alignment, the 55–60 m overlap, and the manual refresh button.
9. Try 60, 120, 180, 240, 300, and 360 m while inside the scan; confirm the active radius and live count update after preparation, both eyes switch together, rapid changes and exit are handled, and the setting persists after relaunch. At 360 m, verify the 355–360 m overlap and compare frame time with 60 m.
10. Allow hand tracking and verify one solid silver stick plus the horizontal brass move handle, readable labels, metallic highlights, and both-eye alignment. Pinch the stick with either hand. Check forward/back and smooth turning; look left/right/up/down while advancing and verify travel follows the current view without added pitch or roll.
11. Release the stick, grab the brass rail, and position the panel at seated and standing heights. Drag closer/farther and sideways, then release. Neither the drag nor its release may fly the camera. Turn your head while idle and confirm the panel stays fixed. Test all four nudge buttons and Bring panel here after sitting down, standing up, hiding it, or walking away.
12. Check neutral/release, stale/missing hands, invalid or jumping input, headset removal, inactivity, toggle-off, Return to start, and exit while gripping. Interaction must stop, last placement must remain, and a fresh pinch must be required. Try other UI pinches and deny permission to verify button navigation remains usable. Confirm flight still moves the live bubble correctly.
13. Hide the menu, confirm flight still works, and toggle it open and closed repeatedly by looking at the gold Menu button and pinching/releasing near your body. Repeat after manually closing the library window. Exit using the gold Exit button with the menu hidden and visible; the library should return and other apps should reappear. Deny hand permission and verify the library remains accessible. Test system dismissal and load failure while the menu is hidden.
14. Recheck the affected scan for black boxes at 60 m and 300 m, including near large surfaces and at the background transition. Record whether any remaining boxes turn with the head, move with the scan, or stay fixed on the display.
15. With at least three scans, use Previous/Next repeatedly with the menu hidden and visible. Check buttons protrude 1 cm, instructions appear printed on metal, press highlights and release/cancel behavior, natural filename order, disabled endpoints, distinct saved scan settings, centered spawn, fixed panel placement, loading indication, and Menu/Exit during loading. Select another library row while immersed and confirm Next still advances from the rendered scan. Alternate large scans, exit mid-load, and immediately reopen; confirm failures remain visible and compare ScanLifecycle memory logs across repeats.
16. Profile a representative large scan with Instruments before distribution; compare frame times with the previous full-scene renderer.

See `THIRD_PARTY_NOTICES.md` for dependency versions, licenses, and integration changes.
