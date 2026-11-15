---
layout: default
title: Privacy policy
permalink: /privacy/
description: How Splativerse for visionOS handles your scans, hand tracking, local settings, and diagnostics.
---

# Privacy policy

**Effective date: November 15, 2026**

This policy describes Splativerse for visionOS, developed by Christopher Arnold, and this project website. It covers the current app, version 1.0. Independently modified versions may behave differently.

## Your scans stay under your control

Splativerse is a viewer for Gaussian Splat files you create or obtain yourself. The app does not require an account, operate a hosted scan library, provide public galleries, or upload your scans to the developer. It contains no advertising, tracking, or third-party analytics SDKs. The app does not sell personal data or use scans or tracking data for advertising or model training.

## Files and information stored on your headset

When you choose files or a folder in the system Files picker, Splativerse uses the access you grant to read supported scans and copy them into **On My Apple Vision Pro → Splativerse → Scans**. Folder import can find supported files in subfolders. Your original files are not modified by importing them.

The app stores a local library catalog containing filenames, file sizes, modification dates, file hashes used to detect duplicates, local identifiers, and scan settings such as scale, orientation, floor adjustment, and detail radius. It also stores your setup preference and a system-provided folder access bookmark. That bookmark lets the app check the selected folder again when you reopen the app or request another scan of the folder.

If you select a file stored in iCloud Drive or another Files provider, that provider may download it to your headset. Device backups may also include app files and settings, depending on your Apple and provider settings. These services operate under their own privacy policies; Splativerse does not operate a separate cloud storage service.

## Hand and headset tracking

With your permission, Splativerse uses ARKit hand tracking to operate the flight joystick and reposition its panel. It uses headset pose and system interaction events to render the scene from your viewpoint and respond to navigation controls. This information is processed locally during use. The app does not save a history of your hand movements or headset poses or transmit those poses to the developer.

You may decline or revoke hand tracking permission through the system's privacy controls. Features that depend on hand tracking will be unavailable without permission. Splativerse does not request raw camera images, microphone access, contacts, or location services.

## Diagnostics and support

The app writes local system diagnostic logs about scan loading, errors, memory allocation, and panel actions. Error details may contain filenames or file paths. The app has no separate service that automatically sends these logs to the developer.

Apple may collect and make crash reports, usage information, or beta feedback available to the developer through its platform services, including TestFlight, according to your settings and Apple's terms. Any reports or messages you choose to share may be used to investigate problems and respond to support requests. Avoid including private scans or sensitive details in public reports.

## Retention, deletion, and choices

Imported scans and local library information remain on your headset until removed. You can delete imported copies in Files and refresh the library in the app. If a copy still exists in the connected source folder, it may be imported again on the next folder scan; manage that source copy or select a different folder if you do not want it reimported.

Deleting the app and its data removes its local library catalog, folder bookmark, preferences, and imported app-container files. It does not remove originals held elsewhere or independently retained cloud copies and backups. Manage those through the relevant provider or system settings. Diagnostic log retention is managed by the operating system. Support messages and platform reports may remain in the service where they were submitted, subject to that service's retention controls.

There is no Splativerse account to delete and no developer-hosted scan collection. For questions about information you have shared directly for support, contact the project at the email address below.

## This website and external services

This website is hosted on GitHub Pages. We do not add analytics, advertising, tracking pixels, cookies, or third-party embedded media to it. GitHub may process technical information such as your IP address and request details to operate and secure its service. See the [GitHub General Privacy Statement](https://docs.github.com/en/site-policy/privacy-policies/github-general-privacy-statement).

Links to Arrival Space, RadianceFields, GitHub, and other sites take you to services governed by their own policies. Those services are separate from the Splativerse viewer. Apple's services are described in the [Apple Privacy Policy](https://www.apple.com/legal/privacy/).

## Children

Splativerse does not knowingly collect personal information from children through the app. The same local processing and file controls described above apply to all users. If you believe a child has shared personal information through a support request, contact the project so it can be addressed.

## Changes to this policy

Changes will be published on this page with a revised effective date. If a future app version adds online features or changes how data is handled, this policy will be updated to describe those changes.

## Contact

For privacy questions, contact Christopher Arnold and the Splativerse project at [splativerse@googlegroups.com](mailto:splativerse@googlegroups.com). Please send only the information needed to describe your question. Do not send private scans or sensitive diagnostic logs unless a suitable way to share them has been agreed. Messages are handled through Google Groups, subject to that service’s policies and group settings.
