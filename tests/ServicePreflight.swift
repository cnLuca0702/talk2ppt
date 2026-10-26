import Foundation
@main struct ServicePreflight {
    @MainActor static func main() async {
        let service = CodexImageService()
        await service.connect()
        print("ready=\(service.isReady)")
        print("status=\(service.status)")
        if let error = service.errorMessage { print("error=\(error)") }
        service.shutdown()
        if !service.isReady { /* state intentionally reset by shutdown */ }
    }
}
