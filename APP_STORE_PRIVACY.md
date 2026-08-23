# App Store Connect Privacy Responses

## Summary
**PDF It does not collect, track, or share any personal data.**  
All document generation and processing runs locally on the user's Apple device.

---

## App Store Connect Privacy Questionnaire Answers

### 1. Data Collection
- **Question**: Do you or your third-party partners collect data from this app?
- **Answer**: **No, we do not collect any data from this app.**

### 2. Tracking
- **Question**: Do you or your third-party partners use data collected from this app for tracking purposes?
- **Answer**: **No.** (`NSPrivacyTracking: false`)

### 3. Third-Party Frameworks & Analytics
- **Third-Party SDKs**: None.
- **Analytics / Diagnostics**: None.
- **Advertising**: None.
- **Accounts / Cloud Backends**: None.

### 4. Webpage Conversion Privacy Disclosure
- When a user explicitly initiates a webpage-to-PDF conversion (via URL pasting or iOS Share Sheet), the app's internal `WKWebView` loads the user-specified webpage directly from the destination website to render it into PDF pages.
- **Direct Destination Connection**: The connection is made directly between the user's device and the destination website.
- **No Intermediary Servers**: No URLs, web content, or browsing activities are transmitted to or stored on any PDF It server or developer infrastructure.

---

## Apple Privacy Manifest (`PrivacyInfo.xcprivacy`) Declarations

PDF It ships with an official Apple Privacy Manifest (`PrivacyInfo.xcprivacy`) adhering to iOS 17+ requirements:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>NSPrivacyTracking</key>
	<false/>
	<key>NSPrivacyTrackingDomains</key>
	<array/>
	<key>NSPrivacyCollectedDataTypes</key>
	<array/>
	<key>NSPrivacyAccessedAPITypes</key>
	<array>
		<!-- UserDefaults API -->
		<dict>
			<key>NSPrivacyAccessedAPIType</key>
			<string>NSPrivacyAccessedAPICategoryUserDefaults</string>
			<key>NSPrivacyAccessedAPITypeReasons</key>
			<array>
				<string>1C8F.1</string>
			</array>
		</dict>
		<!-- File Timestamp API -->
		<dict>
			<key>NSPrivacyAccessedAPIType</key>
			<string>NSPrivacyAccessedAPICategoryFileTimestamp</string>
			<key>NSPrivacyAccessedAPITypeReasons</key>
			<array>
				<string>C617.1</string>
				<string>3B52.1</string>
			</array>
		</dict>
	</array>
</dict>
</plist>
```

### API Reasons Breakdown
1. **`NSPrivacyAccessedAPICategoryUserDefaults` (`1C8F.1`)**:
   - Used to store and synchronize user preferences (conversion mode, default paper size, image quality, footer toggles, onboarding completion flag) between the main application and the Share Extension within the `group.com.kenatst.pdfit` App Group container.
2. **`NSPrivacyAccessedAPICategoryFileTimestamp` (`C617.1`, `3B52.1`)**:
   - `C617.1`: Used to manage local cache files and temporary staging directories inside the app and App Group containers.
   - `3B52.1`: Used to inspect file size and metadata of files explicitly selected by the user via the system Document Picker or received through the iOS Share Sheet.
