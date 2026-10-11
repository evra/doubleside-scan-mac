import AppKit
import CryptoKit
import Foundation
import Security

struct GoogleOAuthConfig {
    let clientId: String
    let clientSecret: String
    let pickerApiKey: String?
    let pickerAppId: String?

    /// Reads the Desktop-app OAuth JSON from Google Cloud Console, plus an optional top-level `picker` object.
    static func load(path: String) throws -> GoogleOAuthConfig {
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        guard let data = try? Data(contentsOf: url),
              let raw = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AppError("Google OAuth config not found or invalid at \(url.path). See README for the one-time Google Cloud setup.")
        }
        let client = (raw["installed"] ?? raw["web"]) as? [String: Any] ?? raw
        let picker = raw["picker"] as? [String: Any]
        guard let id = client["client_id"] as? String, let secret = client["client_secret"] as? String else {
            throw AppError("The Google OAuth config must contain client_id and client_secret.")
        }
        let appId = picker?["app_id"] ?? raw["app_id"]
        let configuredAppId = (appId as? String) ?? (appId as? NSNumber)?.stringValue
        // Picker needs the numeric project number (the client ID prefix), not the project ID; otherwise picked files stay inaccessible.
        let projectNumber = id.split(separator: "-").first.map(String.init).flatMap { $0.allSatisfy(\.isNumber) ? $0 : nil }
        let pickerAppId = configuredAppId.flatMap { $0.allSatisfy(\.isNumber) && !$0.isEmpty ? $0 : nil } ?? projectNumber
        return GoogleOAuthConfig(clientId: id, clientSecret: secret,
                                 pickerApiKey: (picker?["api_key"] ?? raw["api_key"]) as? String,
                                 pickerAppId: pickerAppId)
    }
}

/// Google Drive upload with the `drive.file` scope: loopback OAuth + PKCE, refresh token in Keychain, Picker for the target folder.
@MainActor
final class GoogleDrive: ObservableObject {
    static let port: UInt16 = 43871
    static let origin = "http://127.0.0.1:43871"
    private static let scope = "https://www.googleapis.com/auth/drive.file"
    // Shared with the shell implementation so an existing sign-in keeps working.
    private static let keychainService = "com.scan-doubleside.google-drive"
    private static let legacyPreferences = "com.scan-doubleside"
    private static let interactionTimeout: TimeInterval = 5 * 60

    @Published private(set) var isSignedIn = false
    @Published private(set) var folderId: String?
    @Published private(set) var folderName: String?
    @Published private(set) var activity: String?

    private var cachedToken: (value: String, expires: Date)?

    init() {
        let defaults = UserDefaults.standard
        let legacy = UserDefaults(suiteName: Self.legacyPreferences)
        folderId = defaults.string(forKey: SettingsKey.driveFolderId) ?? legacy?.string(forKey: "driveFolderId")
        folderName = defaults.string(forKey: SettingsKey.driveFolderName) ?? legacy?.string(forKey: "driveFolderName")
    }

    var accountStatus: String { isSignedIn ? "Signed in" : "Checked when you sign in or upload" }

    func signIn() async throws {
        _ = try await accessToken()
    }

    func signOut() {
        if let config = try? loadConfig() {
            Keychain.delete(service: Self.keychainService, account: config.clientId)
        }
        cachedToken = nil
        isSignedIn = false
    }

    func configurationChanged() {
        cachedToken = nil
        isSignedIn = false
    }

    func chooseFolder() async throws {
        let config = try loadConfig()
        let token = try await accessToken()
        activity = "Choose the destination folder in your browser…"
        defer { activity = nil }
        let id = try await pickFolder(config: config, accessToken: token)
        let folder = try await fetchFolder(id: id, accessToken: token)
        folderId = folder.id
        folderName = folder.name
        UserDefaults.standard.set(folder.id, forKey: SettingsKey.driveFolderId)
        UserDefaults.standard.set(folder.name, forKey: SettingsKey.driveFolderName)
    }

    /// Uploads a PDF to the selected folder and returns its Drive web link.
    func upload(file: URL, name: String, description: String?) async throws -> URL? {
        guard (name as NSString).lastPathComponent == name, name.lowercased().hasSuffix(".pdf") else {
            throw AppError("Upload file name must be a plain PDF file name.")
        }
        var token = try await accessToken()
        if folderId == nil { try await chooseFolder(); token = try await accessToken() }
        guard let folderId else { throw AppError("No Google Drive folder is selected.") }
        do {
            _ = try await fetchFolder(id: folderId, accessToken: token)
        } catch {
            throw AppError("Cannot access the selected Drive folder. Choose it again in Settings. \(error.localizedDescription)")
        }

        let size = (try FileManager.default.attributesOfItem(atPath: file.path)[.size] as? NSNumber)?.intValue ?? 0
        var metadata: [String: Any] = ["name": name, "mimeType": "application/pdf", "parents": [folderId]]
        if let description, !description.isEmpty { metadata["description"] = description }

        var start = URLRequest(url: URL(string: "https://www.googleapis.com/upload/drive/v3/files?uploadType=resumable&supportsAllDrives=true&fields=id,name,webViewLink")!)
        start.httpMethod = "POST"
        start.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        start.setValue("application/json; charset=UTF-8", forHTTPHeaderField: "Content-Type")
        start.setValue("application/pdf", forHTTPHeaderField: "X-Upload-Content-Type")
        start.setValue(String(size), forHTTPHeaderField: "X-Upload-Content-Length")
        start.httpBody = try JSONSerialization.data(withJSONObject: metadata)
        let (startData, startResponse) = try await URLSession.shared.data(for: start)
        let http = try Self.check(startResponse, startData, context: "Starting the Drive upload")
        guard let location = http.value(forHTTPHeaderField: "Location"), let sessionURL = URL(string: location),
              sessionURL.scheme == "https", sessionURL.host == "www.googleapis.com" else {
            throw AppError("Google Drive returned an unexpected resumable upload URL.")
        }

        var put = URLRequest(url: sessionURL)
        put.httpMethod = "PUT"
        put.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        put.setValue("application/pdf", forHTTPHeaderField: "Content-Type")
        let (data, response) = try await URLSession.shared.upload(for: put, fromFile: file)
        _ = try Self.check(response, data, context: "PDF upload")
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        return (json?["webViewLink"] as? String).flatMap(URL.init(string:))
    }

    // MARK: - OAuth

    private func loadConfig() throws -> GoogleOAuthConfig {
        try GoogleOAuthConfig.load(path: ScanSettings.load().googleConfigPath)
    }

    private func accessToken() async throws -> String {
        if let cachedToken, cachedToken.expires > Date() { return cachedToken.value }
        let config = try loadConfig()
        if let refreshToken = Keychain.read(service: Self.keychainService, account: config.clientId) {
            let (status, json) = try await tokenRequest([
                "client_id": config.clientId,
                "client_secret": config.clientSecret,
                "refresh_token": refreshToken,
                "grant_type": "refresh_token",
            ])
            if status == 400 || status == 401 {
                Keychain.delete(service: Self.keychainService, account: config.clientId)
            } else if (200..<300).contains(status), let token = json["access_token"] as? String {
                remember(token, expiresIn: json["expires_in"])
                isSignedIn = true
                return token
            } else {
                throw AppError("Google token refresh failed (\(status)).")
            }
        }
        return try await authorize(config: config)
    }

    private func authorize(config: GoogleOAuthConfig) async throws -> String {
        activity = "Complete Google sign-in in your browser…"
        defer { activity = nil }
        let state = Self.randomString(24)
        let verifier = Self.randomString(48)
        let challenge = Self.base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))

        let code = OneShot<String>()
        let server = try LoopbackServer(port: Self.port) { request in
            guard request.path == "/" else { return .status(404) }
            guard request.query["state"] == state else {
                code.resolve(.failure(AppError("Google sign-in returned an invalid state value.")))
                return .message("Invalid sign-in state.", status: 400)
            }
            if let error = request.query["error"] {
                code.resolve(.failure(AppError("Google sign-in failed: \(error)")))
                return .message("Google sign-in was not completed. Return to Duplex Scan.")
            }
            guard let value = request.query["code"], !value.isEmpty else { return .status(400) }
            code.resolve(.success(value))
            return .message("Google sign-in complete. You can close this tab and return to Duplex Scan.")
        }
        try await server.start()
        defer { server.stop() }

        var components = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")!
        components.queryItems = [
            URLQueryItem(name: "client_id", value: config.clientId),
            URLQueryItem(name: "redirect_uri", value: Self.origin),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: Self.scope),
            URLQueryItem(name: "access_type", value: "offline"),
            URLQueryItem(name: "prompt", value: "consent"),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
        ]
        NSWorkspace.shared.open(components.url!)
        let authorizationCode = try await code.value(timeout: Self.interactionTimeout, timeoutMessage: "Timed out waiting for Google sign-in.")

        let (status, json) = try await tokenRequest([
            "code": authorizationCode,
            "client_id": config.clientId,
            "client_secret": config.clientSecret,
            "redirect_uri": Self.origin,
            "grant_type": "authorization_code",
            "code_verifier": verifier,
        ])
        guard (200..<300).contains(status), let token = json["access_token"] as? String else {
            throw AppError("Google sign-in failed (\(status)): \(json["error_description"] ?? json["error"] ?? "")")
        }
        if let refreshToken = json["refresh_token"] as? String {
            try Keychain.write(refreshToken, service: Self.keychainService, account: config.clientId)
        }
        remember(token, expiresIn: json["expires_in"])
        isSignedIn = true
        return token
    }

    private func remember(_ token: String, expiresIn: Any?) {
        let seconds = (expiresIn as? NSNumber)?.doubleValue ?? 3600
        cachedToken = (token, Date().addingTimeInterval(seconds - 120))
    }

    private func tokenRequest(_ parameters: [String: String]) async throws -> (Int, [String: Any]) {
        var request = URLRequest(url: URL(string: "https://oauth2.googleapis.com/token")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        request.httpBody = Data(parameters.map { key, value in
            "\(key)=\(value.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")"
        }.joined(separator: "&").utf8)
        let (data, response) = try await URLSession.shared.data(for: request)
        let json = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
        return ((response as? HTTPURLResponse)?.statusCode ?? 0, json)
    }

    // MARK: - Folder picker

    private func pickFolder(config: GoogleOAuthConfig, accessToken: String) async throws -> String {
        guard let apiKey = config.pickerApiKey, let appId = config.pickerAppId else {
            throw AppError("Choosing a Drive folder needs a \"picker\" object with api_key and app_id in the Google OAuth config.")
        }
        let nonce = Self.randomString(24)
        let page = Self.pickerHTML(accessToken: accessToken, apiKey: apiKey, appId: appId, nonce: nonce)
        let selection = OneShot<String>()
        let server = try LoopbackServer(port: Self.port) { request in
            switch (request.method, request.path) {
            case ("GET", "/picker/\(nonce)"):
                return .html(page)
            case ("POST", "/selected"):
                guard request.headers["x-picker-nonce"] == nonce else { return .status(403) }
                guard let json = try? JSONSerialization.jsonObject(with: request.body) as? [String: Any],
                      let id = json["id"] as? String else { return .status(400) }
                selection.resolve(.success(id))
                return .message("Folder selected. You can close this tab and return to Duplex Scan.")
            case ("POST", "/cancel"):
                guard request.headers["x-picker-nonce"] == nonce else { return .status(403) }
                selection.resolve(.failure(CancellationError()))
                return .status(200)
            default:
                return .status(404)
            }
        }
        try await server.start()
        defer { server.stop() }
        NSWorkspace.shared.open(URL(string: "\(Self.origin)/picker/\(nonce)")!)
        return try await selection.value(timeout: Self.interactionTimeout, timeoutMessage: "Timed out waiting for a Google Drive folder selection.")
    }

    private func fetchFolder(id: String, accessToken: String) async throws -> (id: String, name: String) {
        var components = URLComponents(string: "https://www.googleapis.com/drive/v3/files")!
        components.path += "/" + id
        components.queryItems = [URLQueryItem(name: "fields", value: "id,name,mimeType"),
                                 URLQueryItem(name: "supportsAllDrives", value: "true")]
        var request = URLRequest(url: components.url!)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: request)
        _ = try Self.check(response, data, context: "Reading the Drive folder")
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              json["mimeType"] as? String == "application/vnd.google-apps.folder",
              let folderId = json["id"] as? String, let name = json["name"] as? String else {
            throw AppError("The selected Drive item is not a folder.")
        }
        return (folderId, name)
    }

    private static func pickerHTML(accessToken: String, apiKey: String, appId: String, nonce: String) -> String {
        """
        <!doctype html>
        <meta charset="utf-8">
        <title>Duplex Scan – choose Google Drive folder</title>
        <style>body{font:16px -apple-system,BlinkMacSystemFont,sans-serif;margin:40px;color:#222}button{font:inherit;padding:10px 16px}#status{margin-top:18px}</style>
        <h1>Choose the Google Drive folder for scans</h1>
        <button id="open-picker" disabled>Loading Google Picker…</button><p id="status"></p>
        <script>
        const token=\(scriptJSON(accessToken));
        const apiKey=\(scriptJSON(apiKey));
        const appId=\(scriptJSON(appId));
        const nonce=\(scriptJSON(nonce));
        const status=document.getElementById('status');
        function openPicker(){
          const view=new google.picker.DocsView(google.picker.ViewId.FOLDERS).setSelectFolderEnabled(true).setIncludeFolders(true).setMimeTypes('application/vnd.google-apps.folder');
          const sharedDrives=new google.picker.DocsView(google.picker.ViewId.FOLDERS).setSelectFolderEnabled(true).setIncludeFolders(true).setEnableDrives(true).setMimeTypes('application/vnd.google-apps.folder');
          new google.picker.PickerBuilder().enableFeature(google.picker.Feature.SUPPORT_DRIVES).addView(view).addView(sharedDrives).setOAuthToken(token).setDeveloperKey(apiKey).setAppId(appId).setOrigin(location.origin).setCallback(async data=>{
            if(data.action===google.picker.Action.PICKED){
              const folder=data.docs&&data.docs[0];
              if(!folder){status.textContent='No folder was selected.';return;}
              status.textContent='Saving folder selection…';
              const r=await fetch('/selected',{method:'POST',headers:{'Content-Type':'application/json','X-Picker-Nonce':nonce},body:JSON.stringify({id:folder.id})});
              status.textContent=r.ok?'Folder selected. You can close this tab.':'Could not save the selection.';
            }else if(data.action===google.picker.Action.CANCEL){
              await fetch('/cancel',{method:'POST',headers:{'X-Picker-Nonce':nonce}});
              status.textContent='Cancelled. You can close this tab.';
            }
          }).build().setVisible(true);
          document.getElementById('open-picker').textContent='Open folder picker';
        }
        window.gapiLoaded=()=>gapi.load('picker',{callback:()=>{const b=document.getElementById('open-picker');b.disabled=false;b.onclick=openPicker;openPicker();}});
        </script>
        <script async src="https://apis.google.com/js/api.js" onload="gapiLoaded()"></script>
        """
    }

    // MARK: - Helpers

    private static func check(_ response: URLResponse, _ data: Data, context: String) throws -> HTTPURLResponse {
        guard let http = response as? HTTPURLResponse else { throw AppError("\(context) failed.") }
        guard (200..<300).contains(http.statusCode) else {
            let detail = String(decoding: data.prefix(600), as: UTF8.self)
            throw AppError("\(context) failed (\(http.statusCode)): \(detail)")
        }
        return http
    }

    private static func scriptJSON(_ value: String) -> String {
        let data = (try? JSONEncoder().encode(value)) ?? Data("\"\"".utf8)
        return String(decoding: data, as: UTF8.self)
            .replacingOccurrences(of: "<", with: "\\u003c")
            .replacingOccurrences(of: ">", with: "\\u003e")
            .replacingOccurrences(of: "&", with: "\\u0026")
    }

    private static func randomString(_ byteCount: Int) -> String {
        var bytes = [UInt8](repeating: 0, count: byteCount)
        _ = SecRandomCopyBytes(kSecRandomDefault, byteCount, &bytes)
        return base64URL(Data(bytes))
    }

    private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
