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
                <string>CA92.1</string>
            </array>
        </dict>
        <!-- File Timestamp API -->
        <dict>
            <key>NSPrivacyAccessedAPIType</key>
            <string>NSPrivacyAccessedAPICategoryFileTimestamp</string>
            <key>NSPrivacyAccessedAPITypeReasons</key>
            <array>
                <string>C617.1</string>
            </array>
        </dict>
        <!-- Disk Space API -->
        <dict>
            <key>NSPrivacyAccessedAPIType</key>
            <string>NSPrivacyAccessedAPICategoryDiskSpace</string>
            <key>NSPrivacyAccessedAPITypeReasons</key>
            <array>
                <string>E174.1</string>
            </array>
        </dict>
    </array>
</dict>
</plist>
```

### API Reasons Breakdown
1. **`NSPrivacyAccessedAPICategoryUserDefaults` (`CA92.1`)**:
   - Used to store user preferences (conversion mode, default paper size, image quality, footer toggles, onboarding completion flag) inside standard and App Group `UserDefaults`.
2. **`NSPrivacyAccessedAPICategoryFileTimestamp` (`C617.1`)**:
   - Used to read file creation/modification dates for local PDF records in the App Group storage library and manage temporary file lifecycle in the cache directory.
3. **`NSPrivacyAccessedAPICategoryDiskSpace` (`E174.1`)**:
   - Used to check available local disk space to safeguard against disk exhaustion when generating and saving large multi-page PDF documents.
